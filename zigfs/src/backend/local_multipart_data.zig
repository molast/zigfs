const std = @import("std");
const fault_injection = @import("../common/fault_injection.zig");
const streaming = @import("../common/streaming.zig");
const durable = @import("../metadata/durable.zig");
const id = @import("../common/id.zig");
const multipart_domain = @import("../domain/multipart.zig");
const byte_stream = @import("../ports/byte_stream.zig");
const data_store_port = @import("../ports/multipart_data_store.zig");

const secret_box = @import("../auth/secret_box.zig");
const frames = @import("../application/object_encryption_frames.zig");
const encrypted_stream = @import("../application/object_encrypted_stream.zig");

pub const max_path_length: usize = 256;

pub const LocalMultipartDataStore = struct {
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    io: std.Io,
    buffer_size: usize,
    master_key: ?secret_box.Key = null,
    fault_injector: fault_injection.Injector = .disabled,

    pub fn setFaultInjectorForTesting(self: *LocalMultipartDataStore, injector: fault_injection.Injector) void {
        self.fault_injector = injector;
    }

    pub fn init(allocator: std.mem.Allocator, root: std.Io.Dir, io: std.Io, buffer_size: usize) LocalMultipartDataStore {
        return .{ .allocator = allocator, .root = root, .io = io, .buffer_size = buffer_size };
    }

    pub fn interface(self: *LocalMultipartDataStore) data_store_port.MultipartDataStore {
        return .{ .context = self, .vtable = &.{
            .cleanup_staged = cleanupStagedImpl,
            .stage = stageImpl,
            .stage_encrypted = stageEncryptedImpl,
            .publish = publishImpl,
            .discard = discardImpl,
            .stat = statImpl,
            .read_range = readRangeImpl,
            .delete_upload = deleteUploadImpl,
            .scan_generations = scanGenerationsImpl,
            .delete_generation = deleteGenerationImpl,
        } };
    }

    fn cleanupStagedImpl(context: *anyopaque) data_store_port.Error!usize {
        const self: *LocalMultipartDataStore = @ptrCast(@alignCast(context));
        var directory = self.root.openDir(self.io, ".zigfs/tmp", .{ .iterate = true }) catch return error.Unavailable;
        defer directory.close(self.io);
        var removed: usize = 0;
        var iterator = directory.iterate();
        while (iterator.next(self.io) catch return error.Unavailable) |entry| {
            if (entry.kind != .file or
                !std.mem.startsWith(u8, entry.name, "multipart-") or
                !std.mem.endsWith(u8, entry.name, ".data")) continue;
            directory.deleteFile(self.io, entry.name) catch return error.Unavailable;
            removed += 1;
        }
        if (removed != 0) durable.syncParent(self.root, self.io, ".zigfs/tmp/multipart-cleanup") catch return error.Unavailable;
        return removed;
    }

    fn stageImpl(context: *anyopaque, token: id.Uuid, source: byte_stream.Source) data_store_port.Error!data_store_port.Staged {
        const self: *LocalMultipartDataStore = @ptrCast(@alignCast(context));
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
        var sink: FileSink = .{ .file = file, .io = self.io };
        const copied = streaming.copyAndHash(self.allocator, self.buffer_size, source, sink.interface()) catch |err| return mapStreamingError(err);
        file.sync(self.io) catch return error.Unavailable;
        durable.syncParent(self.root, self.io, path) catch return error.Unavailable;
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

    fn stageEncryptedImpl(context: *anyopaque, token: id.Uuid, source: byte_stream.Source) data_store_port.Error!data_store_port.Staged {
        const self: *LocalMultipartDataStore = @ptrCast(@alignCast(context));
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
        var sink: FileSink = .{ .file = file, .io = self.io };
        var key = try self.partKey(token);
        defer std.crypto.secureZero(u8, &key);
        const copied = encrypted_stream.sealSource(self.allocator, self.io, key, &token, source, sink.interface()) catch return error.SourceReadFailed;
        file.sync(self.io) catch return error.Unavailable;
        durable.syncParent(self.root, self.io, path) catch return error.Unavailable;
        keep_file = true;
        return .{
            .token = token,
            .size = copied.plaintext_size,
            .etag_md5 = copied.etag_md5,
            .checksum_crc32 = copied.checksum_crc32,
            .checksum_crc32c = copied.checksum_crc32c,
            .checksum_sha256 = copied.checksum_sha256,
            .checksum_sha1 = copied.checksum_sha1,
            .checksum_crc64nvme = copied.checksum_crc64nvme,
        };
    }

    fn partKey(self: *LocalMultipartDataStore, token: id.Uuid) data_store_port.Error!secret_box.Key {
        const master = self.master_key orelse return error.Unavailable;
        var mac = std.crypto.auth.hmac.sha2.HmacSha256.init(&master);
        mac.update("ZIGFS-MULTIPART-DATA-V1:");
        mac.update(&token);
        var key: secret_box.Key = undefined;
        mac.final(&key);
        return key;
    }

    fn publishImpl(context: *anyopaque, staged: data_store_port.Staged, location: data_store_port.Location) data_store_port.Error!void {
        const self: *LocalMultipartDataStore = @ptrCast(@alignCast(context));
        if (!validLocation(location) or !std.mem.eql(u8, &staged.token, &location.data_generation)) return error.InvalidValue;
        var temporary_buffer: [max_path_length]u8 = undefined;
        const temporary_path = temporaryPath(staged.token, &temporary_buffer) catch return error.InvalidValue;
        var paths: PathSet = undefined;
        paths.format(location) catch return error.InvalidValue;
        self.root.createDirPath(self.io, paths.generationDirectory()) catch return error.Unavailable;
        try syncCreatedDirectories(self, &paths);
        self.root.renamePreserve(temporary_path, self.root, paths.dataPath(), self.io) catch |err| switch (err) {
            error.PathAlreadyExists => return error.Conflict,
            error.FileNotFound => return error.NotFound,
            else => return error.Unavailable,
        };
        try @import("multipart_part_meta.zig").write(self.allocator, self.root, self.io, paths.generationDirectory(), staged, location);
        durable.syncParent(self.root, self.io, paths.dataPath()) catch return error.Unavailable;
        durable.syncParent(self.root, self.io, temporary_path) catch return error.Unavailable;
    }

    fn discardImpl(context: *anyopaque, token: id.Uuid) void {
        const self: *LocalMultipartDataStore = @ptrCast(@alignCast(context));
        var buffer: [max_path_length]u8 = undefined;
        const path = temporaryPath(token, &buffer) catch return;
        self.root.deleteFile(self.io, path) catch return;
        durable.syncParent(self.root, self.io, path) catch {};
    }

    fn statImpl(context: *anyopaque, location: data_store_port.Location) data_store_port.Error!u64 {
        const self: *LocalMultipartDataStore = @ptrCast(@alignCast(context));
        if (!validLocation(location)) return error.InvalidValue;
        var paths: PathSet = undefined;
        paths.format(location) catch return error.InvalidValue;
        const stat = self.root.statFile(self.io, paths.dataPath(), .{}) catch |err| switch (err) {
            error.FileNotFound => return error.NotFound,
            else => return error.Unavailable,
        };
        if (stat.kind != .file) return error.CorruptData;
        if (location.encrypted) {
            if (stat.size < frames.header_length) return error.CorruptData;
            const count = (stat.size + frames.plaintext_frame_size + frames.header_length - 1) / (frames.plaintext_frame_size + frames.header_length);
            if (stat.size < (count - 1) * (frames.plaintext_frame_size + frames.header_length) + frames.header_length) return error.CorruptData;
            return stat.size - count * frames.header_length;
        }
        return stat.size;
    }

    fn readRangeImpl(context: *anyopaque, location: data_store_port.Location, offset: u64, length: u64, sink: byte_stream.Sink) data_store_port.Error!void {
        const self: *LocalMultipartDataStore = @ptrCast(@alignCast(context));
        if (!validLocation(location)) return error.InvalidValue;
        var paths: PathSet = undefined;
        paths.format(location) catch return error.InvalidValue;
        var file = self.root.openFile(self.io, paths.dataPath(), .{}) catch |err| switch (err) {
            error.FileNotFound => return error.NotFound,
            else => return error.Unavailable,
        };
        defer file.close(self.io);
        if (location.encrypted) {
            const size = try statImpl(context, location);
            if (offset > size or length > size - offset) return error.InvalidValue;
            return self.readEncryptedRange(file, location.data_generation, offset, length, sink);
        }
        const buffer = self.allocator.alloc(u8, self.buffer_size) catch return error.OutOfMemory;
        defer self.allocator.free(buffer);
        var position = offset;
        var remaining = length;
        while (remaining != 0) {
            const requested: usize = @intCast(@min(remaining, @as(u64, @intCast(buffer.len))));
            const count = file.readPositionalAll(self.io, buffer[0..requested], position) catch return error.Unavailable;
            if (count == 0) return error.CorruptData;
            sink.writeAll(buffer[0..count]) catch return error.SinkWriteFailed;
            position = std.math.add(u64, position, count) catch return error.InvalidValue;
            remaining -= count;
        }
    }

    fn readEncryptedRange(self: *LocalMultipartDataStore, file: std.Io.File, token: id.Uuid, offset: u64, length: u64, sink: byte_stream.Sink) data_store_port.Error!void {
        var key = try self.partKey(token);
        defer std.crypto.secureZero(u8, &key);
        var position = offset;
        var remaining = length;
        var verify_empty = offset == 0 and length == 0;
        while (remaining > 0 or verify_empty) {
            verify_empty = false;
            const index = position / frames.plaintext_frame_size;
            const physical = index * (frames.plaintext_frame_size + frames.header_length);
            var bytes: [frames.header_length]u8 = undefined;
            if ((file.readPositionalAll(self.io, &bytes, physical) catch return error.Unavailable) != bytes.len) return error.CorruptData;
            const header = frames.decodeHeader(&bytes) catch return error.CorruptData;
            if (header.index != index) return error.CorruptData;
            const ciphertext = self.allocator.alloc(u8, header.ciphertext_length) catch return error.OutOfMemory;
            defer self.allocator.free(ciphertext);
            if ((file.readPositionalAll(self.io, ciphertext, physical + frames.header_length) catch return error.Unavailable) != ciphertext.len) return error.CorruptData;
            const plaintext = frames.open(self.allocator, key, &token, .{ .index = index, .plaintext_length = header.plaintext_length, .nonce = header.nonce, .tag = header.tag, .ciphertext = ciphertext }) catch return error.CorruptData;
            defer {
                std.crypto.secureZero(u8, plaintext);
                self.allocator.free(plaintext);
            }
            if (remaining == 0) return;
            const start: usize = @intCast(position % frames.plaintext_frame_size);
            if (start >= plaintext.len) return error.CorruptData;
            const count = @min(remaining, plaintext.len - start);
            sink.writeAll(plaintext[start..][0..@intCast(count)]) catch return error.SinkWriteFailed;
            remaining -= count;
            position += count;
        }
    }

    fn deleteUploadImpl(context: *anyopaque, upload_id: id.Uuid) data_store_port.Error!void {
        const self: *LocalMultipartDataStore = @ptrCast(@alignCast(context));
        if (!id.isValidV4(upload_id)) return error.InvalidValue;
        if (self.fault_injector.trigger(.multipart_upload_cleanup)) return error.Unavailable;
        var upload_buffer: [max_path_length]u8 = undefined;
        var shard_buffer: [max_path_length]u8 = undefined;
        const upload_hex = std.fmt.bytesToHex(upload_id, .lower);
        const shard = std.fmt.bufPrint(&shard_buffer, "multipart/{s}", .{upload_hex[0..2]}) catch return error.InvalidValue;
        const upload = std.fmt.bufPrint(&upload_buffer, "{s}/{s}", .{ shard, &upload_hex }) catch return error.InvalidValue;
        var directory = self.root.openDir(self.io, upload, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return error.Unavailable,
        };
        directory.close(self.io);
        // Durable cleanup queue: detach the terminated upload in O(1), then
        // let startup/periodic GC reclaim its directory tree outside Complete.
        var trash_buffer: [max_path_length]u8 = undefined;
        const trash = std.fmt.bufPrint(&trash_buffer, ".zigfs/trash/multipart/upload-{s}", .{&upload_hex}) catch return error.InvalidValue;
        self.root.createDirPath(self.io, ".zigfs/trash/multipart") catch return error.Unavailable;
        self.root.renamePreserve(upload, self.root, trash, self.io) catch return error.Unavailable;
        durable.syncParent(self.root, self.io, upload) catch return error.Unavailable;
        durable.syncParent(self.root, self.io, trash) catch return error.Unavailable;
        self.root.deleteDir(self.io, shard) catch |err| switch (err) {
            error.FileNotFound, error.DirNotEmpty => return,
            else => return error.Unavailable,
        };
        durable.syncParent(self.root, self.io, shard) catch return error.Unavailable;
    }

    fn scanGenerationsImpl(context: *anyopaque, allocator: std.mem.Allocator, partition: ?u8) data_store_port.Error!data_store_port.ScanResult {
        const self: *LocalMultipartDataStore = @ptrCast(@alignCast(context));
        var generations: std.ArrayList(data_store_port.Generation) = .empty;
        errdefer generations.deinit(allocator);
        var root = self.root.openDir(self.io, "multipart", .{ .iterate = true }) catch return error.Unavailable;
        defer root.close(self.io);
        var shards = root.iterate();
        while (shards.next(self.io) catch return error.Unavailable) |shard_entry| {
            if (isIgnoredSystemEntry(shard_entry.name)) continue;
            if (shard_entry.kind != .directory) return error.CorruptData;
            const shard = parseShard(shard_entry.name) orelse return error.CorruptData;
            if (partition) |value| if (shard >> 4 != value) continue;
            try scanShard(self, allocator, shard_entry.name, shard, &generations);
        }
        return .{ .generations = generations.toOwnedSlice(allocator) catch return error.OutOfMemory };
    }

    fn deleteGenerationImpl(context: *anyopaque, location: data_store_port.Location) data_store_port.Error!bool {
        const self: *LocalMultipartDataStore = @ptrCast(@alignCast(context));
        if (!validLocation(location)) return error.InvalidValue;
        var paths: PathSet = undefined;
        paths.format(location) catch return error.InvalidValue;
        var directory = self.root.openDir(self.io, paths.generationDirectory(), .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return error.Unavailable,
        };
        var data_present = false;
        var iterator = directory.iterate();
        while (iterator.next(self.io) catch {
            directory.close(self.io);
            return error.Unavailable;
        }) |entry| {
            if (isIgnoredSystemEntry(entry.name)) continue;
            if (entry.kind == .file and std.mem.eql(u8, entry.name, "part.meta")) continue;
            if (entry.kind != .file or !std.mem.eql(u8, entry.name, "data") or data_present) {
                directory.close(self.io);
                return error.CorruptData;
            }
            data_present = true;
        }
        directory.close(self.io);
        var trash_buffer: [max_path_length]u8 = undefined;
        const trash_path = trashPath(location, &trash_buffer) catch return error.InvalidValue;
        self.root.createDirPath(self.io, ".zigfs/trash/multipart") catch return error.Unavailable;
        self.root.rename(paths.generationDirectory(), self.root, trash_path, self.io) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return error.Unavailable,
        };
        durable.syncParent(self.root, self.io, paths.generationDirectory()) catch return error.Unavailable;
        durable.syncParent(self.root, self.io, trash_path) catch return error.Unavailable;
        try @import("cleanup.zig").removeTrash(self.root, self.io, trash_path);
        durable.syncParent(self.root, self.io, trash_path) catch return error.Unavailable;
        pruneEmptyDirectory(self, paths.partDirectory());
        pruneEmptyDirectory(self, paths.uploadDirectory());
        pruneEmptyDirectory(self, paths.shardDirectory());
        return true;
    }
};

