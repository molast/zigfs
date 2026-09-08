const std = @import("std");
const checksum = @import("../common/checksum.zig");
const bucket_domain = @import("../domain/bucket.zig");
const object_domain = @import("../domain/object.zig");
const index_module = @import("../metadata/index.zig");
const bucket_store_port = @import("../ports/bucket_store.zig");
const byte_stream = @import("../ports/byte_stream.zig");
const data_store_port = @import("../ports/object_data_store.zig");
const multipart_data_store_port = @import("../ports/multipart_data_store.zig");
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
    InvalidVersionId,
    DeleteMarker,
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

pub const MultipartCommitOptions = struct {
    content_type: []const u8 = "application/octet-stream",
    user_metadata: []const object_domain.UserMetadata = &.{},
    etag: MultipartEtag,
};

pub const DeleteResult = struct {
    deleted: bool,
    delete_marker: bool = false,
    version_id: ?object_domain.VersionId = null,
};

pub const VersionListEntry = struct {
    key: []u8,
    version_id: object_domain.VersionId,
    is_latest: bool,
    is_delete_marker: bool,
    size: u64,
    etag_md5: [16]u8,
    etag_part_count: u16,
    last_modified_unix_seconds: i64,

    pub fn deinit(self: VersionListEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
    }
};

pub const VersionList = struct {
    entries: []VersionListEntry,

    pub fn deinit(self: VersionList, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| entry.deinit(allocator);
        allocator.free(self.entries);
    }
};

