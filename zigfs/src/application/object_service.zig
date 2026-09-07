const std = @import("std");
const checksum = @import("../common/checksum.zig");
const bucket_domain = @import("../domain/bucket.zig");
const object_domain = @import("../domain/object.zig");
const index_module = @import("../metadata/index.zig");
const bucket_store_port = @import("../ports/bucket_store.zig");
const byte_stream = @import("../ports/byte_stream.zig");
const data_store_port = @import("../ports/object_data_store.zig");
const object_store_port = @import("../ports/object_store.zig");
const ObjectLockPool = @import("object_lock_pool.zig").ObjectLockPool;

pub const Error = error{
    OutOfMemory,
    InvalidBucketName,
    InvalidObjectKey,
    InvalidContentType,
    InvalidUserMetadata,
    BucketNotFound,
    ObjectNotFound,
    ChecksumMismatch,
    InputReadFailed,
    OutputWriteFailed,
    Conflict,
    CorruptMetadata,
    CorruptData,
    InvalidRange,
    ConditionNotMet,
    Unavailable,
};

pub const PutOptions = struct {
    content_type: []const u8 = "application/octet-stream",
    user_metadata: []const object_domain.UserMetadata = &.{},
    expected_md5: ?[16]u8 = null,
    expected_sha256: ?[32]u8 = null,
    expected_crc64nvme: ?u64 = null,
    expected_checksum: ?checksum.Value = null,
    multipart_etag: ?MultipartEtag = null,
    /// Captures the object state observed before a conditional PUT.
    expected_current: ?ExpectedCurrent = null,
    /// Used by CopyObject to bind source conditions to the observed generation.
    expected_source_generation: ?u64 = null,
};

pub const ExpectedCurrent = union(enum) {
    missing,
    generation: u64,
};

pub const MultipartEtag = struct {
    digest: [16]u8,
    part_count: u16,
};

pub const DeleteResult = struct {
    deleted: bool,
};

pub const ReadLease = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    data_store: data_store_port.ObjectDataStore,
    object_lock: *std.Io.RwLock,
    object: ?object_domain.Object,
    lock_held: bool = true,

    pub fn metadata(self: *const ReadLease) *const object_domain.Object {
        return &(self.object orelse unreachable);
    }

    pub fn stream(self: *ReadLease, sink: byte_stream.Sink) Error!void {
        const object = self.object orelse unreachable;
        self.data_store.read(
            locationFor(object),
            .{
                .size = object.size,
                .checksum_sha256 = object.checksum_sha256,
            },
            sink,
        ) catch |err| return mapExistingDataError(err);
    }

    pub fn streamRange(
        self: *ReadLease,
        offset: u64,
        length: u64,
        sink: byte_stream.Sink,
    ) Error!void {
        const object = self.object orelse unreachable;
        if (offset > object.size or length > object.size - offset) return error.InvalidRange;
        self.data_store.readRange(
            locationFor(object),
            offset,
            length,
            sink,
        ) catch |err| return mapExistingDataError(err);
    }

    pub fn takeMetadata(self: *ReadLease) object_domain.Object {
        const object = self.object orelse unreachable;
        self.object = null;
        return object;
    }

    pub fn deinit(self: *ReadLease) void {
        if (self.object) |object| object.deinit(self.allocator);
        self.object = null;
        if (self.lock_held) self.object_lock.unlockShared(self.io);
        self.lock_held = false;
    }
};

