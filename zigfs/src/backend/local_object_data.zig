const std = @import("std");
const streaming = @import("../common/streaming.zig");
const durable = @import("../metadata/durable.zig");
const fault_injection = @import("../common/fault_injection.zig");
const id = @import("../common/id.zig");
const byte_stream = @import("../ports/byte_stream.zig");
const data_store_port = @import("../ports/object_data_store.zig");
const secret_box = @import("../auth/secret_box.zig");
const encrypted_stream = @import("../application/object_encrypted_stream.zig");
const encryption_frames = @import("../application/object_encryption_frames.zig");

pub const max_path_length: usize = 192;

pub const LocalObjectDataStore = struct {
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    io: std.Io,
    buffer_size: usize,
    fault_injector: fault_injection.Injector = .disabled,

    pub fn init(
        allocator: std.mem.Allocator,
        root: std.Io.Dir,
        io: std.Io,
        buffer_size: usize,
    ) LocalObjectDataStore {
        return .{
            .allocator = allocator,
            .root = root,
            .io = io,
            .buffer_size = buffer_size,
        };
    }

    pub fn setFaultInjectorForTesting(
        self: *LocalObjectDataStore,
        injector: fault_injection.Injector,
    ) void {
        self.fault_injector = injector;
    }

    pub fn interface(self: *LocalObjectDataStore) data_store_port.ObjectDataStore {
        return .{ .context = self, .vtable = &.{
            .cleanup_staged = cleanupStagedImpl,
            .stage = stageImpl,
            .stage_encrypted = stageEncryptedImpl,
            .publish = publishImpl,
            .discard = discardImpl,
            .stat = statImpl,
            .read = readImpl,
            .read_encrypted = readEncryptedImpl,
            .read_encrypted_range = readEncryptedRangeImpl,
            .read_range = readRangeImpl,
            .scan_generations = scanGenerationsImpl,
            .delete_generation = deleteGenerationImpl,
        } };
    }

    fn cleanupStagedImpl(context: *anyopaque) data_store_port.Error!usize {
        const self: *LocalObjectDataStore = @ptrCast(@alignCast(context));
        var directory = self.root.openDir(self.io, ".zigfs/tmp", .{ .iterate = true }) catch {
            return error.Unavailable;
        };
        defer directory.close(self.io);
        var removed: usize = 0;
        var iterator = directory.iterate();
        while (iterator.next(self.io) catch return error.Unavailable) |entry| {
            if (entry.kind != .file or
                !std.mem.startsWith(u8, entry.name, "object-") or
                !std.mem.endsWith(u8, entry.name, ".data"))
            {
                continue;
            }
            directory.deleteFile(self.io, entry.name) catch return error.Unavailable;
            removed += 1;
        }
        if (removed > 0) {
            durable.syncParent(self.root, self.io, ".zigfs/tmp/object-cleanup") catch {
                return error.Unavailable;
            };
        }
        return removed;
    }

    fn stageImpl(
        context: *anyopaque,
        token: id.Uuid,
        source: byte_stream.Source,
    ) data_store_port.Error!data_store_port.Staged {
        const self: *LocalObjectDataStore = @ptrCast(@alignCast(context));
        if (!id.isValidV4(token)) return error.InvalidValue;
        var path_buffer: [max_path_length]u8 = undefined;
        const path = temporaryPath(token, &path_buffer) catch return error.InvalidValue;
        var file = self.root.createFile(self.io, path, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => return error.Conflict,
            else => return error.Unavailable,
        };
        var keep_file = false;
        errdefer if (!keep_file) self.root.deleteFile(self.io, path) catch {};
        defer file.close(self.io);

        var file_sink: FileSink = .{
            .file = file,
            .io = self.io,
            .fault_injector = self.fault_injector,
        };
        const copied = streaming.copyAndHash(
            self.allocator,
            self.buffer_size,
            source,
            file_sink.interface(),
        ) catch |err| return mapStageError(err);
        file.sync(self.io) catch return error.Unavailable;
        durable.syncParent(self.root, self.io, path) catch return error.Unavailable;
        if (self.fault_injector.trigger(.object_stage_synced)) {
            keep_file = true;
            return error.Unavailable;
        }
        keep_file = true;
        return .{
            .token = token,
            .size = copied.size,
            .etag_md5 = copied.etag_md5,
            .checksum_crc32 = copied.checksum_crc32,
            .checksum_crc32c = copied.checksum_crc32c,
            .checksum_sha256 = copied.checksum_sha256,
            .checksum_sha1 = copied.checksum_sha1,
            .checksum_crc64nvme = copied.checksum_crc64nvme,
        };
    }

    fn stageEncryptedImpl(
        context: *anyopaque,
        token: id.Uuid,
        key: secret_box.Key,
        associated_data: []const u8,
        source: byte_stream.Source,
    ) data_store_port.Error!data_store_port.Staged {
        const self: *LocalObjectDataStore = @ptrCast(@alignCast(context));
        if (!id.isValidV4(token)) return error.InvalidValue;
        var path_buffer: [max_path_length]u8 = undefined;
        const path = temporaryPath(token, &path_buffer) catch return error.InvalidValue;
        var file = self.root.createFile(self.io, path, .{ .read = true, .truncate = false, .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => return error.Conflict,
            else => return error.Unavailable,
        };
        var keep_file = false;
        errdefer if (!keep_file) self.root.deleteFile(self.io, path) catch {};
        defer file.close(self.io);
        var file_sink: FileSink = .{ .file = file, .io = self.io, .fault_injector = self.fault_injector };
        const result = encrypted_stream.sealSource(self.allocator, self.io, key, associated_data, source, file_sink.interface()) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SourceReadFailed => error.SourceReadFailed,
            error.SinkWriteFailed => error.SinkWriteFailed,
            error.SizeOverflow => error.InvalidValue,
            else => error.Unavailable,
        };
        file.sync(self.io) catch return error.Unavailable;
        durable.syncParent(self.root, self.io, path) catch return error.Unavailable;
        keep_file = true;
        return .{
            .token = token,
            .size = result.plaintext_size,
            .etag_md5 = result.etag_md5,
            .checksum_crc32 = result.checksum_crc32,
            .checksum_crc32c = result.checksum_crc32c,
            .checksum_sha256 = result.checksum_sha256,
            .checksum_sha1 = result.checksum_sha1,
            .checksum_crc64nvme = result.checksum_crc64nvme,
        };
    }

    fn publishImpl(
        context: *anyopaque,
        staged: data_store_port.Staged,
        location: data_store_port.Location,
    ) data_store_port.Error!void {
        const self: *LocalObjectDataStore = @ptrCast(@alignCast(context));
        if (!validLocation(location) or
            !std.mem.eql(u8, &staged.token, &location.data_generation))
        {
            return error.InvalidValue;
        }
        var temporary_buffer: [max_path_length]u8 = undefined;
        const temporary_path = temporaryPath(staged.token, &temporary_buffer) catch {
            return error.InvalidValue;
        };
        var paths: PathSet = undefined;
        paths.format(location) catch return error.InvalidValue;
        self.root.createDirPath(self.io, paths.generationDirectory()) catch {
            return error.Unavailable;
        };
        syncCreatedDirectories(self, &paths) catch return error.Unavailable;
        self.root.renamePreserve(
            temporary_path,
            self.root,
            paths.dataPath(),
            self.io,
        ) catch |err| switch (err) {
            error.PathAlreadyExists => return error.Conflict,
            error.FileNotFound => return error.NotFound,
            else => return error.Unavailable,
        };
        durable.syncParent(self.root, self.io, paths.dataPath()) catch return error.Unavailable;
        durable.syncParent(self.root, self.io, temporary_path) catch return error.Unavailable;
        if (self.fault_injector.trigger(.object_generation_published)) {
            return error.Unavailable;
        }
    }

    fn discardImpl(context: *anyopaque, token: id.Uuid) void {
        const self: *LocalObjectDataStore = @ptrCast(@alignCast(context));
        var path_buffer: [max_path_length]u8 = undefined;
        const path = temporaryPath(token, &path_buffer) catch return;
        self.root.deleteFile(self.io, path) catch return;
        durable.syncParent(self.root, self.io, path) catch {};
    }

    fn statImpl(
        context: *anyopaque,
        location: data_store_port.Location,
    ) data_store_port.Error!u64 {
        const self: *LocalObjectDataStore = @ptrCast(@alignCast(context));
        if (!validLocation(location)) return error.InvalidValue;
        var paths: PathSet = undefined;
        paths.format(location) catch return error.InvalidValue;
        const stat = self.root.statFile(self.io, paths.dataPath(), .{}) catch |err| switch (err) {
            error.FileNotFound => return error.NotFound,
            else => return error.Unavailable,
        };
        if (stat.kind != .file) return error.CorruptData;
        return stat.size;
    }

    fn readImpl(
        context: *anyopaque,
        location: data_store_port.Location,
        integrity: data_store_port.Integrity,
        sink: byte_stream.Sink,
    ) data_store_port.Error!void {
        const self: *LocalObjectDataStore = @ptrCast(@alignCast(context));
        if (!validLocation(location)) return error.InvalidValue;
        var paths: PathSet = undefined;
        paths.format(location) catch return error.InvalidValue;
        var file = self.root.openFile(self.io, paths.dataPath(), .{}) catch |err| switch (err) {
            error.FileNotFound => return error.NotFound,
            else => return error.Unavailable,
        };
        defer file.close(self.io);
        var file_source: FileSource = .{ .file = file, .io = self.io };
        const copied = streaming.copyAndHash(
            self.allocator,
            self.buffer_size,
            file_source.interface(),
            sink,
        ) catch |err| return mapReadError(err);
        if (copied.size != integrity.size or
            !std.mem.eql(u8, &copied.checksum_sha256, &integrity.checksum_sha256))
        {
            return error.CorruptData;
        }
    }

    fn readEncryptedImpl(
        context: *anyopaque,
        location: data_store_port.Location,
        key: secret_box.Key,
        associated_data: []const u8,
        plaintext_size: u64,
        sink: byte_stream.Sink,
    ) data_store_port.Error!void {
        const self: *LocalObjectDataStore = @ptrCast(@alignCast(context));
        if (!validLocation(location)) return error.InvalidValue;
        var paths: PathSet = undefined;
        paths.format(location) catch return error.InvalidValue;
        const file = self.root.openFile(self.io, paths.dataPath(), .{}) catch |err| switch (err) {
            error.FileNotFound => return error.NotFound,
            else => return error.Unavailable,
        };
        defer file.close(self.io);
        var source: FileSource = .{ .file = file, .io = self.io };
        var header: [encryption_frames.header_length]u8 = undefined;
        var frame_index: u64 = 0;
        var total: u64 = 0;
        while (total < plaintext_size or (plaintext_size == 0 and frame_index == 0)) {
            readExact(source.interface(), &header) catch return error.CorruptData;
            const decoded = encryption_frames.decodeHeader(&header) catch return error.CorruptData;
            if (decoded.index != frame_index) return error.CorruptData;
            const ciphertext = self.allocator.alloc(u8, decoded.ciphertext_length) catch return error.OutOfMemory;
            defer self.allocator.free(ciphertext);
            readExact(source.interface(), ciphertext) catch return error.CorruptData;
            const plaintext = encryption_frames.open(self.allocator, key, associated_data, .{
                .index = decoded.index,
                .plaintext_length = decoded.plaintext_length,
                .nonce = decoded.nonce,
                .tag = decoded.tag,
                .ciphertext = ciphertext,
            }) catch return error.CorruptData;
            defer {
                std.crypto.secureZero(u8, plaintext);
                self.allocator.free(plaintext);
            }
            sink.writeAll(plaintext) catch return error.SinkWriteFailed;
            total = std.math.add(u64, total, decoded.plaintext_length) catch return error.CorruptData;
            frame_index += 1;
            if (decoded.plaintext_length < encryption_frames.plaintext_frame_size) break;
        }
        if (total != plaintext_size) return error.CorruptData;
    }

    fn readEncryptedRangeImpl(
        context: *anyopaque,
        location: data_store_port.Location,
        key: secret_box.Key,
        associated_data: []const u8,
        plaintext_size: u64,
        offset: u64,
        length: u64,
        sink: byte_stream.Sink,
    ) data_store_port.Error!void {
        if (offset > plaintext_size or length > plaintext_size - offset) return error.InvalidValue;
        const self: *LocalObjectDataStore = @ptrCast(@alignCast(context));
        if (!validLocation(location)) return error.InvalidValue;
        var paths: PathSet = undefined;
        paths.format(location) catch return error.InvalidValue;
        const file = self.root.openFile(self.io, paths.dataPath(), .{}) catch |err| switch (err) {
            error.FileNotFound => return error.NotFound,
            else => return error.Unavailable,
        };
        defer file.close(self.io);
        var source: FileSource = .{ .file = file, .io = self.io };
        var header: [encryption_frames.header_length]u8 = undefined;
        var frame_index: u64 = 0;
        var total: u64 = 0;
        var remaining = length;
        while (total < plaintext_size or (plaintext_size == 0 and frame_index == 0)) {
            readExact(source.interface(), &header) catch return error.CorruptData;
            const decoded = encryption_frames.decodeHeader(&header) catch return error.CorruptData;
            if (decoded.index != frame_index) return error.CorruptData;
            const frame_start = total;
            const frame_end = total + decoded.plaintext_length;
            const overlaps = offset < frame_end and offset + length > frame_start;
            const ciphertext = self.allocator.alloc(u8, decoded.ciphertext_length) catch return error.OutOfMemory;
            defer self.allocator.free(ciphertext);
            readExact(source.interface(), ciphertext) catch return error.CorruptData;
            if (overlaps and remaining != 0) {
                const plaintext = encryption_frames.open(self.allocator, key, associated_data, .{ .index = decoded.index, .plaintext_length = decoded.plaintext_length, .nonce = decoded.nonce, .tag = decoded.tag, .ciphertext = ciphertext }) catch return error.CorruptData;
                defer { std.crypto.secureZero(u8, plaintext); self.allocator.free(plaintext); }
                const from = @max(offset, frame_start) - frame_start;
                const take = @min(@as(u64, decoded.plaintext_length) - from, remaining);
                sink.writeAll(plaintext[@intCast(from) .. @intCast(from + take)]) catch return error.SinkWriteFailed;
                remaining -= take;
            }
            total += decoded.plaintext_length;
            frame_index += 1;
            if (decoded.plaintext_length < encryption_frames.plaintext_frame_size) break;
        }
        if (total != plaintext_size or remaining != 0) return error.CorruptData;
    }

    fn readRangeImpl(
        context: *anyopaque,
        location: data_store_port.Location,
        offset: u64,
        length: u64,
        sink: byte_stream.Sink,
    ) data_store_port.Error!void {
        const self: *LocalObjectDataStore = @ptrCast(@alignCast(context));
        if (!validLocation(location)) return error.InvalidValue;
        var paths: PathSet = undefined;
        paths.format(location) catch return error.InvalidValue;
        var file = self.root.openFile(self.io, paths.dataPath(), .{}) catch |err| switch (err) {
            error.FileNotFound => return error.NotFound,
            else => return error.Unavailable,
        };
        defer file.close(self.io);
        const buffer = self.allocator.alloc(u8, self.buffer_size) catch return error.OutOfMemory;
        defer self.allocator.free(buffer);
        var position = offset;
        var remaining = length;
        while (remaining != 0) {
            const requested: usize = @intCast(@min(
                remaining,
                @as(u64, @intCast(buffer.len)),
            ));
            const count = file.readPositionalAll(
                self.io,
                buffer[0..requested],
                position,
            ) catch return error.Unavailable;
            if (count == 0) return error.CorruptData;
            sink.writeAll(buffer[0..count]) catch return error.SinkWriteFailed;
            position = std.math.add(u64, position, count) catch return error.InvalidValue;
            remaining -= count;
        }
    }

    fn scanGenerationsImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        partition: ?u8,
    ) data_store_port.Error!data_store_port.ScanResult {
        const self: *LocalObjectDataStore = @ptrCast(@alignCast(context));
        var generations: std.ArrayList(data_store_port.Generation) = .empty;
        errdefer generations.deinit(allocator);
        var objects = self.root.openDir(self.io, "objects", .{ .iterate = true }) catch {
            return error.Unavailable;
        };
        defer objects.close(self.io);
        var iterator = objects.iterate();
        while (iterator.next(self.io) catch return error.Unavailable) |entry| {
            if (isIgnoredSystemEntry(entry.name)) continue;
            if (entry.kind != .directory) return error.CorruptData;
            const bucket_id = parseUuidHex(entry.name) orelse return error.CorruptData;
            try scanBucket(self, allocator, entry.name, bucket_id, partition, &generations);
        }
        return .{
            .generations = generations.toOwnedSlice(allocator) catch return error.OutOfMemory,
        };
    }

    fn deleteGenerationImpl(
        context: *anyopaque,
        location: data_store_port.Location,
    ) data_store_port.Error!bool {
        const self: *LocalObjectDataStore = @ptrCast(@alignCast(context));
        if (!validLocation(location)) return error.InvalidValue;
        var paths: PathSet = undefined;
        paths.format(location) catch return error.InvalidValue;

        var directory = self.root.openDir(
            self.io,
            paths.generationDirectory(),
            .{ .iterate = true },
        ) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return error.Unavailable,
        };
        var data_present = false;
        var iterator = directory.iterate();
        while (iterator.next(self.io) catch {
            directory.close(self.io);
            return error.Unavailable;
        }) |entry| {
            if (entry.kind != .file or
                !std.mem.eql(u8, entry.name, "data") or
                data_present)
            {
                directory.close(self.io);
                return error.CorruptData;
            }
            data_present = true;
        }
        directory.close(self.io);

        var trash_buffer: [max_path_length]u8 = undefined;
        const trash_path = trashPath(location, &trash_buffer) catch return error.InvalidValue;
        self.root.createDirPath(self.io, ".zigfs/trash/objects") catch return error.Unavailable;
        self.root.rename(paths.generationDirectory(), self.root, trash_path, self.io) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return error.Unavailable,
        };
        durable.syncParent(self.root, self.io, paths.generationDirectory()) catch return error.Unavailable;
        durable.syncParent(self.root, self.io, trash_path) catch return error.Unavailable;
        self.root.deleteTree(self.io, trash_path) catch return error.Unavailable;
        durable.syncParent(self.root, self.io, trash_path) catch return error.Unavailable;
        pruneEmptyDirectory(self, paths.objectDirectory());
        pruneEmptyDirectory(self, paths.shardDirectory());
        pruneEmptyDirectory(self, paths.bucketDirectory());
        return true;
    }
};

