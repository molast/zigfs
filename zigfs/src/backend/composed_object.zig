//! Durable, self-contained multipart objects. Immutable part files are hard-linked
//! into a staged generation; publication never reads or rewrites payload bytes.
const std = @import("std");
const id = @import("../common/id.zig");
const domain = @import("../domain/object.zig");
const port = @import("../ports/object_data_store.zig");
const stream = @import("../ports/byte_stream.zig");
const box = @import("../auth/secret_box.zig");
const frames = @import("../application/object_encryption_frames.zig");
const durable = @import("../metadata/durable.zig");
const part_paths = @import("local_multipart_data.zig");
const magic = "ZFCOMP01";
const Part = struct { offset: u64 = 0, number: u16 = 0, size: u64, sha256: [32]u8, generation: id.Uuid, key: ?box.Key = null };
const Manifest = struct { version: u8 = 1, layout: enum { segments } = .segments, checksum_type: enum { per_segment_sha256 } = .per_segment_sha256, size: u64, parts: []const Part };
pub const Encryption = port.ComposeEncryption;

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    master_key: ?box.Key,
    buffer_size: usize,

    pub fn stage(self: Store, token: id.Uuid, path: []const u8, source: domain.MultipartManifestView, encryption: ?Encryption) (port.Error || error{UnsupportedComposition})!port.Staged {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const parts = a.alloc(Part, source.parts.len) catch return error.OutOfMemory;
        defer for (parts) |*part| {
            if (part.key) |*key| std.crypto.secureZero(u8, key);
        };
        @memset(parts, .{ .size = 0, .sha256 = @splat(0), .generation = @splat(0) });
        self.root.createDir(self.io, path, .default_dir) catch return error.Unavailable;
        errdefer self.root.deleteTree(self.io, path) catch {};
        var dir = self.root.openDir(self.io, path, .{}) catch return error.Unavailable;
        defer dir.close(self.io);
        var size: u64 = 0;
        for (source.parts, 0..) |part, i| {
            if (part.encrypted != (encryption != null)) return error.InvalidValue;
            var paths: part_paths.PathSet = undefined;
            paths.format(.{ .upload_id = source.upload_id, .part_number = part.number, .data_generation = part.data_generation, .encrypted = part.encrypted }) catch return error.InvalidValue;
            try @import("multipart_part_meta.zig").verify(self.root, self.io, paths.generationDirectory(), source.upload_id, part);
            const name = std.fmt.allocPrint(a, "part-{d}", .{i}) catch return error.OutOfMemory;
            // Both namespaces are below one data root. No payload copy and no
            // dependency on the lifetime of the temporary upload directory.
            self.root.hardLink(paths.dataPath(), dir, name, self.io, .{}) catch |err| switch (err) {
                error.OperationUnsupported, error.CrossDevice => return error.UnsupportedComposition,
                else => return error.Unavailable,
            };
            parts[i] = .{ .offset = size, .number = part.number, .size = part.size, .sha256 = part.checksum_sha256, .generation = part.data_generation };
            if (encryption != null) {
                const master = self.master_key orelse return error.Unavailable;
                var mac = std.crypto.auth.hmac.sha2.HmacSha256.init(&master);
                mac.update("ZIGFS-MULTIPART-DATA-V1:");
                mac.update(&part.data_generation);
                var key: box.Key = undefined;
                mac.final(&key);
                parts[i].key = key;
                std.crypto.secureZero(u8, &key);
            }
            size = std.math.add(u64, size, part.size) catch return error.CorruptData;
        }
        const json = std.json.Stringify.valueAlloc(a, Manifest{ .size = size, .parts = parts }, .{}) catch return error.OutOfMemory;
        defer std.crypto.secureZero(u8, json);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(json, &digest, .{});
        const body = if (encryption) |enc| blk: {
            const sealed = box.seal(a, self.io, enc.key, enc.associated_data, json) catch return error.Unavailable;
            break :blk std.mem.concat(a, u8, &.{ magic, "\x01", &sealed.nonce, &sealed.tag, sealed.ciphertext }) catch return error.OutOfMemory;
        } else std.mem.concat(a, u8, &.{ magic, "\x00", &digest, json }) catch return error.OutOfMemory;
        var meta = dir.createFile(self.io, "object.meta", .{ .exclusive = true }) catch return error.Unavailable;
        defer meta.close(self.io);
        meta.writeStreamingAll(self.io, body) catch return error.Unavailable;
        meta.sync(self.io) catch return error.Unavailable;
        // Sync the linked directory entries and then its parent before publish.
        const meta_path = std.fmt.allocPrint(a, "{s}/object.meta", .{path}) catch return error.OutOfMemory;
        durable.syncParent(self.root, self.io, meta_path) catch return error.Unavailable;
        durable.syncParent(self.root, self.io, path) catch return error.Unavailable;
        return .{ .data_layout = .segments, .token = token, .size = size, .etag_md5 = @splat(0), .checksum_crc32 = 0, .checksum_crc32c = 0, .checksum_sha256 = digest, .checksum_sha1 = @splat(0), .checksum_crc64nvme = 0 };
    }

    // Physical payload bytes, consistent with the existing encrypted backend.
    pub fn stat(self: Store, path: []const u8) port.Error!u64 {
        var dir = self.root.openDir(self.io, path, .{ .iterate = true }) catch return error.Unavailable;
        defer dir.close(self.io);
        var iterator = dir.iterate();
        var meta = false;
        var count: usize = 0;
        var total: u64 = 0;
        while (iterator.next(self.io) catch return error.Unavailable) |entry| {
            if (entry.kind != .file) return error.CorruptData;
            if (std.mem.eql(u8, entry.name, "object.meta")) {
                meta = true;
                continue;
            }
            if (!std.mem.startsWith(u8, entry.name, "part-")) return error.CorruptData;
            const index = std.fmt.parseInt(usize, entry.name[5..], 10) catch return error.CorruptData;
            if (index >= domain.max_multipart_parts) return error.CorruptData;
            const info = dir.statFile(self.io, entry.name, .{}) catch return error.Unavailable;
            total = std.math.add(u64, total, info.size) catch return error.CorruptData;
            count += 1;
        }
        if (!meta or count == 0 or count > domain.max_multipart_parts) return error.CorruptData;
        return total;
    }

    pub fn read(self: Store, path: []const u8, integrity: ?port.Integrity, encryption: ?Encryption, offset: u64, length: u64, sink: stream.Sink) port.Error!void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var dir = self.root.openDir(self.io, path, .{}) catch return error.Unavailable;
        defer dir.close(self.io);
        const bytes = dir.readFileAlloc(self.io, "object.meta", a, .limited(16 * 1024 * 1024)) catch return error.CorruptData;
        if (bytes.len < 41 or !std.mem.eql(u8, bytes[0..8], magic)) return error.CorruptData;
        const json = if (encryption) |enc| blk: {
            if (bytes[8] != 1) return error.CorruptData;
            break :blk box.open(a, enc.key, enc.associated_data, bytes[9..21].*, bytes[21..37].*, bytes[37..]) catch return error.CorruptData;
        } else blk: {
            if (bytes[8] != 0) return error.CorruptData;
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes[41..], &digest, .{});
            if (!std.mem.eql(u8, &digest, bytes[9..41])) return error.CorruptData;
            if (integrity) |expected| if (!std.mem.eql(u8, &digest, &expected.checksum_sha256)) return error.CorruptData;
            break :blk bytes[41..];
        };
        defer std.crypto.secureZero(u8, json);
        const parsed = std.json.parseFromSlice(Manifest, a, json, .{}) catch return error.CorruptData;
        defer for (@constCast(parsed.value.parts)) |*part| {
            if (part.key) |*key| std.crypto.secureZero(u8, key);
        };
        const manifest = parsed.value;
        if (manifest.version != 1 or manifest.parts.len == 0 or manifest.parts.len > domain.max_multipart_parts) return error.CorruptData;
        if (integrity) |expected| if (manifest.size != expected.size) return error.CorruptData;
        if (offset > manifest.size or length > manifest.size - offset) return error.InvalidValue;
        var start: u64 = 0;
        var delivered: u64 = 0;
        for (manifest.parts, 0..) |part, i| {
            if (part.offset != start or part.number == 0 or (i > 0 and part.number <= manifest.parts[i - 1].number)) return error.CorruptData;
            if (!id.isValidV4(part.generation) or (part.key != null) != (encryption != null)) return error.CorruptData;
            const end = std.math.add(u64, start, part.size) catch return error.CorruptData;
            if ((offset < end and offset + length > start) or (manifest.size == 0 and i == 0)) {
                const from = if (offset > start) offset - start else 0;
                const take = @min(end, offset + length) - (start + from);
                const name = std.fmt.allocPrint(a, "part-{d}", .{i}) catch return error.OutOfMemory;
                const file = dir.openFile(self.io, name, .{}) catch return error.CorruptData;
                defer file.close(self.io);
                if (part.key) |key| {
                    try self.readEncryptedPart(file, part, key, from, take, sink);
                } else {
                    const buffer = a.alloc(u8, self.buffer_size) catch return error.OutOfMemory;
                    defer a.free(buffer);
                    var hash = std.crypto.hash.sha2.Sha256.init(.{});
                    var position = from;
                    var remaining = take;
                    while (remaining > 0) {
                        const wanted: usize = @intCast(@min(remaining, buffer.len));
                        const count = file.readPositionalAll(self.io, buffer[0..wanted], position) catch return error.Unavailable;
                        if (count != wanted) return error.CorruptData;
                        hash.update(buffer[0..count]);
                        sink.writeAll(buffer[0..count]) catch return error.SinkWriteFailed;
                        remaining -= count;
                        position += count;
                    }
                    if (from == 0 and take == part.size) {
                        var digest: [32]u8 = undefined;
                        hash.final(&digest);
                        if (!std.mem.eql(u8, &digest, &part.sha256)) return error.CorruptData;
                    }
                }
                delivered += take;
            }
            start = end;
        }
        if (start != manifest.size or delivered != length) return error.CorruptData;
    }

    fn readEncryptedPart(self: Store, file: std.Io.File, part: Part, key: box.Key, offset: u64, length: u64, sink: stream.Sink) port.Error!void {
        var position = offset;
        var remaining = length;
        var verify_empty = part.size == 0;
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
            const plaintext = frames.open(self.allocator, key, &part.generation, .{ .index = index, .plaintext_length = header.plaintext_length, .nonce = header.nonce, .tag = header.tag, .ciphertext = ciphertext }) catch return error.CorruptData;
            defer {
                std.crypto.secureZero(u8, plaintext);
                self.allocator.free(plaintext);
            }
            if (remaining == 0) return;
            const from: usize = @intCast(position % frames.plaintext_frame_size);
            if (from >= plaintext.len) return error.CorruptData;
            const count = @min(remaining, plaintext.len - from);
            sink.writeAll(plaintext[from..][0..@intCast(count)]) catch return error.SinkWriteFailed;
            remaining -= count;
            position += count;
        }
    }
};