pub const ObjectService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    bucket_store: bucket_store_port.BucketStore,
    object_store: object_store_port.ObjectStore,
    data_store: data_store_port.ObjectDataStore,
    index: *index_module.MetadataIndex,
    state_mutex: *std.Io.Mutex,
    object_locks: *ObjectLockPool,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        bucket_store: bucket_store_port.BucketStore,
        object_store: object_store_port.ObjectStore,
        data_store: data_store_port.ObjectDataStore,
        index: *index_module.MetadataIndex,
        state_mutex: *std.Io.Mutex,
        object_locks: *ObjectLockPool,
    ) ObjectService {
        return .{
            .allocator = allocator,
            .io = io,
            .bucket_store = bucket_store,
            .object_store = object_store,
            .data_store = data_store,
            .index = index,
            .state_mutex = state_mutex,
            .object_locks = object_locks,
        };
    }

    pub fn put(
        self: ObjectService,
        bucket_name: []const u8,
        key: []const u8,
        source: byte_stream.Source,
        options: PutOptions,
    ) Error!object_domain.Object {
        try validateRequest(bucket_name, key, options);

        self.state_mutex.lockUncancelable(self.io);
        const initial_bucket = self.loadBucketLocked(bucket_name) catch |err| {
            self.state_mutex.unlock(self.io);
            return err;
        };
        self.state_mutex.unlock(self.io);
        defer initial_bucket.deinit(self.allocator);

        const data_generation = @import("../common/id.zig").randomV4(self.io) catch return error.Unavailable;
        const staged = self.data_store.stage(data_generation, source) catch |err| return mapStageError(err);
        var staged_pending = true;
        defer if (staged_pending) self.data_store.discard(staged.token);
        const object = self.commitStaged(bucket_name, key, initial_bucket, staged, options) catch |err| return err;
        staged_pending = false;
        return object;
    }

    /// Copies an existing object through the same staged publish path as PUT.
    /// The source generation is read while a shared lease is held, then the
    /// lease is released before committing the destination so self-copies do
    /// not deadlock on the destination write lock.
    pub fn copy(
        self: ObjectService,
        source_bucket_name: []const u8,
        source_key: []const u8,
        target_bucket_name: []const u8,
        target_key: []const u8,
        options: PutOptions,
        copy_source_metadata: bool,
    ) Error!object_domain.Object {
        try validateAddress(source_bucket_name, source_key);
        try validateRequest(target_bucket_name, target_key, options);

        var source_lease = try self.open(source_bucket_name, source_key);
        defer source_lease.deinit();
        var source_object = source_lease.takeMetadata();
        defer source_object.deinit(self.allocator);
        const source_view = source_object.view();
        if (options.expected_source_generation) |generation| {
            if (source_object.metadata_generation != generation) return error.ConditionNotMet;
        }
        var copy_options = options;
        if (copy_source_metadata) {
            copy_options.content_type = source_object.content_type;
            copy_options.user_metadata = source_view.user_metadata;
        }
        if (copy_options.multipart_etag == null and source_object.etag_part_count != 0) {
            copy_options.multipart_etag = .{
                .digest = source_object.etag_md5,
                .part_count = source_object.etag_part_count,
            };
        }

        self.state_mutex.lockUncancelable(self.io);
        const initial_bucket = self.loadBucketLocked(target_bucket_name) catch |err| {
            self.state_mutex.unlock(self.io);
            return err;
        };
        self.state_mutex.unlock(self.io);
        defer initial_bucket.deinit(self.allocator);

        const data_generation = @import("../common/id.zig").randomV4(self.io) catch return error.Unavailable;
        var source_stream = LeaseSource{
            .data_store = self.data_store,
            .location = locationFor(source_view),
            .size = source_view.size,
            .offset = 0,
        };
        const staged = self.data_store.stage(data_generation, source_stream.interface()) catch |err| {
            return mapStageError(err);
        };
        var staged_pending = true;
        defer if (staged_pending) self.data_store.discard(staged.token);
        source_lease.deinit();

        const object = self.commitStaged(target_bucket_name, target_key, initial_bucket, staged, copy_options) catch |err| return err;
        staged_pending = false;
        return object;
    }

    fn commitStaged(
        self: ObjectService,
        bucket_name: []const u8,
        key: []const u8,
        initial_bucket: bucket_domain.Bucket,
        staged: data_store_port.Staged,
        options: PutOptions,
    ) Error!object_domain.Object {
        if (options.expected_md5) |expected| {
            if (!std.crypto.timing_safe.eql([16]u8, expected, staged.etag_md5)) return error.ChecksumMismatch;
        }
        if (options.expected_sha256) |expected| {
            if (!std.crypto.timing_safe.eql([32]u8, expected, staged.checksum_sha256)) return error.ChecksumMismatch;
        }
        if (options.expected_crc64nvme) |expected| {
            if (expected != staged.checksum_crc64nvme) return error.ChecksumMismatch;
        }
        if (options.expected_checksum) |expected| {
            if (!stagedMatchesChecksum(staged, expected)) return error.ChecksumMismatch;
        }

        const object_lock = self.object_locks.get(bucket_name, key);
        object_lock.lockUncancelable(self.io);
        defer object_lock.unlock(self.io);
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);

        const bucket = try self.loadBucketLocked(bucket_name);
        defer bucket.deinit(self.allocator);
        if (!std.mem.eql(u8, &initial_bucket.id, &bucket.id) or initial_bucket.generation != bucket.generation) {
            return error.BucketNotFound;
        }

        const current = try self.loadObjectLocked(bucket_name, key);
        defer if (current) |record| record.deinit(self.allocator);
        if (options.expected_current) |expected| {
            const current_generation: ?u64 = if (current) |record| switch (record) {
                .active => |object| object.metadata_generation,
                .tombstone => null,
            } else null;
            switch (expected) {
                .missing => if (current_generation != null) return error.ConditionNotMet,
                .generation => |generation| if (current_generation == null or current_generation.? != generation) return error.ConditionNotMet,
            }
        }
        var expected_generation: object_store_port.ExpectedGeneration = .missing;
        const object_id = if (current) |record| switch (record) {
            .active => |object| active: {
                expected_generation = .{ .exact = object.metadata_generation };
                break :active object.id;
            },
            .tombstone => |generation| deleted: {
                expected_generation = .{ .exact = generation };
                break :deleted @import("../common/id.zig").randomV4(self.io) catch return error.Unavailable;
            },
        } else @import("../common/id.zig").randomV4(self.io) catch return error.Unavailable;
        const data_generation = staged.token;
        const modified_at = std.Io.Clock.real.now(self.io).toSeconds();
        const value: object_store_port.Value = .{
            .id = object_id,
            .bucket_id = bucket.id,
            .bucket_name = bucket_name,
            .key = key,
            .size = staged.size,
            .etag_md5 = if (options.multipart_etag) |etag| etag.digest else staged.etag_md5,
            .etag_part_count = if (options.multipart_etag) |etag| etag.part_count else 0,
            .checksum_sha256 = staged.checksum_sha256,
            .content_type = options.content_type,
            .last_modified_unix_seconds = modified_at,
            .user_metadata = options.user_metadata,
            .data_generation = data_generation,
            .status = .active,
        };
        var owned = object_domain.cloneFromView(self.allocator, value, 0) catch return error.OutOfMemory;
        errdefer owned.deinit(self.allocator);
        var prepared = self.index.prepareObject(bucket_name, key) catch |err| return mapIndexError(err);
        defer prepared.deinit(self.index.allocator);
        self.data_store.publish(staged, .{ .bucket_id = bucket.id, .object_id = object_id, .data_generation = data_generation }) catch |err| return mapPublishError(err);
        const metadata_generation = self.object_store.put(self.allocator, value, expected_generation) catch |err| return mapObjectStoreError(err);
        self.index.publishObject(&prepared, metadata_generation);
        owned.metadata_generation = metadata_generation;
        return owned;
    }

    pub fn head(
        self: ObjectService,
        bucket_name: []const u8,
        key: []const u8,
    ) Error!object_domain.Object {
        var lease = try self.open(bucket_name, key);
        defer lease.deinit();
        return lease.takeMetadata();
    }

    pub fn get(
        self: ObjectService,
        bucket_name: []const u8,
        key: []const u8,
        sink: byte_stream.Sink,
    ) Error!object_domain.Object {
        var lease = try self.open(bucket_name, key);
        defer lease.deinit();
        try lease.stream(sink);
        return lease.takeMetadata();
    }

    pub fn open(
        self: ObjectService,
        bucket_name: []const u8,
        key: []const u8,
    ) Error!ReadLease {
        try validateAddress(bucket_name, key);
        const object_lock = self.object_locks.get(bucket_name, key);
        object_lock.lockSharedUncancelable(self.io);
        errdefer object_lock.unlockShared(self.io);

        self.state_mutex.lockUncancelable(self.io);
        const object = self.loadActiveObjectLocked(bucket_name, key) catch |err| {
            self.state_mutex.unlock(self.io);
            return err;
        };
        self.state_mutex.unlock(self.io);
        errdefer object.deinit(self.allocator);
        const size = self.data_store.stat(locationFor(object)) catch |err| {
            return mapExistingDataError(err);
        };
        if (size != object.size) return error.CorruptData;
        return .{
            .allocator = self.allocator,
            .io = self.io,
            .data_store = self.data_store,
            .object_lock = object_lock,
            .object = object,
        };
    }

    pub fn delete(
        self: ObjectService,
        bucket_name: []const u8,
        key: []const u8,
    ) Error!DeleteResult {
        try validateAddress(bucket_name, key);
        const object_lock = self.object_locks.get(bucket_name, key);
        object_lock.lockUncancelable(self.io);
        defer object_lock.unlock(self.io);
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);

        const bucket = try self.loadBucketLocked(bucket_name);
        defer bucket.deinit(self.allocator);
        const current = try self.loadObjectLocked(bucket_name, key) orelse {
            return .{ .deleted = false };
        };
        defer current.deinit(self.allocator);
        const object = switch (current) {
            .active => |active| active,
            .tombstone => return .{ .deleted = false },
        };
        _ = self.object_store.tombstone(
            self.allocator,
            bucket_name,
            key,
            object.metadata_generation,
        ) catch |err| return mapObjectStoreError(err);
        if (!self.index.removeObject(bucket_name, key)) return error.CorruptMetadata;
        return .{ .deleted = true };
    }

    fn loadBucketLocked(
        self: ObjectService,
        bucket_name: []const u8,
    ) Error!bucket_domain.Bucket {
        const indexed_generation = self.index.bucketGeneration(bucket_name) orelse {
            return error.BucketNotFound;
        };
        const record = self.bucket_store.get(self.allocator, bucket_name) catch |err| {
            return switch (err) {
                error.NotFound => error.CorruptMetadata,
                else => mapBucketStoreError(err),
            };
        };
        return switch (record) {
            .active => |bucket| {
                if (bucket.generation != indexed_generation) {
                    bucket.deinit(self.allocator);
                    return error.CorruptMetadata;
                }
                return bucket;
            },
            .tombstone => error.CorruptMetadata,
        };
    }

    fn loadObjectLocked(
        self: ObjectService,
        bucket_name: []const u8,
        key: []const u8,
    ) Error!?object_store_port.Record {
        const indexed_generation = self.index.objectGeneration(bucket_name, key);
        const record: object_store_port.Record = self.object_store.get(
            self.allocator,
            bucket_name,
            key,
        ) catch |err| switch (err) {
            error.NotFound => {
                if (indexed_generation != null) return error.CorruptMetadata;
                return null;
            },
            else => return mapObjectStoreError(err),
        };
        switch (record) {
            .active => |object| {
                if (indexed_generation == null or
                    indexed_generation.? != object.metadata_generation)
                {
                    object.deinit(self.allocator);
                    return error.CorruptMetadata;
                }
            },
            .tombstone => {
                if (indexed_generation != null) return error.CorruptMetadata;
            },
        }
        return record;
    }

    fn loadActiveObjectLocked(
        self: ObjectService,
        bucket_name: []const u8,
        key: []const u8,
    ) Error!object_domain.Object {
        const bucket = try self.loadBucketLocked(bucket_name);
        defer bucket.deinit(self.allocator);
        const current = try self.loadObjectLocked(bucket_name, key) orelse {
            return error.ObjectNotFound;
        };
        return switch (current) {
            .active => |object| object,
            .tombstone => error.ObjectNotFound,
        };
    }
};

