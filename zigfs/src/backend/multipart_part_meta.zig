//! Versioned, checksummed per-part metadata, durable before UploadPart succeeds.
const std = @import("std");
const domain = @import("../domain/object.zig");
const part_port = @import("../ports/multipart_data_store.zig");
const port = @import("../ports/object_data_store.zig");
const magic = "ZFPART01";
const Record = struct { upload_id: [16]u8, status: enum { completed } = .completed, completed_at: i64, modified_ns: i128, physical_size: u64, number: u16, encrypted: bool, size: u64, generation: [16]u8, etag: [16]u8, sha256: [32]u8, crc32: u32, crc32c: u32, sha1: [20]u8, crc64nvme: u64 };

pub fn write(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, directory: []const u8, staged: part_port.Staged, location: part_port.Location) part_port.Error!void {
    var data_dir = root.openDir(io, directory, .{}) catch return error.Unavailable;
    defer data_dir.close(io);
    const info = data_dir.statFile(io, "data", .{}) catch return error.Unavailable;
    const json = std.json.Stringify.valueAlloc(a, Record{ .upload_id = location.upload_id, .completed_at = std.Io.Clock.real.now(io).toSeconds(), .modified_ns = info.mtime.nanoseconds, .physical_size = info.size, .number = location.part_number, .encrypted = location.encrypted, .size = staged.size, .generation = location.data_generation, .etag = staged.etag_md5, .sha256 = staged.checksum_sha256, .crc32 = staged.checksum_crc32, .crc32c = staged.checksum_crc32c, .sha1 = staged.checksum_sha1, .crc64nvme = staged.checksum_crc64nvme }, .{}) catch return error.OutOfMemory;
    defer a.free(json);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(json, &digest, .{});
    const bytes = std.mem.concat(a, u8, &.{ magic, &digest, json }) catch return error.OutOfMemory;
    defer a.free(bytes);
    var dir = root.openDir(io, directory, .{}) catch return error.Unavailable;
    defer dir.close(io);
    var file = dir.createFile(io, ".part.meta.tmp", .{ .exclusive = true }) catch return error.Unavailable;
    defer file.close(io);
    file.writeStreamingAll(io, bytes) catch return error.Unavailable;
    file.sync(io) catch return error.Unavailable;
    dir.renamePreserve(".part.meta.tmp", dir, "part.meta", io) catch return error.Unavailable;
}

pub fn verify(root: std.Io.Dir, io: std.Io, directory: []const u8, upload_id: [16]u8, expected: domain.MultipartPart) port.Error!void {
    var dir = root.openDir(io, directory, .{}) catch return error.Unavailable;
    defer dir.close(io);
    var buffer: [4096]u8 = undefined;
    const bytes = dir.readFile(io, "part.meta", &buffer) catch |err| switch (err) {
        // Upgrade compatibility: older uploads already have durable checksums
        // in upload metadata. No payload scan is required for these either.
        error.FileNotFound => return,
        else => return error.CorruptData,
    };
    if (bytes.len < 40 or !std.mem.eql(u8, bytes[0..8], magic)) return error.CorruptData;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[40..], &digest, .{});
    if (!std.mem.eql(u8, &digest, bytes[8..40])) return error.CorruptData;
    var storage: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    const parsed = std.json.parseFromSlice(Record, fba.allocator(), bytes[40..], .{}) catch return error.CorruptData;
    const record = parsed.value;
    if (!std.mem.eql(u8, &record.upload_id, &upload_id) or record.completed_at <= 0) return error.CorruptData;
    const info = dir.statFile(io, "data", .{}) catch return error.CorruptData;
    if (info.kind != .file or info.mtime.nanoseconds != record.modified_ns or info.size != record.physical_size) return error.CorruptData;
    if (expected.etag_md5) |etag| if (!std.mem.eql(u8, &record.etag, &etag)) return error.CorruptData;
    if (record.number != expected.number or record.encrypted != expected.encrypted or record.size != expected.size or !std.mem.eql(u8, &record.generation, &expected.data_generation) or !std.mem.eql(u8, &record.sha256, &expected.checksum_sha256)) return error.CorruptData;
}