const FileSink = struct {
    file: std.Io.File,
    io: std.Io,

    fn interface(self: *FileSink) byte_stream.Sink {
        return .{ .context = self, .vtable = &.{ .write_all = writeAll } };
    }

    fn writeAll(context: *anyopaque, bytes: []const u8) byte_stream.Sink.Error!void {
        const self: *FileSink = @ptrCast(@alignCast(context));
        self.file.writeStreamingAll(self.io, bytes) catch return error.WriteFailed;
    }
};

pub const PathSet = struct {
    shard_buffer: [max_path_length]u8,
    upload_buffer: [max_path_length]u8,
    part_buffer: [max_path_length]u8,
    generation_buffer: [max_path_length]u8,
    data_buffer: [max_path_length]u8,
    shard_length: usize,
    upload_length: usize,
    part_length: usize,
    generation_length: usize,
    data_length: usize,

    pub fn format(self: *PathSet, location: data_store_port.Location) error{NoSpaceLeft}!void {
        const upload_hex = std.fmt.bytesToHex(location.upload_id, .lower);
        const generation_hex = std.fmt.bytesToHex(location.data_generation, .lower);
        const shard = try std.fmt.bufPrint(&self.shard_buffer, "multipart/{s}", .{upload_hex[0..2]});
        self.shard_length = shard.len;
        const upload = try std.fmt.bufPrint(&self.upload_buffer, "{s}/{s}", .{ shard, &upload_hex });
        self.upload_length = upload.len;
        const part = try std.fmt.bufPrint(&self.part_buffer, "{s}/{d}", .{ upload, location.part_number });
        self.part_length = part.len;
        const generation = try std.fmt.bufPrint(&self.generation_buffer, "{s}/{s}", .{ part, &generation_hex });
        self.generation_length = generation.len;
        const data = try std.fmt.bufPrint(&self.data_buffer, "{s}/data", .{generation});
        self.data_length = data.len;
    }

    fn shardDirectory(self: *const PathSet) []const u8 {
        return self.shard_buffer[0..self.shard_length];
    }
    fn uploadDirectory(self: *const PathSet) []const u8 {
        return self.upload_buffer[0..self.upload_length];
    }
    fn partDirectory(self: *const PathSet) []const u8 {
        return self.part_buffer[0..self.part_length];
    }
    pub fn generationDirectory(self: *const PathSet) []const u8 {
        return self.generation_buffer[0..self.generation_length];
    }
    pub fn dataPath(self: *const PathSet) []const u8 {
        return self.data_buffer[0..self.data_length];
    }
};