fn validateAddress(bucket_name: []const u8, key: []const u8) Error!void {
    bucket_domain.validateName(bucket_name) catch return error.InvalidBucketName;
    object_domain.validateKey(key) catch return error.InvalidObjectKey;
}

fn validateRequest(
    bucket_name: []const u8,
    key: []const u8,
    options: PutOptions,
) Error!void {
    try validateAddress(bucket_name, key);
    object_domain.validateContentType(options.content_type) catch {
        return error.InvalidContentType;
    };
    object_domain.validateUserMetadata(options.user_metadata) catch {
        return error.InvalidUserMetadata;
    };
    if (options.multipart_etag) |etag| {
        if (etag.part_count == 0 or etag.part_count > object_domain.max_multipart_parts) {
            return error.InvalidUserMetadata;
        }
    }
}

const LeaseSource = struct {
    data_store: data_store_port.ObjectDataStore,
    location: data_store_port.Location,
    size: u64,
    offset: u64,

    fn interface(self: *LeaseSource) byte_stream.Source {
        return .{ .context = self, .vtable = &.{ .read = read } };
    }

    fn read(context: *anyopaque, buffer: []u8) byte_stream.Source.Error!usize {
        const self: *LeaseSource = @ptrCast(@alignCast(context));
        if (self.offset == self.size) return 0;
        if (buffer.len == 0) return error.ReadFailed;
        const requested = @min(self.size - self.offset, @as(u64, @intCast(buffer.len)));
        var sink = RangeBufferSink{ .buffer = buffer[0..@intCast(requested)] };
        self.data_store.readRange(
            self.location,
            self.offset,
            requested,
            sink.interface(),
        ) catch return error.ReadFailed;
        if (sink.written != requested) return error.ReadFailed;
        self.offset += requested;
        return @intCast(requested);
    }
};

