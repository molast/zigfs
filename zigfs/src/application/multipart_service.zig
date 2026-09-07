const std = @import("std");
const checksum = @import("../common/checksum.zig");
const bucket_domain = @import("../domain/bucket.zig");
const multipart_domain = @import("../domain/multipart.zig");
const object_domain = @import("../domain/object.zig");
const id = @import("../common/id.zig");
const index_module = @import("../metadata/index.zig");
const bucket_store_port = @import("../ports/bucket_store.zig");
const byte_stream = @import("../ports/byte_stream.zig");
const data_store_port = @import("../ports/multipart_data_store.zig");
const multipart_store_port = @import("../ports/multipart_store.zig");
const object_service = @import("object_service.zig");
const ObjectLockPool = @import("object_lock_pool.zig").ObjectLockPool;

pub const Error = error{
    OutOfMemory,
    InvalidBucketName,
    InvalidObjectKey,
    InvalidContentType,
    InvalidUserMetadata,
    InvalidUploadId,
    InvalidPartNumber,
    InvalidPart,
    InvalidPartOrder,
    EntityTooSmall,
    BucketNotFound,
    UploadNotFound,
    ChecksumMismatch,
    InputReadFailed,
    Conflict,
    CorruptMetadata,
    CorruptData,
    Unavailable,
};

pub const CreateOptions = struct {
    content_type: []const u8 = "application/octet-stream",
    user_metadata: []const object_domain.UserMetadata = &.{},
};

pub const UploadPartOptions = struct {
    expected_md5: ?[16]u8 = null,
    expected_sha256: ?[32]u8 = null,
    expected_crc64nvme: ?u64 = null,
    expected_checksum: ?checksum.Value = null,
};

pub const CompletePart = struct {
    number: u16,
    etag_md5: [16]u8,
};