fn scanShard(
    self: *LocalMultipartDataStore,
    allocator: std.mem.Allocator,
    shard_name: []const u8,
    shard: u8,
    generations: *std.ArrayList(data_store_port.Generation),
) data_store_port.Error!void {
    var path_buffer: [max_path_length]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "multipart/{s}", .{shard_name}) catch return error.CorruptData;
    var directory = self.root.openDir(self.io, path, .{ .iterate = true }) catch return error.Unavailable;
    defer directory.close(self.io);
    var uploads = directory.iterate();
    while (uploads.next(self.io) catch return error.Unavailable) |entry| {
        if (isIgnoredSystemEntry(entry.name)) continue;
        if (entry.kind != .directory) return error.CorruptData;
        const upload_id = parseUuidHex(entry.name) orelse return error.CorruptData;
        if (upload_id[0] != shard) return error.CorruptData;
        try scanUpload(self, allocator, shard_name, entry.name, upload_id, generations);
    }
}

fn scanUpload(
    self: *LocalMultipartDataStore,
    allocator: std.mem.Allocator,
    shard_name: []const u8,
    upload_name: []const u8,
    upload_id: id.Uuid,
    generations: *std.ArrayList(data_store_port.Generation),
) data_store_port.Error!void {
    var path_buffer: [max_path_length]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "multipart/{s}/{s}", .{ shard_name, upload_name }) catch return error.CorruptData;
    var directory = self.root.openDir(self.io, path, .{ .iterate = true }) catch return error.Unavailable;
    defer directory.close(self.io);
    var parts = directory.iterate();
    while (parts.next(self.io) catch return error.Unavailable) |entry| {
        if (isIgnoredSystemEntry(entry.name)) continue;
        if (entry.kind != .directory) return error.CorruptData;
        const part_number = parsePartNumber(entry.name) orelse return error.CorruptData;
        try scanPart(self, allocator, shard_name, upload_name, upload_id, entry.name, part_number, generations);
    }
}