const RangeBufferSink = struct {
    buffer: []u8,
    written: u64 = 0,

    fn interface(self: *RangeBufferSink) byte_stream.Sink {
        return .{ .context = self, .vtable = &.{ .write_all = writeAll } };
    }

    fn writeAll(context: *anyopaque, bytes: []const u8) byte_stream.Sink.Error!void {
        const self: *RangeBufferSink = @ptrCast(@alignCast(context));
        if (bytes.len > self.buffer.len - @as(usize, @intCast(self.written))) return error.WriteFailed;
        @memcpy(self.buffer[@intCast(self.written)..][0..bytes.len], bytes);
        self.written += bytes.len;
    }
};

fn locationFor(object: anytype) data_store_port.Location {
    return .{
        .bucket_id = object.bucket_id,
        .object_id = object.id,
        .data_generation = object.data_generation,
    };
}

fn mapBucketStoreError(err: bucket_store_port.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotFound => error.BucketNotFound,
        error.Conflict => error.Conflict,
        error.InvalidValue, error.CorruptMetadata => error.CorruptMetadata,
        error.Unavailable => error.Unavailable,
    };
}

fn mapObjectStoreError(err: object_store_port.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotFound => error.ObjectNotFound,
        error.Conflict => error.Conflict,
        error.InvalidValue, error.CorruptMetadata => error.CorruptMetadata,
        error.Unavailable => error.Unavailable,
    };
}