pub const MultipartService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    bucket_store: bucket_store_port.BucketStore,
    multipart_store: multipart_store_port.MultipartStore,
    data_store: data_store_port.MultipartDataStore,
    objects: object_service.ObjectService,
    index: *index_module.MetadataIndex,
    state_mutex: *std.Io.Mutex,
    upload_locks: *ObjectLockPool,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        bucket_store: bucket_store_port.BucketStore,
        multipart_store: multipart_store_port.MultipartStore,
        data_store: data_store_port.MultipartDataStore,
        objects: object_service.ObjectService,
        index: *index_module.MetadataIndex,
        state_mutex: *std.Io.Mutex,
        upload_locks: *ObjectLockPool,
    ) MultipartService {
        return .{
            .allocator = allocator,
            .io = io,
            .bucket_store = bucket_store,
            .multipart_store = multipart_store,
            .data_store = data_store,
            .objects = objects,
            .index = index,
            .state_mutex = state_mutex,
            .upload_locks = upload_locks,
        };
    }

    pub fn create(
        self: MultipartService,
        bucket_name: []const u8,
        key: []const u8,
        options: CreateOptions,
    ) Error!multipart_domain.Upload {
        try validateAddress(bucket_name, key);
        object_domain.validateContentType(options.content_type) catch return error.InvalidContentType;
        object_domain.validateUserMetadata(options.user_metadata) catch return error.InvalidUserMetadata;

        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        const bucket = try self.loadBucketLocked(bucket_name);
        defer bucket.deinit(self.allocator);

        var upload_id: id.Uuid = undefined;
        var upload_id_buffer: [32]u8 = undefined;
        var attempts: usize = 0;
        while (true) : (attempts += 1) {
            if (attempts == 8) return error.Unavailable;
            upload_id = id.randomV4(self.io) catch return error.Unavailable;
            const upload_id_text = multipart_domain.formatUploadId(upload_id, &upload_id_buffer);
            if (!self.index.containsUpload(upload_id_text)) break;
        }
        const value: multipart_domain.View = .{
            .id = upload_id,
            .bucket_id = bucket.id,
            .bucket_name = bucket_name,
            .key = key,
            .content_type = options.content_type,
            .user_metadata = options.user_metadata,
            .initiated_at_unix_seconds = std.Io.Clock.real.now(self.io).toSeconds(),
            .parts = &.{},
        };
        var owned = multipart_domain.cloneFromView(self.allocator, value, 0) catch return error.OutOfMemory;
        errdefer owned.deinit(self.allocator);
        const upload_id_text = multipart_domain.formatUploadId(upload_id, &upload_id_buffer);
        var prepared = self.index.prepareUpload(upload_id_text) catch |err| return mapIndexError(err);
        defer prepared.deinit(self.index.allocator);
        const generation = self.multipart_store.put(self.allocator, value, .missing) catch |err| return mapStoreError(err);
        self.index.publishUpload(&prepared, generation);
        owned.metadata_generation = generation;
        return owned;
    }

    pub fn uploadPart(
        self: MultipartService,
        bucket_name: []const u8,
        key: []const u8,
        upload_id: []const u8,
        part_number: u16,
        source: byte_stream.Source,
        options: UploadPartOptions,
    ) Error!multipart_domain.Part {
        try validateMultipartAddress(bucket_name, key, upload_id);
        if (part_number < multipart_domain.min_part_number or part_number > multipart_domain.max_parts) {
            return error.InvalidPartNumber;
        }
        self.state_mutex.lockUncancelable(self.io);
        const initial = self.loadMatchingUploadLocked(bucket_name, key, upload_id) catch |err| {
            self.state_mutex.unlock(self.io);
            return err;
        };
        self.state_mutex.unlock(self.io);
        defer initial.deinit(self.allocator);

        const data_generation = id.randomV4(self.io) catch return error.Unavailable;
        const staged = self.data_store.stage(data_generation, source) catch |err| return mapStageError(err);
        var staged_pending = true;
        defer if (staged_pending) self.data_store.discard(staged.token);
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

        const upload_lock = self.upload_locks.get("multipart", upload_id);
        upload_lock.lockUncancelable(self.io);
        defer upload_lock.unlock(self.io);
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        const upload = try self.loadMatchingUploadLocked(bucket_name, key, upload_id);
        defer upload.deinit(self.allocator);
        if (!std.mem.eql(u8, &initial.bucket_id, &upload.bucket_id)) return error.UploadNotFound;

        const new_part: multipart_domain.Part = .{
            .number = part_number,
            .size = staged.size,
            .etag_md5 = staged.etag_md5,
            .checksum_sha256 = staged.checksum_sha256,
            .data_generation = data_generation,
            .last_modified_unix_seconds = std.Io.Clock.real.now(self.io).toSeconds(),
        };
        const position = lowerBoundPart(upload.parts, part_number);
        const replacing = position < upload.parts.len and upload.parts[position].number == part_number;
        const part_count = upload.parts.len + @intFromBool(!replacing);
        const parts = self.allocator.alloc(multipart_domain.Part, part_count) catch return error.OutOfMemory;
        defer self.allocator.free(parts);
        @memcpy(parts[0..position], upload.parts[0..position]);
        parts[position] = new_part;
        if (replacing) {
            @memcpy(parts[position + 1 ..], upload.parts[position + 1 ..]);
        } else {
            @memcpy(parts[position + 1 ..], upload.parts[position..]);
        }
        var view = upload.view();
        view.parts = parts;
        var prepared = self.index.prepareUpload(upload_id) catch |err| return mapIndexError(err);
        defer prepared.deinit(self.index.allocator);
        self.data_store.publish(staged, .{
            .upload_id = upload.id,
            .part_number = part_number,
            .data_generation = data_generation,
        }) catch |err| return mapPublishError(err);
        staged_pending = false;
        const generation = self.multipart_store.put(self.allocator, view, .{
            .exact = upload.metadata_generation,
        }) catch |err| return mapStoreError(err);
        self.index.publishUpload(&prepared, generation);
        return new_part;
    }

    pub fn listParts(
        self: MultipartService,
        bucket_name: []const u8,
        key: []const u8,
        upload_id: []const u8,
    ) Error!multipart_domain.Upload {
        try validateMultipartAddress(bucket_name, key, upload_id);
        const upload_lock = self.upload_locks.get("multipart", upload_id);
        upload_lock.lockSharedUncancelable(self.io);
        defer upload_lock.unlockShared(self.io);
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        return self.loadMatchingUploadLocked(bucket_name, key, upload_id);
    }

    pub fn complete(
        self: MultipartService,
        bucket_name: []const u8,
        key: []const u8,
        upload_id: []const u8,
        requested_parts: []const CompletePart,
    ) Error!object_domain.Object {
        try validateMultipartAddress(bucket_name, key, upload_id);
        if (requested_parts.len == 0 or requested_parts.len > multipart_domain.max_parts) return error.InvalidPart;
        var previous: u16 = 0;
        for (requested_parts) |part| {
            if (part.number < multipart_domain.min_part_number or part.number > multipart_domain.max_parts) return error.InvalidPart;
            if (part.number <= previous) return error.InvalidPartOrder;
            previous = part.number;
        }

        const upload_lock = self.upload_locks.get("multipart", upload_id);
        upload_lock.lockUncancelable(self.io);
        defer upload_lock.unlock(self.io);
        self.state_mutex.lockUncancelable(self.io);
        const upload = self.loadMatchingUploadLocked(bucket_name, key, upload_id) catch |err| {
            self.state_mutex.unlock(self.io);
            return err;
        };
        self.state_mutex.unlock(self.io);
        defer upload.deinit(self.allocator);

        const parts = self.allocator.alloc(multipart_domain.Part, requested_parts.len) catch return error.OutOfMemory;
        defer self.allocator.free(parts);
        var total_size: u64 = 0;
        var composite_hash = std.crypto.hash.Md5.init(.{});
        for (requested_parts, 0..) |requested, index| {
            const position = lowerBoundPart(upload.parts, requested.number);
            if (position >= upload.parts.len or upload.parts[position].number != requested.number) return error.InvalidPart;
            const stored = upload.parts[position];
            if (!std.crypto.timing_safe.eql([16]u8, stored.etag_md5, requested.etag_md5)) return error.InvalidPart;
            if (index + 1 < requested_parts.len and stored.size < multipart_domain.min_nonfinal_part_size) {
                return error.EntityTooSmall;
            }
            total_size = std.math.add(u64, total_size, stored.size) catch return error.InvalidPart;
            composite_hash.update(&stored.etag_md5);
            parts[index] = stored;
        }
        var composite_etag: [16]u8 = undefined;
        composite_hash.final(&composite_etag);
        var source = PartSource.init(self.data_store, upload.id, parts);
        const object = self.objects.put(bucket_name, key, source.interface(), .{
            .content_type = upload.content_type,
            .user_metadata = @ptrCast(upload.user_metadata),
            .multipart_etag = .{
                .digest = composite_etag,
                .part_count = @intCast(parts.len),
            },
        }) catch |err| return mapObjectError(err);
        errdefer object.deinit(self.allocator);
        if (object.size != total_size) return error.CorruptData;

        self.state_mutex.lockUncancelable(self.io);
        _ = self.multipart_store.tombstone(
            self.allocator,
            upload_id,
            upload.metadata_generation,
        ) catch |err| {
            self.state_mutex.unlock(self.io);
            return mapStoreError(err);
        };
        if (!self.index.removeUpload(upload_id)) {
            self.state_mutex.unlock(self.io);
            return error.CorruptMetadata;
        }
        self.state_mutex.unlock(self.io);
        self.data_store.deleteUpload(upload.id) catch {};
        return object;
    }

    pub fn abort(
        self: MultipartService,
        bucket_name: []const u8,
        key: []const u8,
        upload_id: []const u8,
    ) Error!void {
        try validateMultipartAddress(bucket_name, key, upload_id);
        const upload_lock = self.upload_locks.get("multipart", upload_id);
        upload_lock.lockUncancelable(self.io);
        defer upload_lock.unlock(self.io);
        self.state_mutex.lockUncancelable(self.io);
        const upload = self.loadMatchingUploadLocked(bucket_name, key, upload_id) catch |err| {
            self.state_mutex.unlock(self.io);
            return err;
        };
        _ = self.multipart_store.tombstone(self.allocator, upload_id, upload.metadata_generation) catch |err| {
            upload.deinit(self.allocator);
            self.state_mutex.unlock(self.io);
            return mapStoreError(err);
        };
        if (!self.index.removeUpload(upload_id)) {
            upload.deinit(self.allocator);
            self.state_mutex.unlock(self.io);
            return error.CorruptMetadata;
        }
        self.state_mutex.unlock(self.io);
        self.data_store.deleteUpload(upload.id) catch {};
        upload.deinit(self.allocator);
    }

    pub fn cleanupExpired(self: MultipartService, now_unix_seconds: i64, expiry_seconds: u64) Error!usize {
        const entries = self.index.uploadEntries();
        const upload_ids = self.allocator.alloc([]u8, entries.len) catch return error.OutOfMemory;
        var initialized: usize = 0;
        defer {
            for (upload_ids[0..initialized]) |upload_id| self.allocator.free(upload_id);
            self.allocator.free(upload_ids);
        }
        for (entries, 0..) |entry, index| {
            upload_ids[index] = self.allocator.dupe(u8, entry.name) catch return error.OutOfMemory;
            initialized += 1;
        }
        var removed: usize = 0;
        for (upload_ids) |upload_id| {
            if (try self.cleanupOneExpired(upload_id, now_unix_seconds, expiry_seconds)) removed += 1;
        }
        return removed;
    }

    fn cleanupOneExpired(self: MultipartService, upload_id: []const u8, now: i64, expiry_seconds: u64) Error!bool {
        const upload_lock = self.upload_locks.get("multipart", upload_id);
        upload_lock.lockUncancelable(self.io);
        defer upload_lock.unlock(self.io);
        self.state_mutex.lockUncancelable(self.io);
        const upload = self.loadUploadLocked(upload_id) catch |err| {
            self.state_mutex.unlock(self.io);
            if (err == error.UploadNotFound) return false;
            return err;
        };
        const expired = now >= upload.initiated_at_unix_seconds and
            @as(u64, @intCast(now - upload.initiated_at_unix_seconds)) >= expiry_seconds;
        if (!expired) {
            self.state_mutex.unlock(self.io);
            upload.deinit(self.allocator);
            return false;
        }
        _ = self.multipart_store.tombstone(self.allocator, upload_id, upload.metadata_generation) catch |err| {
            self.state_mutex.unlock(self.io);
            upload.deinit(self.allocator);
            return mapStoreError(err);
        };
        if (!self.index.removeUpload(upload_id)) {
            self.state_mutex.unlock(self.io);
            upload.deinit(self.allocator);
            return error.CorruptMetadata;
        }
        self.state_mutex.unlock(self.io);
        self.data_store.deleteUpload(upload.id) catch {};
        upload.deinit(self.allocator);
        return true;
    }

    fn loadMatchingUploadLocked(self: MultipartService, bucket_name: []const u8, key: []const u8, upload_id: []const u8) Error!multipart_domain.Upload {
        const bucket = try self.loadBucketLocked(bucket_name);
        defer bucket.deinit(self.allocator);
        const upload = try self.loadUploadLocked(upload_id);
        errdefer upload.deinit(self.allocator);
        if (!std.mem.eql(u8, upload.bucket_name, bucket_name) or
            !std.mem.eql(u8, upload.key, key) or
            !std.mem.eql(u8, &upload.bucket_id, &bucket.id)) return error.UploadNotFound;
        return upload;
    }

    fn loadUploadLocked(self: MultipartService, upload_id: []const u8) Error!multipart_domain.Upload {
        const indexed_generation = self.index.uploadGeneration(upload_id);
        const record = self.multipart_store.get(self.allocator, upload_id) catch |err| switch (err) {
            error.NotFound => {
                if (indexed_generation != null) return error.CorruptMetadata;
                return error.UploadNotFound;
            },
            else => return mapStoreError(err),
        };
        return switch (record) {
            .active => |upload| {
                if (indexed_generation == null or indexed_generation.? != upload.metadata_generation) {
                    upload.deinit(self.allocator);
                    return error.CorruptMetadata;
                }
                return upload;
            },
            .tombstone => {
                if (indexed_generation != null) return error.CorruptMetadata;
                return error.UploadNotFound;
            },
        };
    }

    fn loadBucketLocked(self: MultipartService, bucket_name: []const u8) Error!bucket_domain.Bucket {
        const indexed_generation = self.index.bucketGeneration(bucket_name) orelse return error.BucketNotFound;
        const record = self.bucket_store.get(self.allocator, bucket_name) catch |err| switch (err) {
            error.NotFound => return error.CorruptMetadata,
            else => return mapBucketStoreError(err),
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
};

const PartSource = struct {
    data_store: data_store_port.MultipartDataStore,
    upload_id: id.Uuid,
    parts: []const multipart_domain.Part,
    part_index: usize = 0,
    part_offset: u64 = 0,
    sha256: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),

    fn init(data_store: data_store_port.MultipartDataStore, upload_id: id.Uuid, parts: []const multipart_domain.Part) PartSource {
        return .{ .data_store = data_store, .upload_id = upload_id, .parts = parts };
    }

    fn interface(self: *PartSource) byte_stream.Source {
        return .{ .context = self, .vtable = &.{ .read = read } };
    }

    fn read(context: *anyopaque, buffer: []u8) byte_stream.Source.Error!usize {
        const self: *PartSource = @ptrCast(@alignCast(context));
        if (buffer.len == 0) return 0;
        while (self.part_index < self.parts.len) {
            const part = self.parts[self.part_index];
            if (self.part_offset == part.size) {
                try self.finishPart(part);
                continue;
            }
            const requested: usize = @intCast(@min(part.size - self.part_offset, buffer.len));
            var sink: BufferSink = .{ .buffer = buffer[0..requested] };
            self.data_store.readRange(.{
                .upload_id = self.upload_id,
                .part_number = part.number,
                .data_generation = part.data_generation,
            }, self.part_offset, requested, sink.interface()) catch return error.ReadFailed;
            if (sink.written != requested) return error.ReadFailed;
            self.sha256.update(buffer[0..requested]);
            self.part_offset += requested;
            if (self.part_offset == part.size) try self.finishPart(part);
            return requested;
        }
        return 0;
    }

    fn finishPart(self: *PartSource, part: multipart_domain.Part) byte_stream.Source.Error!void {
        var actual: [32]u8 = undefined;
        self.sha256.final(&actual);
        if (!std.crypto.timing_safe.eql([32]u8, actual, part.checksum_sha256)) return error.ReadFailed;
        self.part_index += 1;
        self.part_offset = 0;
        self.sha256 = std.crypto.hash.sha2.Sha256.init(.{});
    }
};