fn scanBucket(
    self: *LocalObjectDataStore,
    allocator: std.mem.Allocator,
    bucket_name: []const u8,
    bucket_id: id.Uuid,
    partition: ?u8,
    generations: *std.ArrayList(data_store_port.Generation),
) data_store_port.Error!void {
    var path_buffer: [max_path_length]u8 = undefined;
    const bucket_path = std.fmt.bufPrint(&path_buffer, "objects/{s}", .{bucket_name}) catch {
        return error.CorruptData;
    };
    var bucket = self.root.openDir(self.io, bucket_path, .{ .iterate = true }) catch {
        return error.Unavailable;
    };
    defer bucket.close(self.io);
    var iterator = bucket.iterate();
    while (iterator.next(self.io) catch return error.Unavailable) |entry| {
        if (isIgnoredSystemEntry(entry.name)) continue;
        if (entry.kind != .directory) return error.CorruptData;
        const shard = parseShard(entry.name) orelse return error.CorruptData;
        if (partition) |value| if (shard >> 4 != value) continue;
        try scanShard(
            self,
            allocator,
            bucket_name,
            bucket_id,
            entry.name,
            shard,
            generations,
        );
    }
}

fn scanShard(
    self: *LocalObjectDataStore,
    allocator: std.mem.Allocator,
    bucket_name: []const u8,
    bucket_id: id.Uuid,
    shard_name: []const u8,
    shard: u8,
    generations: *std.ArrayList(data_store_port.Generation),
) data_store_port.Error!void {
    var path_buffer: [max_path_length]u8 = undefined;
    const shard_path = std.fmt.bufPrint(
        &path_buffer,
        "objects/{s}/{s}",
        .{ bucket_name, shard_name },
    ) catch return error.CorruptData;
    var directory = self.root.openDir(self.io, shard_path, .{ .iterate = true }) catch {
        return error.Unavailable;
    };
    defer directory.close(self.io);
    var iterator = directory.iterate();
    while (iterator.next(self.io) catch return error.Unavailable) |entry| {
        if (isIgnoredSystemEntry(entry.name)) continue;
        if (entry.kind != .directory) return error.CorruptData;
        const object_id = parseUuidHex(entry.name) orelse return error.CorruptData;
        if (object_id[0] != shard) return error.CorruptData;
        try scanObject(
            self,
            allocator,
            bucket_name,
            bucket_id,
            shard_name,
            entry.name,
            object_id,
            generations,
        );
    }
}