fn mapIndexError(err: index_module.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CorruptRecord => error.CorruptMetadata,
        error.Unavailable => error.Unavailable,
    };
}

fn mapStageError(err: data_store_port.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SourceReadFailed => error.InputReadFailed,
        error.Conflict => error.Conflict,
        error.CorruptData => error.CorruptData,
        error.InvalidValue,
        error.SinkWriteFailed,
        error.NotFound,
        error.Unavailable,
        => error.Unavailable,
    };
}

fn stagedMatchesChecksum(staged: data_store_port.Staged, expected: checksum.Value) bool {
    return switch (expected) {
        .crc32 => |value| value == staged.checksum_crc32,
        .crc32c => |value| value == staged.checksum_crc32c,
        .crc64nvme => |value| value == staged.checksum_crc64nvme,
        .sha1 => |value| std.mem.eql(u8, &value, &staged.checksum_sha1),
        .sha256 => |value| std.mem.eql(u8, &value, &staged.checksum_sha256),
    };
}

fn mapPublishError(err: data_store_port.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Conflict => error.Conflict,
        error.CorruptData => error.CorruptData,
        error.InvalidValue,
        error.SourceReadFailed,
        error.SinkWriteFailed,
        error.NotFound,
        error.Unavailable,
        => error.Unavailable,
    };
}