const BufferSink = struct {
    buffer: []u8,
    written: usize = 0,

    fn interface(self: *BufferSink) byte_stream.Sink {
        return .{ .context = self, .vtable = &.{ .write_all = writeAll } };
    }

    fn writeAll(context: *anyopaque, bytes: []const u8) byte_stream.Sink.Error!void {
        const self: *BufferSink = @ptrCast(@alignCast(context));
        if (bytes.len > self.buffer.len - self.written) return error.WriteFailed;
        @memcpy(self.buffer[self.written .. self.written + bytes.len], bytes);
        self.written += bytes.len;
    }
};

fn validateAddress(bucket_name: []const u8, key: []const u8) Error!void {
    bucket_domain.validateName(bucket_name) catch return error.InvalidBucketName;
    object_domain.validateKey(key) catch return error.InvalidObjectKey;
}

fn validateMultipartAddress(bucket_name: []const u8, key: []const u8, upload_id: []const u8) Error!void {
    try validateAddress(bucket_name, key);
    if (multipart_domain.parseUploadId(upload_id) == null) return error.InvalidUploadId;
}

fn lowerBoundPart(parts: []const multipart_domain.Part, part_number: u16) usize {
    var low: usize = 0;
    var high = parts.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (parts[middle].number < part_number) low = middle + 1 else high = middle;
    }
    return low;
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

fn mapStoreError(err: multipart_store_port.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotFound => error.UploadNotFound,
        error.Conflict => error.Conflict,
        error.InvalidValue => error.InvalidUploadId,
        error.CorruptMetadata => error.CorruptMetadata,
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
        else => error.Unavailable,
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
        else => error.Unavailable,
    };
}

fn mapObjectError(err: object_service.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidBucketName => error.InvalidBucketName,
        error.InvalidObjectKey => error.InvalidObjectKey,
        error.InvalidContentType => error.InvalidContentType,
        error.InvalidUserMetadata => error.InvalidUserMetadata,
        error.BucketNotFound => error.BucketNotFound,
        error.ChecksumMismatch => error.ChecksumMismatch,
        error.InputReadFailed => error.CorruptData,
        error.Conflict => error.Conflict,
        error.CorruptMetadata => error.CorruptMetadata,
        error.CorruptData => error.CorruptData,
        else => error.Unavailable,
    };
}