fn scanObject(
    self: *LocalObjectDataStore,
    allocator: std.mem.Allocator,
    bucket_name: []const u8,
    bucket_id: id.Uuid,
    shard_name: []const u8,
    object_name: []const u8,
    object_id: id.Uuid,
    generations: *std.ArrayList(data_store_port.Generation),
) data_store_port.Error!void {
    var path_buffer: [max_path_length]u8 = undefined;
    const object_path = std.fmt.bufPrint(
        &path_buffer,
        "objects/{s}/{s}/{s}",
        .{ bucket_name, shard_name, object_name },
    ) catch return error.CorruptData;
    var directory = self.root.openDir(self.io, object_path, .{ .iterate = true }) catch {
        return error.Unavailable;
    };
    defer directory.close(self.io);
    var iterator = directory.iterate();
    while (iterator.next(self.io) catch return error.Unavailable) |entry| {
        if (isIgnoredSystemEntry(entry.name)) continue;
        if (entry.kind != .directory) return error.CorruptData;
        const data_generation = parseUuidHex(entry.name) orelse return error.CorruptData;
        const location: data_store_port.Location = .{
            .bucket_id = bucket_id,
            .object_id = object_id,
            .data_generation = data_generation,
        };
        const data_present = try inspectGeneration(self, location);
        generations.append(allocator, .{
            .location = location,
            .data_present = data_present != null,
            .data_size = data_present orelse 0,
        }) catch return error.OutOfMemory;
    }
}