fn mapExistingDataError(err: data_store_port.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SinkWriteFailed => error.OutputWriteFailed,
        error.CorruptData, error.NotFound => error.CorruptData,
        error.Conflict => error.Conflict,
        error.InvalidValue => error.CorruptMetadata,
        error.SourceReadFailed,
        error.Unavailable,
        => error.Unavailable,
    };
}

test "object service puts gets overwrites and tombstones objects" {
    const MemoryMetadataRepository = @import("../testing/memory_metadata_repository.zig").MemoryMetadataRepository;
    const MetadataBucketStore = @import("../metadata/bucket_store.zig").MetadataBucketStore;
    const MetadataObjectStore = @import("../metadata/object_store.zig").MetadataObjectStore;
    const LocalObjectDataStore = @import("../backend/local_object_data.zig").LocalObjectDataStore;
    const BucketService = @import("bucket_service.zig").BucketService;
    const streaming = @import("../common/streaming.zig");
    const test_streams = @import("../testing/streams.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".zigfs/tmp");
    try tmp.dir.createDirPath(std.testing.io, "objects");
    var memory = MemoryMetadataRepository.init(std.testing.allocator);
    defer memory.deinit();
    var bucket_store = MetadataBucketStore.init(memory.interface());
    var object_store = MetadataObjectStore.init(memory.interface());
    var data_store = LocalObjectDataStore.init(
        std.testing.allocator,
        tmp.dir,
        std.testing.io,
        streaming.min_buffer_size,
    );
    var index = index_module.MetadataIndex.init(std.testing.allocator);
    defer index.deinit();
    try index.rebuild(memory.interface());
    var state_mutex: std.Io.Mutex = .init;
    var object_locks: ObjectLockPool = .{};
    const buckets = BucketService.init(
        std.testing.allocator,
        std.testing.io,
        bucket_store.interface(),
        &index,
        &state_mutex,
    );
    const bucket = try buckets.create("project-assets", "owner-a");
    defer bucket.deinit(std.testing.allocator);
    const objects = ObjectService.init(
        std.testing.allocator,
        std.testing.io,
        bucket_store.interface(),
        object_store.interface(),
        data_store.interface(),
        &index,
        &state_mutex,
        &object_locks,
    );

    const body = "first object body";
    var expected_md5: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(body, &expected_md5, .{});
    var source = test_streams.SliceSource.init(body);
    const created = try objects.put(
        "project-assets",
        "../../images/cover.txt",
        source.interface(),
        .{
            .content_type = "text/plain",
            .user_metadata = &.{.{ .name = "client-id", .value = "mobile" }},
            .expected_md5 = expected_md5,
        },
    );
    defer created.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, body.len), created.size);
    try std.testing.expectEqualStrings("mobile", created.user_metadata[0].value);

    const headed = try objects.head("project-assets", "../../images/cover.txt");
    defer headed.deinit(std.testing.allocator);
    try std.testing.expectEqual(created.metadata_generation, headed.metadata_generation);
    var sink = test_streams.CollectingSink.init(std.testing.allocator);
    defer sink.deinit();
    const downloaded = try objects.get(
        "project-assets",
        "../../images/cover.txt",
        sink.interface(),
    );
    defer downloaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(body, sink.bytes.items);

    const copied = try objects.copy(
        "project-assets",
        "../../images/cover.txt",
        "project-assets",
        "copies/cover.txt",
        .{},
        true,
    );
    defer copied.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("text/plain", copied.content_type);
    try std.testing.expectEqualStrings("mobile", copied.user_metadata[0].value);
    var copy_sink = test_streams.CollectingSink.init(std.testing.allocator);
    defer copy_sink.deinit();
    const copied_body = try objects.get("project-assets", "copies/cover.txt", copy_sink.interface());
    defer copied_body.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(body, copy_sink.bytes.items);

    const self_copy = try objects.copy(
        "project-assets",
        "../../images/cover.txt",
        "project-assets",
        "../../images/cover.txt",
        .{},
        true,
    );
    defer self_copy.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("text/plain", self_copy.content_type);
    var self_copy_sink = test_streams.CollectingSink.init(std.testing.allocator);
    defer self_copy_sink.deinit();
    const self_copy_body = try objects.get(
        "project-assets",
        "../../images/cover.txt",
        self_copy_sink.interface(),
    );
    defer self_copy_body.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(body, self_copy_sink.bytes.items);

    var replacement_source = test_streams.SliceSource.init("replacement");
    const replaced = try objects.put(
        "project-assets",
        "../../images/cover.txt",
        replacement_source.interface(),
        .{},
    );
    defer replaced.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &created.id, &replaced.id);
    try std.testing.expect(!std.mem.eql(u8, &created.data_generation, &replaced.data_generation));
    try std.testing.expect(replaced.metadata_generation > created.metadata_generation);

    var stale_source = test_streams.SliceSource.init("stale replacement");
    try std.testing.expectError(
        error.ConditionNotMet,
        objects.put(
            "project-assets",
            "../../images/cover.txt",
            stale_source.interface(),
            .{ .expected_current = .{ .generation = created.metadata_generation } },
        ),
    );

    try std.testing.expect((try objects.delete("project-assets", "../../images/cover.txt")).deleted);
    try std.testing.expect(!(try objects.delete("project-assets", "../../images/cover.txt")).deleted);
    try std.testing.expect((try objects.delete("project-assets", "copies/cover.txt")).deleted);
    try std.testing.expectError(
        error.ObjectNotFound,
        objects.head("project-assets", "../../images/cover.txt"),
    );
    try buckets.delete("project-assets");
}