fn scanPart(
    self: *LocalMultipartDataStore,
    allocator: std.mem.Allocator,
    shard_name: []const u8,
    upload_name: []const u8,
    upload_id: id.Uuid,
    part_name: []const u8,
    part_number: u16,
    generations: *std.ArrayList(data_store_port.Generation),
) data_store_port.Error!void {
    var path_buffer: [max_path_length]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "multipart/{s}/{s}/{s}", .{ shard_name, upload_name, part_name }) catch return error.CorruptData;
    var directory = self.root.openDir(self.io, path, .{ .iterate = true }) catch return error.Unavailable;
    defer directory.close(self.io);
    var stored_generations = directory.iterate();
    while (stored_generations.next(self.io) catch return error.Unavailable) |entry| {
        if (isIgnoredSystemEntry(entry.name)) continue;
        if (entry.kind != .directory) return error.CorruptData;
        const data_generation = parseUuidHex(entry.name) orelse return error.CorruptData;
        const location: data_store_port.Location = .{
            .upload_id = upload_id,
            .part_number = part_number,
            .data_generation = data_generation,
        };
        const data_size = try inspectGeneration(self, location);
        generations.append(allocator, .{
            .location = location,
            .data_present = data_size != null,
            .data_size = data_size orelse 0,
        }) catch return error.OutOfMemory;
    }
}