fn inspectGeneration(
    self: *LocalObjectDataStore,
    location: data_store_port.Location,
) data_store_port.Error!?u64 {
    var paths: PathSet = undefined;
    paths.format(location) catch return error.CorruptData;
    var directory = self.root.openDir(
        self.io,
        paths.generationDirectory(),
        .{ .iterate = true },
    ) catch return error.Unavailable;
    defer directory.close(self.io);
    var data_present = false;
    var iterator = directory.iterate();
    while (iterator.next(self.io) catch return error.Unavailable) |entry| {
        if (isIgnoredSystemEntry(entry.name)) continue;
        if (entry.kind != .file or
            !std.mem.eql(u8, entry.name, "data") or
            data_present)
        {
            return error.CorruptData;
        }
        data_present = true;
    }
    if (!data_present) return null;
    const stat = self.root.statFile(self.io, paths.dataPath(), .{}) catch return error.Unavailable;
    if (stat.kind != .file) return error.CorruptData;
    return stat.size;
}

fn isIgnoredSystemEntry(name: []const u8) bool {
    // Finder and other desktop tools may leave hidden files in a data root.
    // They are not ZigFS-managed entries and must not make a healthy store
    // fail its reachability scan.
    return std.mem.startsWith(u8, name, ".");
}

fn parseUuidHex(value: []const u8) ?id.Uuid {
    if (value.len != 32) return null;
    for (value) |character| {
        if (!std.ascii.isDigit(character) and (character < 'a' or character > 'f')) return null;
    }
    var parsed: id.Uuid = undefined;
    _ = std.fmt.hexToBytes(&parsed, value) catch return null;
    if (!id.isValidV4(parsed)) return null;
    return parsed;
}