pub const ReadLease = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    data_store: data_store_port.ObjectDataStore,
    multipart_data_store: ?multipart_data_store_port.MultipartDataStore,
    object_lock: *std.Io.RwLock,
    object: ?object_domain.Object,
    lock_held: bool = true,

    pub fn metadata(self: *const ReadLease) *const object_domain.Object {
        return &(self.object orelse unreachable);
    }

    pub fn stream(self: *ReadLease, sink: byte_stream.Sink) Error!void {
        const object = self.object orelse unreachable;
        if (object.multipart_manifest) |manifest| {
            const store = self.multipart_data_store orelse return error.CorruptData;
            for (manifest.parts) |part| {
                var verifying_sink: VerifyingPartSink = .{ .downstream = sink };
                store.readRange(
                    multipartLocation(manifest.upload_id, part),
                    0,
                    part.size,
                    verifying_sink.interface(),
                ) catch |err| return mapExistingMultipartDataError(err);
                if (verifying_sink.size != part.size or
                    !std.crypto.timing_safe.eql([32]u8, verifying_sink.digest(), part.checksum_sha256))
                {
                    return error.CorruptData;
                }
            }
            return;
        }
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
        if (object.multipart_manifest) |manifest| {
            const store = self.multipart_data_store orelse return error.CorruptData;
            var object_part_offset: u64 = 0;
            var requested_offset = offset;
            var remaining = length;
            for (manifest.parts) |part| {
                if (remaining == 0) break;
                const part_end = std.math.add(u64, object_part_offset, part.size) catch return error.CorruptMetadata;
                if (requested_offset >= part_end) {
                    object_part_offset = part_end;
                    continue;
                }
                const offset_in_part = if (requested_offset > object_part_offset) requested_offset - object_part_offset else 0;
                const part_length = @min(remaining, part.size - offset_in_part);
                store.readRange(
                    multipartLocation(manifest.upload_id, part),
                    offset_in_part,
                    part_length,
                    sink,
                ) catch |err| return mapExistingMultipartDataError(err);
                requested_offset += part_length;
                remaining -= part_length;
                object_part_offset = part_end;
            }
            if (remaining != 0) return error.CorruptData;
            return;
        }
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
    multipart_data_store: ?multipart_data_store_port.MultipartDataStore,
    index: *index_module.MetadataIndex,
    state_mutex: *std.Io.Mutex,
    object_locks: *ObjectLockPool,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        bucket_store: bucket_store_port.BucketStore,
        object_store: object_store_port.ObjectStore,
        data_store: data_store_port.ObjectDataStore,
        multipart_data_store: ?multipart_data_store_port.MultipartDataStore,
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
            .multipart_data_store = multipart_data_store,
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

    pub fn commitMultipart(
        self: ObjectService,
        bucket_name: []const u8,
        key: []const u8,
        manifest: object_domain.MultipartManifestView,
        size: u64,
        options: MultipartCommitOptions,
    ) Error!object_domain.Object {
        try validateAddress(bucket_name, key);
        object_domain.validateContentType(options.content_type) catch return error.InvalidContentType;
        object_domain.validateUserMetadata(options.user_metadata) catch return error.InvalidUserMetadata;
        if (options.etag.part_count == 0 or options.etag.part_count > object_domain.max_multipart_parts or
            options.etag.part_count != manifest.parts.len or !@import("../common/id.zig").isValidV4(manifest.upload_id))
        {
            return error.CorruptMetadata;
        }
        const multipart_store = self.multipart_data_store orelse return error.Unavailable;
        var verified_size: u64 = 0;
        var previous_part_number: u16 = 0;
        for (manifest.parts) |part| {
            if (part.number == 0 or part.number <= previous_part_number or
                !@import("../common/id.zig").isValidV4(part.data_generation)) return error.CorruptMetadata;
            const stored_size = multipart_store.stat(multipartLocation(manifest.upload_id, part)) catch |err| {
                return mapExistingMultipartDataError(err);
            };
            if (stored_size != part.size) return error.CorruptData;
            verified_size = std.math.add(u64, verified_size, stored_size) catch return error.CorruptMetadata;
            previous_part_number = part.number;
        }
        if (verified_size != size) return error.CorruptMetadata;

        self.state_mutex.lockUncancelable(self.io);
        const initial_bucket = self.loadBucketLocked(bucket_name) catch |err| {
            self.state_mutex.unlock(self.io);
            return err;
        };
        self.state_mutex.unlock(self.io);
        defer initial_bucket.deinit(self.allocator);

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
        const current = try self.loadHistoryLocked(bucket_name, key);
        defer if (current) |record| record.deinit(self.allocator);
        var expected_generation: object_store_port.ExpectedGeneration = .missing;
        if (current) |record| switch (record) {
            .active => |history| expected_generation = .{ .exact = history.metadata_generation },
            .tombstone => |generation| expected_generation = .{ .exact = generation },
        };
        const object_id = reusableNullVersionObjectId(current, bucket.versioning) orelse
            (@import("../common/id.zig").randomV4(self.io) catch return error.Unavailable);
        const data_generation = @import("../common/id.zig").randomV4(self.io) catch return error.Unavailable;
        const value: object_store_port.Value = .{
            .id = object_id,
            .bucket_id = bucket.id,
            .bucket_name = bucket_name,
            .key = key,
            .size = size,
            .etag_md5 = options.etag.digest,
            .etag_part_count = options.etag.part_count,
            .checksum_sha256 = manifestIntegrityDigest(manifest),
            .content_type = options.content_type,
            .last_modified_unix_seconds = std.Io.Clock.real.now(self.io).toSeconds(),
            .user_metadata = options.user_metadata,
            .data_generation = data_generation,
            .multipart_manifest = manifest,
            .status = .active,
            .version_id = if (bucket.versioning == .enabled)
                .{ .uuid = @import("../common/id.zig").randomV4(self.io) catch return error.Unavailable }
            else
                .null_version,
        };
        var owned = object_domain.cloneFromView(self.allocator, value, 0) catch return error.OutOfMemory;
        errdefer owned.deinit(self.allocator);
        var history = buildHistoryWithObject(self.allocator, value, current, bucket.versioning) catch return error.OutOfMemory;
        defer history.deinit(self.allocator);
        var prepared = self.index.prepareObject(bucket_name, key) catch |err| return mapIndexError(err);
        defer prepared.deinit(self.index.allocator);
        const metadata_generation = self.object_store.putHistory(
            self.allocator,
            &history,
            expected_generation,
        ) catch |err| return mapObjectStoreError(err);
        self.index.publishObject(&prepared, metadata_generation);
        owned.metadata_generation = metadata_generation;
        return owned;
    }

    /// Copies an existing object through the same staged publish path as PUT.
    /// The source generation is read while a shared lease is held, then the
    /// lease is released before committing the destination so self-copies do
    /// not deadlock on the destination write lock.
    pub fn copy(
        self: ObjectService,
        source_bucket_name: []const u8,
        source_key: []const u8,
        source_version_id: ?object_domain.VersionId,
        target_bucket_name: []const u8,
        target_key: []const u8,
        options: PutOptions,
        copy_source_metadata: bool,
    ) Error!object_domain.Object {
        try validateAddress(source_bucket_name, source_key);
        try validateRequest(target_bucket_name, target_key, options);

        var source_lease = if (source_version_id) |version_id|
            try self.openVersion(source_bucket_name, source_key, version_id)
        else
            try self.open(source_bucket_name, source_key);
        defer source_lease.deinit();
        const source_object = source_lease.metadata();
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
            .lease = &source_lease,
            .size = source_view.size,
            .offset = 0,
        };
        const staged = self.data_store.stage(data_generation, source_stream.interface()) catch |err| {
            return mapStageError(err);
        };
        var staged_pending = true;
        defer if (staged_pending) self.data_store.discard(staged.token);
        var source_metadata = source_lease.takeMetadata();
        defer source_metadata.deinit(self.allocator);
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

        const current = try self.loadHistoryLocked(bucket_name, key);
        defer if (current) |record| record.deinit(self.allocator);
        if (options.expected_current) |expected| {
            const current_generation: ?u64 = if (current) |record| switch (record) {
                .active => |history| switch (history.entries[0]) {
                    .object => history.metadata_generation,
                    .delete_marker => null,
                },
                .tombstone => null,
            } else null;
            switch (expected) {
                .missing => if (current_generation != null) return error.ConditionNotMet,
                .generation => |generation| if (current_generation == null or current_generation.? != generation) return error.ConditionNotMet,
            }
        }
        var expected_generation: object_store_port.ExpectedGeneration = .missing;
        if (current) |record| switch (record) {
            .active => |history| expected_generation = .{ .exact = history.metadata_generation },
            .tombstone => |generation| {
                expected_generation = .{ .exact = generation };
            },
        };
        const object_id = reusableNullVersionObjectId(current, bucket.versioning) orelse
            (@import("../common/id.zig").randomV4(self.io) catch return error.Unavailable);
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
            .version_id = if (bucket.versioning == .enabled)
                .{ .uuid = @import("../common/id.zig").randomV4(self.io) catch return error.Unavailable }
            else
                .null_version,
        };
        var owned = object_domain.cloneFromView(self.allocator, value, 0) catch return error.OutOfMemory;
        errdefer owned.deinit(self.allocator);
        var history = buildHistoryWithObject(
            self.allocator,
            value,
            current,
            bucket.versioning,
        ) catch return error.OutOfMemory;
        defer history.deinit(self.allocator);
        var prepared = self.index.prepareObject(bucket_name, key) catch |err| return mapIndexError(err);
        defer prepared.deinit(self.index.allocator);
        self.data_store.publish(staged, .{ .bucket_id = bucket.id, .object_id = object_id, .data_generation = data_generation }) catch |err| return mapPublishError(err);
        const metadata_generation = self.object_store.putHistory(
            self.allocator,
            &history,
            expected_generation,
        ) catch |err| return mapObjectStoreError(err);
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
        try self.validateObjectData(object);
        return .{
            .allocator = self.allocator,
            .io = self.io,
            .data_store = self.data_store,
            .multipart_data_store = self.multipart_data_store,
            .object_lock = object_lock,
            .object = object,
        };
    }

    pub fn openVersion(
        self: ObjectService,
        bucket_name: []const u8,
        key: []const u8,
        version_id: object_domain.VersionId,
    ) Error!ReadLease {
        try validateAddress(bucket_name, key);
        const object_lock = self.object_locks.get(bucket_name, key);
        object_lock.lockSharedUncancelable(self.io);
        errdefer object_lock.unlockShared(self.io);
        self.state_mutex.lockUncancelable(self.io);
        const object = self.loadVersionLocked(bucket_name, key, version_id) catch |err| {
            self.state_mutex.unlock(self.io);
            return err;
        };
        self.state_mutex.unlock(self.io);
        errdefer object.deinit(self.allocator);
        try self.validateObjectData(object);
        return .{
            .allocator = self.allocator,
            .io = self.io,
            .data_store = self.data_store,
            .multipart_data_store = self.multipart_data_store,
            .object_lock = object_lock,
            .object = object,
        };
    }

    fn validateObjectData(self: ObjectService, object: object_domain.Object) Error!void {
        if (object.multipart_manifest) |manifest| {
            const store = self.multipart_data_store orelse return error.CorruptData;
            var total_size: u64 = 0;
            for (manifest.parts) |part| {
                const size = store.stat(multipartLocation(manifest.upload_id, part)) catch |err| {
                    return mapExistingMultipartDataError(err);
                };
                if (size != part.size) return error.CorruptData;
                total_size = std.math.add(u64, total_size, size) catch return error.CorruptMetadata;
            }
            if (total_size != object.size) return error.CorruptMetadata;
            return;
        }
        const size = self.data_store.stat(locationFor(object)) catch |err| return mapExistingDataError(err);
        if (size != object.size) return error.CorruptData;
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
        const current = try self.loadHistoryLocked(bucket_name, key);
        defer if (current) |record| record.deinit(self.allocator);
        if (bucket.versioning == .unversioned) {
            const record = current orelse return .{ .deleted = false };
            const generation = switch (record) {
                .active => |history| history.metadata_generation,
                .tombstone => return .{ .deleted = false },
            };
            _ = self.object_store.tombstone(
                self.allocator,
                bucket_name,
                key,
                generation,
            ) catch |err| return mapObjectStoreError(err);
            if (!self.index.removeObject(bucket_name, key)) return error.CorruptMetadata;
            return .{ .deleted = true };
        }

        const version_id: object_domain.VersionId = if (bucket.versioning == .enabled)
            .{ .uuid = @import("../common/id.zig").randomV4(self.io) catch return error.Unavailable }
        else
            .null_version;
        const modified_at = std.Io.Clock.real.now(self.io).toSeconds();
        var history = buildHistoryWithDeleteMarker(
            self.allocator,
            bucket_name,
            key,
            version_id,
            modified_at,
            current,
            bucket.versioning,
        ) catch return error.OutOfMemory;
        defer history.deinit(self.allocator);
        const expected_generation: object_store_port.ExpectedGeneration = if (current) |record| switch (record) {
            .active => |existing| .{ .exact = existing.metadata_generation },
            .tombstone => |generation| .{ .exact = generation },
        } else .missing;
        var prepared = self.index.prepareObject(bucket_name, key) catch |err| return mapIndexError(err);
        defer prepared.deinit(self.index.allocator);
        const generation = self.object_store.putHistory(self.allocator, &history, expected_generation) catch |err| return mapObjectStoreError(err);
        self.index.publishObject(&prepared, generation);
        return .{ .deleted = true, .delete_marker = true, .version_id = version_id };
    }

    pub fn deleteVersion(
        self: ObjectService,
        bucket_name: []const u8,
        key: []const u8,
        version_id: object_domain.VersionId,
    ) Error!DeleteResult {
        try validateAddress(bucket_name, key);
        const object_lock = self.object_locks.get(bucket_name, key);
        object_lock.lockUncancelable(self.io);
        defer object_lock.unlock(self.io);
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        const bucket = try self.loadBucketLocked(bucket_name);
        defer bucket.deinit(self.allocator);
        const current = try self.loadHistoryLocked(bucket_name, key) orelse {
            return .{ .deleted = false, .version_id = version_id };
        };
        defer current.deinit(self.allocator);
        const existing = switch (current) {
            .active => |history| history,
            .tombstone => return .{ .deleted = false, .version_id = version_id },
        };
        var found: ?usize = null;
        for (existing.entries, 0..) |entry, index| {
            if (object_domain.VersionId.eql(entry.versionId(), version_id)) {
                found = index;
                break;
            }
        }
        const remove_index = found orelse return .{ .deleted = false, .version_id = version_id };
        const was_delete_marker = switch (existing.entries[remove_index]) {
            .delete_marker => true,
            .object => false,
        };
        if (existing.entries.len == 1) {
            _ = self.object_store.tombstone(self.allocator, bucket_name, key, existing.metadata_generation) catch |err| return mapObjectStoreError(err);
            if (!self.index.removeObject(bucket_name, key)) return error.CorruptMetadata;
        } else {
            var history = cloneHistoryWithout(self.allocator, existing, remove_index) catch return error.OutOfMemory;
            defer history.deinit(self.allocator);
            const generation = self.object_store.putHistory(self.allocator, &history, .{ .exact = existing.metadata_generation }) catch |err| return mapObjectStoreError(err);
            var prepared = self.index.prepareObject(bucket_name, key) catch |err| return mapIndexError(err);
            defer prepared.deinit(self.index.allocator);
            self.index.publishObject(&prepared, generation);
        }
        return .{ .deleted = true, .delete_marker = was_delete_marker, .version_id = version_id };
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
            .delete_marker => {
                if (indexed_generation == null) {
                    record.deinit(self.allocator);
                    return error.CorruptMetadata;
                }
            },
            .tombstone => {
                if (indexed_generation != null) return error.CorruptMetadata;
            },
        }
        return record;
    }

    fn loadHistoryLocked(
        self: ObjectService,
        bucket_name: []const u8,
        key: []const u8,
    ) Error!?object_store_port.HistoryRecord {
        const indexed_generation = self.index.objectGeneration(bucket_name, key);
        const record = self.object_store.getHistory(self.allocator, bucket_name, key) catch |err| switch (err) {
            error.NotFound => {
                if (indexed_generation != null) return error.CorruptMetadata;
                return null;
            },
            else => return mapObjectStoreError(err),
        };
        switch (record) {
            .active => |history| {
                if (indexed_generation == null or indexed_generation.? != history.metadata_generation) {
                    history.deinit(self.allocator);
                    return error.CorruptMetadata;
                }
            },
            .tombstone => if (indexed_generation != null) return error.CorruptMetadata,
        }
        return record;
    }

    fn loadVersionLocked(
        self: ObjectService,
        bucket_name: []const u8,
        key: []const u8,
        version_id: object_domain.VersionId,
    ) Error!object_domain.Object {
        const bucket = try self.loadBucketLocked(bucket_name);
        defer bucket.deinit(self.allocator);
        const record = try self.loadHistoryLocked(bucket_name, key) orelse return error.ObjectNotFound;
        defer record.deinit(self.allocator);
        const history = switch (record) {
            .active => |active| active,
            .tombstone => return error.ObjectNotFound,
        };
        for (history.entries) |entry| {
            if (!object_domain.VersionId.eql(entry.versionId(), version_id)) continue;
            return switch (entry) {
                .object => |object| object_domain.cloneFromView(
                    self.allocator,
                    object.view(),
                    history.metadata_generation,
                ) catch return error.OutOfMemory,
                .delete_marker => error.DeleteMarker,
            };
        }
        return error.ObjectNotFound;
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
            .delete_marker => |marker| {
                marker.deinit(self.allocator);
                return error.ObjectNotFound;
            },
            .tombstone => error.ObjectNotFound,
        };
    }

    pub fn listVersions(
        self: ObjectService,
        bucket_name: []const u8,
        prefix: []const u8,
    ) Error!VersionList {
        bucket_domain.validateName(bucket_name) catch return error.InvalidBucketName;
        if (prefix.len > object_domain.max_key_length or std.mem.indexOfScalar(u8, prefix, 0) != null) {
            return error.InvalidObjectKey;
        }
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        const bucket = try self.loadBucketLocked(bucket_name);
        defer bucket.deinit(self.allocator);
        var entries: std.ArrayList(VersionListEntry) = .empty;
        errdefer {
            for (entries.items) |entry| entry.deinit(self.allocator);
            entries.deinit(self.allocator);
        }
        for (self.index.objectEntries()) |indexed| {
            if (!std.mem.eql(u8, indexed.bucket, bucket_name) or !std.mem.startsWith(u8, indexed.key, prefix)) continue;
            const record = self.object_store.getHistory(self.allocator, bucket_name, indexed.key) catch |err| return mapObjectStoreError(err);
            defer record.deinit(self.allocator);
            const history = switch (record) {
                .active => |active| active,
                .tombstone => return error.CorruptMetadata,
            };
            if (history.metadata_generation != indexed.generation) return error.CorruptMetadata;
            for (history.entries, 0..) |entry, version_index| {
                const key = self.allocator.dupe(u8, indexed.key) catch return error.OutOfMemory;
                errdefer self.allocator.free(key);
                const summary: VersionListEntry = switch (entry) {
                    .object => |object| .{
                        .key = key,
                        .version_id = object.version_id,
                        .is_latest = version_index == 0,
                        .is_delete_marker = false,
                        .size = object.size,
                        .etag_md5 = object.etag_md5,
                        .etag_part_count = object.etag_part_count,
                        .last_modified_unix_seconds = object.last_modified_unix_seconds,
                    },
                    .delete_marker => |marker| .{
                        .key = key,
                        .version_id = marker.version_id,
                        .is_latest = version_index == 0,
                        .is_delete_marker = true,
                        .size = 0,
                        .etag_md5 = .{0} ** 16,
                        .etag_part_count = 0,
                        .last_modified_unix_seconds = marker.last_modified_unix_seconds,
                    },
                };
                entries.append(self.allocator, summary) catch return error.OutOfMemory;
            }
        }
        return .{ .entries = entries.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
    }

    pub fn findDeleteMarker(
        self: ObjectService,
        bucket_name: []const u8,
        key: []const u8,
        version_id: ?object_domain.VersionId,
    ) Error!?object_domain.DeleteMarker {
        try validateAddress(bucket_name, key);
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        const bucket = try self.loadBucketLocked(bucket_name);
        defer bucket.deinit(self.allocator);
        const record = try self.loadHistoryLocked(bucket_name, key) orelse return null;
        defer record.deinit(self.allocator);
        const history = switch (record) {
            .active => |active| active,
            .tombstone => return null,
        };
        for (history.entries, 0..) |entry, index| {
            if (version_id) |requested| {
                if (!object_domain.VersionId.eql(entry.versionId(), requested)) continue;
            } else if (index != 0) break;
            return switch (entry) {
                .object => null,
                .delete_marker => |marker| marker.clone(self.allocator) catch return error.OutOfMemory,
            };
        }
        return null;
    }
};