fn inspectGeneration(self: *LocalMultipartDataStore, location: data_store_port.Location) data_store_port.Error!?u64 {
    var paths: PathSet = undefined;
    paths.format(location) catch return error.CorruptData;
    var directory = self.root.openDir(self.io, paths.generationDirectory(), .{ .iterate = true }) catch return error.Unavailable;
    defer directory.close(self.io);
    var data_present = false;
    var iterator = directory.iterate();
    while (iterator.next(self.io) catch return error.Unavailable) |entry| {
        if (isIgnoredSystemEntry(entry.name)) continue;
        if (entry.kind == .file and std.mem.eql(u8, entry.name, "part.meta")) continue;
        if (entry.kind != .file or !std.mem.eql(u8, entry.name, "data") or data_present) return error.CorruptData;
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
    var parsed: [1]u8 = undefined;
    _ = std.fmt.hexToBytes(&parsed, value) catch return null;
    return parsed[0];
}

fn parsePartNumber(value: []const u8) ?u16 {
    const number = std.fmt.parseInt(u16, value, 10) catch return null;
    if (number < multipart_domain.min_part_number or number > multipart_domain.max_parts) return null;
    return number;
}

fn pruneEmptyDirectory(self: *LocalMultipartDataStore, path: []const u8) void {
    @import("cleanup.zig").pruneEmpty(self.root, self.io, path);
}

fn temporaryPath(token: id.Uuid, buffer: *[max_path_length]u8) error{NoSpaceLeft}![]const u8 {
    const token_hex = std.fmt.bytesToHex(token, .lower);
    return std.fmt.bufPrint(buffer, ".zigfs/tmp/multipart-{s}.data", .{&token_hex});
}

fn trashPath(location: data_store_port.Location, buffer: *[max_path_length]u8) error{NoSpaceLeft}![]const u8 {
    const upload_hex = std.fmt.bytesToHex(location.upload_id, .lower);
    const generation_hex = std.fmt.bytesToHex(location.data_generation, .lower);
    return std.fmt.bufPrint(buffer, ".zigfs/trash/multipart/{s}-{d}-{s}", .{ &upload_hex, location.part_number, &generation_hex });
}

fn validLocation(location: data_store_port.Location) bool {
    return id.isValidV4(location.upload_id) and
        location.part_number >= multipart_domain.min_part_number and
        location.part_number <= multipart_domain.max_parts and
        id.isValidV4(location.data_generation);
}

fn syncCreatedDirectories(self: *LocalMultipartDataStore, paths: *const PathSet) data_store_port.Error!void {
    durable.syncParent(self.root, self.io, paths.shardDirectory()) catch return error.Unavailable;
    durable.syncParent(self.root, self.io, paths.uploadDirectory()) catch return error.Unavailable;
    durable.syncParent(self.root, self.io, paths.partDirectory()) catch return error.Unavailable;
    durable.syncParent(self.root, self.io, paths.generationDirectory()) catch return error.Unavailable;
}

fn mapStreamingError(err: streaming.Error) data_store_port.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SourceReadFailed => error.SourceReadFailed,
        error.InvalidBufferSize, error.SinkWriteFailed, error.SizeOverflow => error.Unavailable,
    };
}