fn parseShard(value: []const u8) ?u8 {
    if (value.len != 2) return null;
    for (value) |character| {
        if (!std.ascii.isDigit(character) and (character < 'a' or character > 'f')) return null;
    }
    var parsed: [1]u8 = undefined;
    _ = std.fmt.hexToBytes(&parsed, value) catch return null;
    return parsed[0];
}

fn pruneEmptyDirectory(self: *LocalObjectDataStore, path: []const u8) void {
    self.root.deleteDir(self.io, path) catch |err| switch (err) {
        error.FileNotFound, error.DirNotEmpty => return,
        else => return,
    };
    durable.syncParent(self.root, self.io, path) catch {};
}

const FileSink = struct {
    file: std.Io.File,
    io: std.Io,
    fault_injector: fault_injection.Injector,

    fn interface(self: *FileSink) byte_stream.Sink {
        return .{ .context = self, .vtable = &.{ .write_all = writeAll } };
    }

    fn writeAll(context: *anyopaque, bytes: []const u8) byte_stream.Sink.Error!void {
        const self: *FileSink = @ptrCast(@alignCast(context));
        if (self.fault_injector.trigger(.object_data_write)) return error.WriteFailed;
        self.file.writeStreamingAll(self.io, bytes) catch return error.WriteFailed;
    }
};