fn buildHistoryWithObject(
    allocator: std.mem.Allocator,
    value: object_domain.View,
    current: ?object_store_port.HistoryRecord,
    versioning: bucket_domain.Versioning,
) std.mem.Allocator.Error!object_domain.History {
    return buildHistory(allocator, .{ .object = value }, current, versioning);
}

fn reusableNullVersionObjectId(
    current: ?object_store_port.HistoryRecord,
    versioning: bucket_domain.Versioning,
) ?@import("../common/id.zig").Uuid {
    if (versioning == .enabled) return null;
    const record = current orelse return null;
    const history = switch (record) {
        .active => |value| value,
        .tombstone => return null,
    };
    for (history.entries) |entry| switch (entry) {
        .object => |object| if (object.version_id == .null_version) return object.id,
        .delete_marker => {},
    };
    return null;
}

const NewHistoryEntry = union(enum) {
    object: object_domain.View,
    delete_marker: struct {
        bucket_name: []const u8,
        key: []const u8,
        version_id: object_domain.VersionId,
        modified_at: i64,
    },
};

fn buildHistoryWithDeleteMarker(
    allocator: std.mem.Allocator,
    bucket_name: []const u8,
    key: []const u8,
    version_id: object_domain.VersionId,
    modified_at: i64,
    current: ?object_store_port.HistoryRecord,
    versioning: bucket_domain.Versioning,
) std.mem.Allocator.Error!object_domain.History {
    return buildHistory(allocator, .{ .delete_marker = .{
        .bucket_name = bucket_name,
        .key = key,
        .version_id = version_id,
        .modified_at = modified_at,
    } }, current, versioning);
}

