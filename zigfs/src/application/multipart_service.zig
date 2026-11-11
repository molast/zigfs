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
    InvalidListOptions,
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

pub const max_list_uploads: usize = 1000;

pub const ListUploadsOptions = struct {
    prefix: []const u8 = "",
    delimiter: ?[]const u8 = null,
    key_marker: ?[]const u8 = null,
    upload_id_marker: ?[]const u8 = null,
    max_uploads: usize = max_list_uploads,
};

pub const UploadSummary = struct {
    upload_id: []u8,
    key: []u8,
    initiated_at_unix_seconds: i64,

    pub fn deinit(self: UploadSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.upload_id);
        allocator.free(self.key);
    }
};

pub const ListUploadsResult = struct {
    uploads: []UploadSummary,
    common_prefixes: [][]u8,
    is_truncated: bool,
    next_key_marker: ?[]u8,
    next_upload_id_marker: ?[]u8,

    pub fn deinit(self: ListUploadsResult, allocator: std.mem.Allocator) void {
        for (self.uploads) |upload| upload.deinit(allocator);
        allocator.free(self.uploads);
        for (self.common_prefixes) |prefix| allocator.free(prefix);
        allocator.free(self.common_prefixes);
        if (self.next_key_marker) |marker| allocator.free(marker);
        if (self.next_upload_id_marker) |marker| allocator.free(marker);
    }
};

