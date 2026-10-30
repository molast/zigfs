const std = @import("std");
const durable = @import("durable.zig");

pub const path = ".zigfs/system/configuration/generation.meta";
pub const magic = [8]u8{ 'Z', 'F', 'S', 'G', 'E', 'N', '0', '1' };
pub const major_version: u16 = 1;
pub const minor_version: u16 = 0;
pub const encoded_length: usize = 56;

const flags_offset: usize = 12;
const generation_offset: usize = 16;
const checksum_offset: usize = 24;

pub const DecodeError = error{
    InvalidLength,
    InvalidMagic,
    UnsupportedMajorVersion,
    UnsupportedFlags,
    ChecksumMismatch,
};

pub const Error = DecodeError ||
    std.Io.Dir.ReadFileError ||
    std.Io.Dir.CreateFileAtomicError ||
    std.Io.File.Writer.Error ||
    std.Io.File.SyncError ||
    std.Io.File.Atomic.ReplaceError ||
    durable.SyncParentError ||
    error{GenerationExhausted};

pub fn allocate(root: std.Io.Dir, io: std.Io) Error!u64 {
    const last = try load(root, io);
    const next = std.math.add(u64, last, 1) catch return error.GenerationExhausted;
    const bytes = encode(next);

    var atomic_file = try root.createFileAtomic(io, path, .{ .replace = true });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, &bytes);
    try atomic_file.file.sync(io);
    try atomic_file.replace(io);
    try durable.syncParent(root, io, path);
    return next;
}

pub fn load(root: std.Io.Dir, io: std.Io) Error!u64 {
    var buffer: [encoded_length + 1]u8 = undefined;
    const bytes = root.readFile(io, path, &buffer) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    return decode(bytes);
}

pub fn encode(last_generation: u64) [encoded_length]u8 {
    var bytes = @as([encoded_length]u8, @splat(0));
    @memcpy(bytes[0..magic.len], &magic);
    std.mem.writeInt(u16, bytes[8..10], major_version, .little);
    std.mem.writeInt(u16, bytes[10..12], minor_version, .little);
    std.mem.writeInt(u32, bytes[flags_offset..generation_offset], 0, .little);
    std.mem.writeInt(u64, bytes[generation_offset..checksum_offset], last_generation, .little);
    writeChecksum(&bytes);
    return bytes;
}

pub fn decode(bytes: []const u8) DecodeError!u64 {
    if (bytes.len != encoded_length) return error.InvalidLength;
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return error.InvalidMagic;
    if (std.mem.readInt(u16, bytes[8..10], .little) != major_version) {
        return error.UnsupportedMajorVersion;
    }
    if (std.mem.readInt(u32, bytes[flags_offset..generation_offset], .little) != 0) {
        return error.UnsupportedFlags;
    }
    var expected_checksum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..checksum_offset], &expected_checksum, .{});
    if (!std.mem.eql(u8, &expected_checksum, bytes[checksum_offset..])) {
        return error.ChecksumMismatch;
    }
    return std.mem.readInt(u64, bytes[generation_offset..checksum_offset], .little);
}

fn writeChecksum(bytes: *[encoded_length]u8) void {
    std.crypto.hash.sha2.Sha256.hash(bytes[0..checksum_offset], bytes[checksum_offset..], .{});
}

test "generation allocation is monotonic across reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".zigfs/system/configuration");

    try std.testing.expectEqual(@as(u64, 1), try allocate(tmp.dir, std.testing.io));
    try std.testing.expectEqual(@as(u64, 2), try allocate(tmp.dir, std.testing.io));
    try std.testing.expectEqual(@as(u64, 2), try load(tmp.dir, std.testing.io));
    try std.testing.expectEqual(@as(u64, 3), try allocate(tmp.dir, std.testing.io));
}

test "corrupt generation state is never overwritten" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".zigfs/system/configuration");
    _ = try allocate(tmp.dir, std.testing.io);

    var corrupt = encode(1);
    corrupt[checksum_offset] ^= 0xff;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = &corrupt });
    try std.testing.expectError(error.ChecksumMismatch, allocate(tmp.dir, std.testing.io));

    var after_buffer: [encoded_length]u8 = undefined;
    const after = try tmp.dir.readFile(std.testing.io, path, &after_buffer);
    try std.testing.expectEqualSlices(u8, &corrupt, after);
}