fn buildHistory(
    allocator: std.mem.Allocator,
    new_entry: NewHistoryEntry,
    current: ?object_store_port.HistoryRecord,
    versioning: bucket_domain.Versioning,
) std.mem.Allocator.Error!object_domain.History {
    const bucket_name = switch (new_entry) {
        .object => |value| value.bucket_name,
        .delete_marker => |value| value.bucket_name,
    };
    const key = switch (new_entry) {
        .object => |value| value.key,
        .delete_marker => |value| value.key,
    };
    const existing: ?object_domain.History = if (current) |record| switch (record) {
        .active => |history| history,
        .tombstone => null,
    } else null;
    var retained: usize = 0;
    if (existing) |history| {
        for (history.entries) |entry| {
            if (versioning == .unversioned) continue;
            if (versioning == .suspended and entry.versionId() == .null_version) continue;
            retained += 1;
        }
    }
    const owned_bucket = try allocator.dupe(u8, bucket_name);
    errdefer allocator.free(owned_bucket);
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    const entries = try allocator.alloc(object_domain.VersionEntry, retained + 1);
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |entry| entry.deinit(allocator);
        allocator.free(entries);
    }
    entries[0] = switch (new_entry) {
        .object => |value| .{ .object = try object_domain.cloneFromView(allocator, value, 0) },
        .delete_marker => |value| marker: {
            const marker_bucket = try allocator.dupe(u8, value.bucket_name);
            errdefer allocator.free(marker_bucket);
            break :marker .{ .delete_marker = .{
                .bucket_name = marker_bucket,
                .key = try allocator.dupe(u8, value.key),
                .version_id = value.version_id,
                .last_modified_unix_seconds = value.modified_at,
            } };
        },
    };
    initialized = 1;
    if (existing) |history| for (history.entries) |entry| {
        if (versioning == .unversioned) continue;
        if (versioning == .suspended and entry.versionId() == .null_version) continue;
        entries[initialized] = try cloneVersionEntry(allocator, entry);
        initialized += 1;
    };
    return .{ .bucket_name = owned_bucket, .key = owned_key, .entries = entries, .metadata_generation = 0 };
}