test "object service rejects missing buckets bad checksums and failed sources" {
    const MemoryMetadataRepository = @import("../testing/memory_metadata_repository.zig").MemoryMetadataRepository;
    const MetadataBucketStore = @import("../metadata/bucket_store.zig").MetadataBucketStore;
    const MetadataObjectStore = @import("../metadata/object_store.zig").MetadataObjectStore;
    const LocalObjectDataStore = @import("../backend/local_object_data.zig").LocalObjectDataStore;
    const BucketService = @import("bucket_service.zig").BucketService;
    const streaming = @import("../common/streaming.zig");
    const test_streams = @import("../testing/streams.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".zigfs/tmp");
    try tmp.dir.createDirPath(std.testing.io, "objects");
    var memory = MemoryMetadataRepository.init(std.testing.allocator);
    defer memory.deinit();
    var bucket_store = MetadataBucketStore.init(memory.interface());
    var object_store = MetadataObjectStore.init(memory.interface());
    var data_store = LocalObjectDataStore.init(
        std.testing.allocator,
        tmp.dir,
        std.testing.io,
        streaming.min_buffer_size,
    );
    var index = index_module.MetadataIndex.init(std.testing.allocator);
    defer index.deinit();
    try index.rebuild(memory.interface());
    var state_mutex: std.Io.Mutex = .init;
    var object_locks: ObjectLockPool = .{};
    const buckets = BucketService.init(
        std.testing.allocator,
        std.testing.io,
        bucket_store.interface(),
        &index,
        &state_mutex,
    );
    const objects = ObjectService.init(
        std.testing.allocator,
        std.testing.io,
        bucket_store.interface(),
        object_store.interface(),
        data_store.interface(),
        &index,
        &state_mutex,
        &object_locks,
    );
    var missing_source = test_streams.SliceSource.init("body");
    try std.testing.expectError(
        error.BucketNotFound,
        objects.put("missing-bucket", "file", missing_source.interface(), .{}),
    );
    const bucket = try buckets.create("project-assets", "owner-a");
    defer bucket.deinit(std.testing.allocator);
    var checksum_source = test_streams.SliceSource.init("body");
    try std.testing.expectError(
        error.ChecksumMismatch,
        objects.put("project-assets", "file", checksum_source.interface(), .{
            .expected_md5 = .{0} ** 16,
        }),
    );
    var crc_source = test_streams.SliceSource.init("body");
    try std.testing.expectError(
        error.ChecksumMismatch,
        objects.put("project-assets", "file", crc_source.interface(), .{
            .expected_crc64nvme = 0,
        }),
    );
    var failing_source: test_streams.FailingSource = .{};
    try std.testing.expectError(
        error.InputReadFailed,
        objects.put("project-assets", "failed", failing_source.interface(), .{}),
    );
}