pub const CreateOptions = struct {
    encryption: ?bool = null,
    kms_key: ?[]const u8 = null,
    kms_selection: ?@import("kms.zig").Envelope = null,
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
        var kms_selection = options.kms_selection;
        if (kms_selection == null) if (options.kms_key orelse (if (options.encryption == null and bucket.encryption == .kms) @as(?[]const u8, bucket.kms_key_id.slice()) else null)) |key_name| {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            kms_selection = (self.objects.kms orelse return error.Unavailable).select(arena.allocator(), key_name) catch return error.Unavailable;
        };
        const value: multipart_domain.View = .{
            .id = upload_id,
            .bucket_id = bucket.id,
            .encryption = kms_selection != null or options.kms_key != null or (options.encryption orelse (bucket.encryption != .disabled)),
            .kms = kms_selection,
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
        const staged = (if (initial.encryption orelse false) self.data_store.stageEncrypted(data_generation, source) else self.data_store.stage(data_generation, source)) catch |err| return mapStageError(err);
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
            .encrypted = initial.encryption orelse false,
            .upload_id = upload.id,
            .part_number = part_number,
            .data_generation = data_generation,
        }) catch |err| return mapPublishError(err);
        staged_pending = false;
        const generation = self.multipart_store.put(self.allocator, view, .{
            .exact = upload.metadata_generation,
        }) catch |err| return mapStoreError(err);
        self.index.publishUpload(&prepared, generation);
        if (replacing) {
            const replaced = upload.parts[position];
            if (!std.mem.eql(u8, &replaced.data_generation, &data_generation)) {
                _ = self.data_store.deleteGeneration(.{
                    .upload_id = upload.id,
                    .part_number = replaced.number,
                    .data_generation = replaced.data_generation,
                }) catch {};
            }
        }
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

    pub fn listUploads(
        self: MultipartService,
        bucket_name: []const u8,
        options: ListUploadsOptions,
    ) Error!ListUploadsResult {
        bucket_domain.validateName(bucket_name) catch return error.InvalidBucketName;
        if (options.max_uploads > max_list_uploads or
            (options.delimiter != null and options.delimiter.?.len == 0) or
            (options.upload_id_marker != null and options.key_marker == null))
        {
            return error.InvalidListOptions;
        }

        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        const bucket = try self.loadBucketLocked(bucket_name);
        defer bucket.deinit(self.allocator);

        var candidates: std.ArrayList(UploadSummary) = .empty;
        defer {
            for (candidates.items) |upload| upload.deinit(self.allocator);
            candidates.deinit(self.allocator);
        }
        for (self.index.uploadEntries()) |entry| {
            const upload = try self.loadUploadLocked(entry.name);
            defer upload.deinit(self.allocator);
            if (!std.mem.eql(u8, upload.bucket_name, bucket_name) or
                !std.mem.eql(u8, &upload.bucket_id, &bucket.id) or
                !std.mem.startsWith(u8, upload.key, options.prefix))
            {
                continue;
            }
            const upload_id = self.allocator.dupe(u8, entry.name) catch return error.OutOfMemory;
            errdefer self.allocator.free(upload_id);
            const key = self.allocator.dupe(u8, upload.key) catch return error.OutOfMemory;
            candidates.append(self.allocator, .{
                .upload_id = upload_id,
                .key = key,
                .initiated_at_unix_seconds = upload.initiated_at_unix_seconds,
            }) catch {
                self.allocator.free(key);
                return error.OutOfMemory;
            };
        }
        std.mem.sort(UploadSummary, candidates.items, {}, lessThanUploadSummary);

        var uploads: std.ArrayList(UploadSummary) = .empty;
        errdefer {
            for (uploads.items) |upload| upload.deinit(self.allocator);
            uploads.deinit(self.allocator);
        }
        var common_prefixes: std.ArrayList([]u8) = .empty;
        errdefer {
            for (common_prefixes.items) |prefix| self.allocator.free(prefix);
            common_prefixes.deinit(self.allocator);
        }
        var emitted: usize = 0;
        var is_truncated = false;
        var last_key: ?[]const u8 = null;
        var last_upload_id: ?[]const u8 = null;

        for (candidates.items) |candidate| {
            if (!isAfterUploadMarker(candidate, options.key_marker, options.upload_id_marker)) continue;
            if (options.delimiter) |delimiter| {
                const suffix = candidate.key[options.prefix.len..];
                if (std.mem.indexOf(u8, suffix, delimiter)) |position| {
                    const prefix_end = options.prefix.len + position + delimiter.len;
                    const common_prefix = candidate.key[0..prefix_end];
                    if (options.key_marker) |marker| {
                        if (std.mem.order(u8, common_prefix, marker) != .gt) continue;
                    }
                    if (common_prefixes.items.len != 0 and
                        std.mem.eql(u8, common_prefixes.items[common_prefixes.items.len - 1], common_prefix))
                    {
                        continue;
                    }
                    if (emitted == options.max_uploads) {
                        is_truncated = true;
                        break;
                    }
                    const owned_prefix = self.allocator.dupe(u8, common_prefix) catch return error.OutOfMemory;
                    common_prefixes.append(self.allocator, owned_prefix) catch {
                        self.allocator.free(owned_prefix);
                        return error.OutOfMemory;
                    };
                    emitted += 1;
                    last_key = owned_prefix;
                    last_upload_id = null;
                    continue;
                }
            }
            if (emitted == options.max_uploads) {
                is_truncated = true;
                break;
            }
            const upload_id = self.allocator.dupe(u8, candidate.upload_id) catch return error.OutOfMemory;
            errdefer self.allocator.free(upload_id);
            const key = self.allocator.dupe(u8, candidate.key) catch return error.OutOfMemory;
            uploads.append(self.allocator, .{
                .upload_id = upload_id,
                .key = key,
                .initiated_at_unix_seconds = candidate.initiated_at_unix_seconds,
            }) catch {
                self.allocator.free(key);
                return error.OutOfMemory;
            };
            emitted += 1;
            last_key = key;
            last_upload_id = upload_id;
        }

        const next_key_marker = if (is_truncated and last_key != null)
            self.allocator.dupe(u8, last_key.?) catch return error.OutOfMemory
        else
            null;
        errdefer if (next_key_marker) |marker| self.allocator.free(marker);
        const next_upload_id_marker = if (is_truncated and last_upload_id != null)
            self.allocator.dupe(u8, last_upload_id.?) catch return error.OutOfMemory
        else
            null;
        const owned_uploads = uploads.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        errdefer {
            for (owned_uploads) |upload| upload.deinit(self.allocator);
            self.allocator.free(owned_uploads);
        }
        const owned_common_prefixes = common_prefixes.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        errdefer {
            for (owned_common_prefixes) |common_prefix| self.allocator.free(common_prefix);
            self.allocator.free(owned_common_prefixes);
        }
        return .{
            .uploads = owned_uploads,
            .common_prefixes = owned_common_prefixes,
            .is_truncated = is_truncated,
            .next_key_marker = next_key_marker,
            .next_upload_id_marker = next_upload_id_marker,
        };
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
        var request_hash = std.crypto.hash.sha2.Sha256.init(.{});
        var previous: u16 = 0;
        for (requested_parts) |part| {
            if (part.number < multipart_domain.min_part_number or part.number > multipart_domain.max_parts) return error.InvalidPart;
            if (part.number <= previous) return error.InvalidPartOrder;
            previous = part.number;
            var number_bytes: [2]u8 = undefined;
            std.mem.writeInt(u16, &number_bytes, part.number, .little);
            request_hash.update(&number_bytes);
            request_hash.update(&part.etag_md5);
        }

        var parts_digest: [32]u8 = undefined;
        request_hash.final(&parts_digest);

        const upload_lock = self.upload_locks.get("multipart", upload_id);
        upload_lock.lockUncancelable(self.io);
        defer upload_lock.unlock(self.io);
        if (try self.completedObject(bucket_name, key, upload_id, parts_digest)) |completed| {
            errdefer completed.deinit(self.allocator);
            self.state_mutex.lockUncancelable(self.io);
            const residual = self.loadMatchingUploadLocked(bucket_name, key, upload_id) catch |err| {
                self.state_mutex.unlock(self.io);
                if (err == error.UploadNotFound) return completed;
                return err;
            };
            self.state_mutex.unlock(self.io);
            defer residual.deinit(self.allocator);
            try self.terminateCompletedUpload(residual, bucket_name, key, upload_id);
            return completed;
        }
        self.state_mutex.lockUncancelable(self.io);
        const upload = self.loadMatchingUploadLocked(bucket_name, key, upload_id) catch |err| {
            self.state_mutex.unlock(self.io);
            return err;
        };
        self.state_mutex.unlock(self.io);
        defer upload.deinit(self.allocator);

        const parts = self.allocator.alloc(object_domain.MultipartPart, requested_parts.len) catch return error.OutOfMemory;
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
            parts[index] = .{
                .number = stored.number,
                .etag_md5 = stored.etag_md5,
                .size = stored.size,
                .checksum_sha256 = stored.checksum_sha256,
                .data_generation = stored.data_generation,
                .encrypted = upload.encryption orelse false,
            };
        }
        var composite_etag: [16]u8 = undefined;
        composite_hash.final(&composite_etag);
        const object = self.objects.commitMultipart(bucket_name, key, .{
            .upload_id = upload.id,
            .parts = parts,
        }, total_size, .{
            .content_type = upload.content_type,
            .encryption = upload.encryption,
            .kms_selection = upload.kms,
            .user_metadata = @ptrCast(upload.user_metadata),
            .parts_digest = parts_digest,
            .etag = .{
                .digest = composite_etag,
                .part_count = @intCast(parts.len),
            },
        }) catch |err| return mapObjectError(err);
        errdefer object.deinit(self.allocator);
        if (object.size != total_size) return error.CorruptData;

        try self.terminateCompletedUpload(upload, bucket_name, key, upload_id);
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

    pub fn lookupCompleted(self: MultipartService, bucket: []const u8, key: []const u8, upload_id: []const u8, parts: []const CompletePart) Error!?object_domain.Object {
        try validateMultipartAddress(bucket, key, upload_id);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        for (parts) |part| {
            var number: [2]u8 = undefined;
            std.mem.writeInt(u16, &number, part.number, .little);
            hash.update(&number);
            hash.update(&part.etag_md5);
        }
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        return self.completedObject(bucket, key, upload_id, digest);
    }

    fn completedObject(self: MultipartService, bucket_name: []const u8, key: []const u8, upload_id: []const u8, digest: [32]u8) Error!?object_domain.Object {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        const bucket = try self.loadBucketLocked(bucket_name);
        defer bucket.deinit(self.allocator);
        const history = self.objects.object_store.getHistory(self.allocator, bucket_name, key) catch |err| switch (err) {
            error.NotFound => return null,
            else => return error.Unavailable,
        };
        defer history.deinit(self.allocator);
        const upload_uuid = multipart_domain.parseUploadId(upload_id) orelse return error.InvalidUploadId;
        switch (history) {
            .active => |record| for (record.entries) |entry| switch (entry) {
                .object => |object| if (object.multipart_completion) |completion| {
                    if (!std.mem.eql(u8, &completion.upload_id, &upload_uuid)) continue;
                    if (!std.mem.eql(u8, &object.bucket_id, &bucket.id)) return null;
                    if (!std.mem.eql(u8, &completion.parts_digest, &digest)) return error.InvalidPart;
                    return object_domain.cloneFromView(self.allocator, object.view(), record.metadata_generation) catch return error.OutOfMemory;
                },
                else => {},
            },
            else => {},
        }
        return null;
    }

    fn terminateCompletedUpload(self: MultipartService, upload: multipart_domain.Upload, bucket_name: []const u8, key: []const u8, upload_id: []const u8) Error!void {
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
        self.cleanupCompletedUpload(bucket_name, key, upload.id) catch |err| {
            std.log.warn("multipart cleanup deferred to GC: upload={s} error={s}", .{ upload_id, @errorName(err) });
        };
    }

    fn cleanupCompletedUpload(self: MultipartService, bucket: []const u8, key: []const u8, upload_id: id.Uuid) !void {
        // A retry of an older completion may still have a version referencing
        // these parts. Leave those generations to reference-aware GC.
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        const record = try self.objects.object_store.getHistory(self.allocator, bucket, key);
        defer record.deinit(self.allocator);
        switch (record) {
            .active => |history| for (history.entries) |entry| {
                switch (entry) {
                    .object => |object| if (object.multipart_manifest) |manifest| {
                        if (std.mem.eql(u8, &manifest.upload_id, &upload_id)) return;
                    },
                    .delete_marker => {},
                }
            },
            .tombstone => {},
        }
        try self.data_store.deleteUpload(upload_id);
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

fn lessThanUploadSummary(_: void, left: UploadSummary, right: UploadSummary) bool {
    const key_order = std.mem.order(u8, left.key, right.key);
    if (key_order != .eq) return key_order == .lt;
    return std.mem.order(u8, left.upload_id, right.upload_id) == .lt;
}

fn isAfterUploadMarker(
    upload: UploadSummary,
    key_marker: ?[]const u8,
    upload_id_marker: ?[]const u8,
) bool {
    const marker = key_marker orelse return true;
    return switch (std.mem.order(u8, upload.key, marker)) {
        .lt => false,
        .gt => true,
        .eq => if (upload_id_marker) |upload_marker|
            std.mem.order(u8, upload.upload_id, upload_marker) == .gt
        else
            false,
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