fn cloneVersionEntry(
    allocator: std.mem.Allocator,
    entry: object_domain.VersionEntry,
) std.mem.Allocator.Error!object_domain.VersionEntry {
    return switch (entry) {
        .object => |object| .{ .object = try object_domain.cloneFromView(allocator, object.view(), object.metadata_generation) },
        .delete_marker => |marker| .{ .delete_marker = try marker.clone(allocator) },
    };
}

fn cloneHistoryWithout(
    allocator: std.mem.Allocator,
    history: object_domain.History,
    remove_index: usize,
) std.mem.Allocator.Error!object_domain.History {
    const bucket = try allocator.dupe(u8, history.bucket_name);
    errdefer allocator.free(bucket);
    const key = try allocator.dupe(u8, history.key);
    errdefer allocator.free(key);
    const entries = try allocator.alloc(object_domain.VersionEntry, history.entries.len - 1);
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |entry| entry.deinit(allocator);
        allocator.free(entries);
    }
    for (history.entries, 0..) |entry, index| {
        if (index == remove_index) continue;
        entries[initialized] = try cloneVersionEntry(allocator, entry);
        initialized += 1;
    }
    return .{ .bucket_name = bucket, .key = key, .entries = entries, .metadata_generation = history.metadata_generation };
}

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
        null,
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
        null,
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