test "local multipart data paths are opaque and stream ranges" {
    const test_streams = @import("../testing/streams.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".zigfs/tmp");
    try tmp.dir.createDirPath(std.testing.io, "multipart");
    var local = LocalMultipartDataStore.init(std.testing.allocator, tmp.dir, std.testing.io, streaming.min_buffer_size);
    const store = local.interface();
    const upload_id: id.Uuid = .{ 0, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 };
    const generation: id.Uuid = .{ 1, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 };
    var source: test_streams.SliceSource = .{ .bytes = "part-body" };
    const staged = try store.stage(generation, source.interface());
    const location: data_store_port.Location = .{ .upload_id = upload_id, .part_number = 7, .data_generation = generation };
    try store.publish(staged, location);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "multipart/.DS_Store", .data = "desktop metadata" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "multipart/.hidden", .data = "desktop metadata" });
    var sink = test_streams.CollectingSink.init(std.testing.allocator);
    defer sink.deinit();
    try store.readRange(location, 2, 4, sink.interface());
    try std.testing.expectEqualStrings("rt-b", sink.bytes.items);

    const matching_partition = try store.scanGenerationPartition(std.testing.allocator, upload_id[0] >> 4);
    defer matching_partition.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), matching_partition.generations.len);
    try std.testing.expectEqual(@as(u64, "part-body".len), matching_partition.generations[0].data_size);
    const other_partition = try store.scanGenerationPartition(
        std.testing.allocator,
        (upload_id[0] >> 4) + 1,
    );
    defer other_partition.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), other_partition.generations.len);

    try store.deleteUpload(upload_id);
    try std.testing.expectError(error.NotFound, store.readRange(location, 0, 1, sink.interface()));
}