const FileSource = struct {
    file: std.Io.File,
    io: std.Io,
    offset: u64 = 0,

    fn interface(self: *FileSource) byte_stream.Source {
        return .{ .context = self, .vtable = &.{ .read = read } };
    }

    fn read(context: *anyopaque, buffer: []u8) byte_stream.Source.Error!usize {
        const self: *FileSource = @ptrCast(@alignCast(context));
        const length = self.file.readPositionalAll(self.io, buffer, self.offset) catch {
            return error.ReadFailed;
        };
        self.offset = std.math.add(u64, self.offset, length) catch return error.ReadFailed;
        return length;
    }
};

const PathSet = struct {
    bucket_buffer: [max_path_length]u8,
    shard_buffer: [max_path_length]u8,
    object_buffer: [max_path_length]u8,
    generation_buffer: [max_path_length]u8,
    data_buffer: [max_path_length]u8,
    bucket_length: usize,
    shard_length: usize,
    object_length: usize,
    generation_length: usize,
    data_length: usize,

    fn format(self: *PathSet, location: data_store_port.Location) error{NoSpaceLeft}!void {
        const bucket_hex = std.fmt.bytesToHex(location.bucket_id, .lower);
        const object_hex = std.fmt.bytesToHex(location.object_id, .lower);
        const generation_hex = std.fmt.bytesToHex(location.data_generation, .lower);
        const bucket = try std.fmt.bufPrint(&self.bucket_buffer, "objects/{s}", .{&bucket_hex});
        self.bucket_length = bucket.len;
        const shard = try std.fmt.bufPrint(&self.shard_buffer, "{s}/{s}", .{ bucket, object_hex[0..2] });
        self.shard_length = shard.len;
        const object = try std.fmt.bufPrint(&self.object_buffer, "{s}/{s}", .{ shard, &object_hex });
        self.object_length = object.len;
        const generation = try std.fmt.bufPrint(&self.generation_buffer, "{s}/{s}", .{ object, &generation_hex });
        self.generation_length = generation.len;
        const data = try std.fmt.bufPrint(&self.data_buffer, "{s}/data", .{generation});
        self.data_length = data.len;
    }

    fn bucketDirectory(self: *const PathSet) []const u8 {
        return self.bucket_buffer[0..self.bucket_length];
    }

    fn shardDirectory(self: *const PathSet) []const u8 {
        return self.shard_buffer[0..self.shard_length];
    }

    fn objectDirectory(self: *const PathSet) []const u8 {
        return self.object_buffer[0..self.object_length];
    }

    fn generationDirectory(self: *const PathSet) []const u8 {
        return self.generation_buffer[0..self.generation_length];
    }

    fn dataPath(self: *const PathSet) []const u8 {
        return self.data_buffer[0..self.data_length];
    }
};