test "object service preserves version history delete markers and suspended null versions" {
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
    const created_bucket = try buckets.create("versioned-assets", "owner-a");
    created_bucket.deinit(std.testing.allocator);
    const enabled_bucket = try buckets.setVersioning("versioned-assets", .enabled);
    enabled_bucket.deinit(std.testing.allocator);
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

    var first_source = test_streams.SliceSource.init("first");
    const first = try objects.put("versioned-assets", "release.txt", first_source.interface(), .{});
    defer first.deinit(std.testing.allocator);
    var second_source = test_streams.SliceSource.init("second");
    const second = try objects.put("versioned-assets", "release.txt", second_source.interface(), .{});
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(first.version_id != .null_version);
    try std.testing.expect(second.version_id != .null_version);
    try std.testing.expect(!object_domain.VersionId.eql(first.version_id, second.version_id));
    try std.testing.expect(!std.mem.eql(u8, &first.id, &second.id));

    const initial_versions = try objects.listVersions("versioned-assets", "release");
    defer initial_versions.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), initial_versions.entries.len);
    try std.testing.expect(initial_versions.entries[0].is_latest);
    try std.testing.expect(object_domain.VersionId.eql(second.version_id, initial_versions.entries[0].version_id));

    var first_sink = test_streams.CollectingSink.init(std.testing.allocator);
    defer first_sink.deinit();
    var first_lease = try objects.openVersion("versioned-assets", "release.txt", first.version_id);
    try first_lease.stream(first_sink.interface());
    first_lease.deinit();
    try std.testing.expectEqualStrings("first", first_sink.bytes.items);

    const rewound = try objects.copy(
        "versioned-assets",
        "release.txt",
        first.version_id,
        "versioned-assets",
        "release.txt",
        .{},
        true,
    );
    defer rewound.deinit(std.testing.allocator);
    try std.testing.expect(!object_domain.VersionId.eql(first.version_id, rewound.version_id));
    try std.testing.expect(!object_domain.VersionId.eql(second.version_id, rewound.version_id));
    var rewound_sink = test_streams.CollectingSink.init(std.testing.allocator);
    defer rewound_sink.deinit();
    const rewound_current = try objects.get("versioned-assets", "release.txt", rewound_sink.interface());
    defer rewound_current.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("first", rewound_sink.bytes.items);
    const rewound_versions = try objects.listVersions("versioned-assets", "release");
    defer rewound_versions.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), rewound_versions.entries.len);
    try std.testing.expect(object_domain.VersionId.eql(rewound.version_id, rewound_versions.entries[0].version_id));
    try std.testing.expect((try objects.deleteVersion("versioned-assets", "release.txt", rewound.version_id)).deleted);
    const after_rewind_cleanup = try objects.head("versioned-assets", "release.txt");
    defer after_rewind_cleanup.deinit(std.testing.allocator);
    try std.testing.expect(object_domain.VersionId.eql(second.version_id, after_rewind_cleanup.version_id));

    const deleted = try objects.delete("versioned-assets", "release.txt");
    try std.testing.expect(deleted.deleted and deleted.delete_marker);
    try std.testing.expect(deleted.version_id != null);
    try std.testing.expectError(error.ObjectNotFound, objects.head("versioned-assets", "release.txt"));
    const with_marker = try objects.listVersions("versioned-assets", "release");
    defer with_marker.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), with_marker.entries.len);
    try std.testing.expect(with_marker.entries[0].is_latest and with_marker.entries[0].is_delete_marker);

    const removed_marker = try objects.deleteVersion("versioned-assets", "release.txt", deleted.version_id.?);
    try std.testing.expect(removed_marker.deleted and removed_marker.delete_marker);
    const restored = try objects.head("versioned-assets", "release.txt");
    defer restored.deinit(std.testing.allocator);
    try std.testing.expect(object_domain.VersionId.eql(second.version_id, restored.version_id));
    try std.testing.expect((try objects.deleteVersion("versioned-assets", "release.txt", second.version_id)).deleted);
    const previous = try objects.head("versioned-assets", "release.txt");
    defer previous.deinit(std.testing.allocator);
    try std.testing.expect(object_domain.VersionId.eql(first.version_id, previous.version_id));

    const suspended_bucket = try buckets.setVersioning("versioned-assets", .suspended);
    suspended_bucket.deinit(std.testing.allocator);
    var null_source = test_streams.SliceSource.init("null one");
    const null_one = try objects.put("versioned-assets", "release.txt", null_source.interface(), .{});
    defer null_one.deinit(std.testing.allocator);
    var replacement_source = test_streams.SliceSource.init("null two");
    const null_two = try objects.put("versioned-assets", "release.txt", replacement_source.interface(), .{});
    defer null_two.deinit(std.testing.allocator);
    try std.testing.expect(null_one.version_id == .null_version);
    try std.testing.expect(null_two.version_id == .null_version);
    try std.testing.expectEqualSlices(u8, &null_one.id, &null_two.id);
    const suspended_versions = try objects.listVersions("versioned-assets", "release");
    defer suspended_versions.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), suspended_versions.entries.len);
    try std.testing.expect(suspended_versions.entries[0].version_id == .null_version);
    try std.testing.expect(object_domain.VersionId.eql(first.version_id, suspended_versions.entries[1].version_id));
}