test "encrypted multipart data hides plaintext supports cross frame ranges and rejects tampering" {
    const test_streams = @import("../testing/streams.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".zigfs/tmp");
    try tmp.dir.createDirPath(std.testing.io, "multipart");
    var local = LocalMultipartDataStore.init(std.testing.allocator, tmp.dir, std.testing.io, streaming.min_buffer_size);
    local.master_key = @splat(42);
    const store = local.interface();
    const token: id.Uuid = .{ 0, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 };
    const body = try std.testing.allocator.alloc(u8, frames.plaintext_frame_size + 123);
    defer std.testing.allocator.free(body);
    @memset(body, 'q');
    var source = test_streams.SliceSource.init(body);
    const staged = try store.stageEncrypted(token, source.interface());
    const location: data_store_port.Location = .{ .upload_id = token, .part_number = 1, .data_generation = token, .encrypted = true };
    try store.publish(staged, location);
    try std.testing.expectEqual(body.len, try store.stat(location));
    var paths: PathSet = undefined;
    try paths.format(location);
    const disk = try std.testing.allocator.alloc(u8, body.len + 2 * frames.header_length);
    defer std.testing.allocator.free(disk);
    const bytes = try tmp.dir.readFile(std.testing.io, paths.dataPath(), disk);
    try std.testing.expect(std.mem.indexOf(u8, bytes, body[0..64]) == null);
    var sink = test_streams.CollectingSink.init(std.testing.allocator);
    defer sink.deinit();
    try store.readRange(location, frames.plaintext_frame_size - 5, 100, sink.interface());
    try std.testing.expectEqualSlices(u8, body[0..100], sink.bytes.items);
    disk[frames.header_length + 3] ^= 1;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = paths.dataPath(), .data = disk });
    try std.testing.expectError(error.CorruptData, store.readRange(location, 0, 1, sink.interface()));
}