fn temporaryPath(
    token: id.Uuid,
    buffer: *[max_path_length]u8,
) error{NoSpaceLeft}![]const u8 {
    const token_hex = std.fmt.bytesToHex(token, .lower);
    return std.fmt.bufPrint(buffer, ".zigfs/tmp/object-{s}.data", .{&token_hex});
}

fn trashPath(location: data_store_port.Location, buffer: *[max_path_length]u8) error{NoSpaceLeft}![]const u8 {
    const bucket_hex = std.fmt.bytesToHex(location.bucket_id, .lower);
    const object_hex = std.fmt.bytesToHex(location.object_id, .lower);
    const generation_hex = std.fmt.bytesToHex(location.data_generation, .lower);
    return std.fmt.bufPrint(buffer, ".zigfs/trash/objects/{s}-{s}-{s}", .{ &bucket_hex, &object_hex, &generation_hex });
}

fn validLocation(location: data_store_port.Location) bool {
    return id.isValidV4(location.bucket_id) and
        id.isValidV4(location.object_id) and
        id.isValidV4(location.data_generation);
}

fn syncCreatedDirectories(
    self: *LocalObjectDataStore,
    paths: *const PathSet,
) !void {
    try durable.syncParent(self.root, self.io, paths.bucketDirectory());
    try durable.syncParent(self.root, self.io, paths.shardDirectory());
    try durable.syncParent(self.root, self.io, paths.objectDirectory());
    try durable.syncParent(self.root, self.io, paths.generationDirectory());
}

fn mapStageError(err: streaming.Error) data_store_port.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SourceReadFailed => error.SourceReadFailed,
        error.InvalidBufferSize, error.SinkWriteFailed, error.SizeOverflow => error.Unavailable,
    };
}

fn readExact(source: byte_stream.Source, buffer: []u8) byte_stream.Source.Error!void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const count = try source.read(buffer[offset..]);
        if (count == 0 or count > buffer.len - offset) return error.ReadFailed;
        offset += count;
    }
}

fn mapReadError(err: streaming.Error) data_store_port.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SinkWriteFailed => error.SinkWriteFailed,
        error.InvalidBufferSize, error.SourceReadFailed, error.SizeOverflow => error.Unavailable,
    };
}

const TestSliceSource = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn interface(self: *TestSliceSource) byte_stream.Source {
        return .{ .context = self, .vtable = &.{ .read = read } };
    }

    fn read(context: *anyopaque, buffer: []u8) byte_stream.Source.Error!usize {
        const self: *TestSliceSource = @ptrCast(@alignCast(context));
        const length = @min(buffer.len, self.bytes.len - self.offset);
        @memcpy(buffer[0..length], self.bytes[self.offset..][0..length]);
        self.offset += length;
        return length;
    }
};

const TestCollectingSink = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestCollectingSink) void {
        self.bytes.deinit(self.allocator);
    }

    fn interface(self: *TestCollectingSink) byte_stream.Sink {
        return .{ .context = self, .vtable = &.{ .write_all = writeAll } };
    }

    fn writeAll(context: *anyopaque, bytes: []const u8) byte_stream.Sink.Error!void {
        const self: *TestCollectingSink = @ptrCast(@alignCast(context));
        self.bytes.appendSlice(self.allocator, bytes) catch return error.OutOfMemory;
    }
};

fn testLocation() data_store_port.Location {
    return .{
        .bucket_id = .{ 0, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
        .object_id = .{ 1, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
        .data_generation = .{ 2, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
    };
}

test "local object data store stages publishes and verifies a generation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".zigfs/tmp");
    try tmp.dir.createDirPath(std.testing.io, "objects");
    var local = LocalObjectDataStore.init(
        std.testing.allocator,
        tmp.dir,
        std.testing.io,
        streaming.min_buffer_size,
    );
    const store = local.interface();
    const location = testLocation();
    var source: TestSliceSource = .{ .bytes = "object-body" };
    const staged = try store.stage(location.data_generation, source.interface());
    try std.testing.expectEqual(@as(u64, 11), staged.size);
    try store.publish(staged, location);
    try std.testing.expectEqual(staged.size, try store.stat(location));

    var sink: TestCollectingSink = .{ .allocator = std.testing.allocator };
    defer sink.deinit();
    try store.read(location, .{
        .size = staged.size,
        .checksum_sha256 = staged.checksum_sha256,
    }, sink.interface());
    try std.testing.expectEqualStrings("object-body", sink.bytes.items);

    var range_sink: TestCollectingSink = .{ .allocator = std.testing.allocator };
    defer range_sink.deinit();
    try store.readRange(location, 3, 6, range_sink.interface());
    try std.testing.expectEqualStrings("ect-bo", range_sink.bytes.items);
}

test "local object data paths never contain an object key and staged cleanup is scoped" {
    var paths: PathSet = undefined;
    try paths.format(testLocation());
    try std.testing.expect(std.mem.indexOf(u8, paths.dataPath(), "../") == null);
    try std.testing.expect(std.mem.indexOf(u8, paths.dataPath(), "object-key") == null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".zigfs/tmp");
    try tmp.dir.createDirPath(std.testing.io, "objects");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".zigfs/tmp/object-stale.data",
        .data = "stale",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".zigfs/tmp/metadata.record",
        .data = "keep",
    });
    var local = LocalObjectDataStore.init(
        std.testing.allocator,
        tmp.dir,
        std.testing.io,
        streaming.min_buffer_size,
    );
    try std.testing.expectEqual(@as(usize, 1), try local.interface().cleanupStaged());
    _ = try tmp.dir.statFile(std.testing.io, ".zigfs/tmp/metadata.record", .{});
}

test "local object data store detects size and checksum corruption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".zigfs/tmp");
    try tmp.dir.createDirPath(std.testing.io, "objects");
    var local = LocalObjectDataStore.init(
        std.testing.allocator,
        tmp.dir,
        std.testing.io,
        streaming.min_buffer_size,
    );
    const store = local.interface();
    const location = testLocation();
    var source: TestSliceSource = .{ .bytes = "object-body" };
    const staged = try store.stage(location.data_generation, source.interface());
    try store.publish(staged, location);
    var sink: TestCollectingSink = .{ .allocator = std.testing.allocator };
    defer sink.deinit();
    try std.testing.expectError(error.CorruptData, store.read(location, .{
        .size = staged.size + 1,
        .checksum_sha256 = staged.checksum_sha256,
    }, sink.interface()));

    var paths: PathSet = undefined;
    try paths.format(location);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = paths.dataPath(),
        .data = "object-bodx",
    });
    var checksum_sink: TestCollectingSink = .{ .allocator = std.testing.allocator };
    defer checksum_sink.deinit();
    try std.testing.expectError(error.CorruptData, store.read(location, .{
        .size = staged.size,
        .checksum_sha256 = staged.checksum_sha256,
    }, checksum_sink.interface()));
}

test "local object data store scans and idempotently deletes generations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".zigfs/tmp");
    try tmp.dir.createDirPath(std.testing.io, "objects");
    var local = LocalObjectDataStore.init(
        std.testing.allocator,
        tmp.dir,
        std.testing.io,
        streaming.min_buffer_size,
    );
    const store = local.interface();
    const location = testLocation();
    var source: TestSliceSource = .{ .bytes = "object-body" };
    const staged = try store.stage(location.data_generation, source.interface());
    try store.publish(staged, location);

    var empty_location = location;
    empty_location.data_generation = .{ 3, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 };
    var empty_paths: PathSet = undefined;
    try empty_paths.format(empty_location);
    try tmp.dir.createDirPath(std.testing.io, empty_paths.generationDirectory());
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "objects/.DS_Store", .data = "desktop metadata" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "objects/.hidden", .data = "desktop metadata" });

    const scan = try store.scanGenerations(std.testing.allocator);
    defer scan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), scan.generations.len);
    var found_data = false;
    var found_empty = false;
    for (scan.generations) |generation| {
        if (std.mem.eql(u8, &generation.location.data_generation, &location.data_generation)) {
            found_data = generation.data_present;
        } else if (std.mem.eql(
            u8,
            &generation.location.data_generation,
            &empty_location.data_generation,
        )) {
            found_empty = !generation.data_present;
        }
    }
    try std.testing.expect(found_data);
    try std.testing.expect(found_empty);

    const matching_partition = try store.scanGenerationPartition(std.testing.allocator, location.object_id[0] >> 4);
    defer matching_partition.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), matching_partition.generations.len);
    const other_partition = try store.scanGenerationPartition(
        std.testing.allocator,
        (location.object_id[0] >> 4) + 1,
    );
    defer other_partition.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), other_partition.generations.len);

    try std.testing.expect(try store.deleteGeneration(location));
    try std.testing.expect(!(try store.deleteGeneration(location)));
    try std.testing.expect(try store.deleteGeneration(empty_location));
    try std.testing.expect(!(try store.deleteGeneration(empty_location)));
    try std.testing.expectError(error.NotFound, store.stat(location));
}

test "local object data scan refuses malformed managed paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".zigfs/tmp");
    try tmp.dir.createDirPath(std.testing.io, "objects/not-a-uuid");
    var local = LocalObjectDataStore.init(
        std.testing.allocator,
        tmp.dir,
        std.testing.io,
        streaming.min_buffer_size,
    );
    try std.testing.expectError(
        error.CorruptData,
        local.interface().scanGenerations(std.testing.allocator),
    );
}
