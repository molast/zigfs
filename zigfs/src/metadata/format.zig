const std = @import("std");
const id = @import("../common/id.zig");

pub const path = ".zigfs/format.meta";
pub const magic = [8]u8{ 'Z', 'I', 'G', 'F', 'S', 'F', 'M', 'T' };
pub const major_version: u16 = 1;
pub const minor_version: u16 = 0;
pub const encoded_length: usize = 72;

const checksum_offset: usize = 40;
const flags_offset: usize = 14;

pub const Metadata = struct {
    instance_id: id.Uuid,
    created_at_unix_seconds: i64,
};

pub const DecodeError = error{
    InvalidLength,
    InvalidMagic,
    UnsupportedMajorVersion,
    InvalidHeaderLength,
    UnsupportedFlags,
    InvalidInstanceId,
    ChecksumMismatch,
};

pub const Error = DecodeError ||
    std.Io.Dir.ReadFileError ||
    std.Io.Dir.CreateFileAtomicError ||
    std.Io.File.Writer.Error ||
    std.Io.File.SyncError ||
    std.Io.File.Atomic.LinkError ||
    std.Io.RandomSecureError;

pub fn loadOrCreate(dir: std.Io.Dir, io: std.Io) Error!Metadata {
    var buffer: [encoded_length + 1]u8 = undefined;
    const existing = dir.readFile(io, path, &buffer) catch |err| switch (err) {
        error.FileNotFound => return create(dir, io),
        else => return err,
    };
    return decode(existing);
}

pub fn encode(metadata: Metadata) [encoded_length]u8 {
    var bytes = @as([encoded_length]u8, @splat(0));
    @memcpy(bytes[0..magic.len], &magic);
    std.mem.writeInt(u16, bytes[8..10], major_version, .little);
    std.mem.writeInt(u16, bytes[10..12], minor_version, .little);
    std.mem.writeInt(u16, bytes[12..14], encoded_length, .little);
    std.mem.writeInt(u16, bytes[flags_offset..16], 0, .little);
    @memcpy(bytes[16..32], &metadata.instance_id);
    std.mem.writeInt(i64, bytes[32..checksum_offset], metadata.created_at_unix_seconds, .little);
    writeChecksum(&bytes);
    return bytes;
}

pub fn decode(bytes: []const u8) DecodeError!Metadata {
    if (bytes.len != encoded_length) return error.InvalidLength;
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return error.InvalidMagic;
    if (std.mem.readInt(u16, bytes[8..10], .little) != major_version) {
        return error.UnsupportedMajorVersion;
    }
    if (std.mem.readInt(u16, bytes[12..14], .little) != encoded_length) {
        return error.InvalidHeaderLength;
    }
    if (std.mem.readInt(u16, bytes[flags_offset..16], .little) != 0) {
        return error.UnsupportedFlags;
    }

    var instance_id: id.Uuid = undefined;
    @memcpy(&instance_id, bytes[16..32]);
    if (!id.isValidV4(instance_id)) return error.InvalidInstanceId;

    var expected_checksum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..checksum_offset], &expected_checksum, .{});
    if (!std.mem.eql(u8, &expected_checksum, bytes[checksum_offset..encoded_length])) {
        return error.ChecksumMismatch;
    }

    return .{
        .instance_id = instance_id,
        .created_at_unix_seconds = std.mem.readInt(i64, bytes[32..checksum_offset], .little),
    };
}

fn create(dir: std.Io.Dir, io: std.Io) Error!Metadata {
    const metadata: Metadata = .{
        .instance_id = try id.randomV4(io),
        .created_at_unix_seconds = std.Io.Clock.real.now(io).toSeconds(),
    };
    const bytes = encode(metadata);

    var atomic_file = try dir.createFileAtomic(io, path, .{ .replace = false });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, &bytes);
    try atomic_file.file.sync(io);
    try atomic_file.link(io);
    return metadata;
}

fn writeChecksum(bytes: *[encoded_length]u8) void {
    std.crypto.hash.sha2.Sha256.hash(bytes[0..checksum_offset], bytes[checksum_offset..encoded_length], .{});
}

test "format metadata round trip" {
    const metadata: Metadata = .{
        .instance_id = .{ 0, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
        .created_at_unix_seconds = 1_800_000_000,
    };
    const decoded = try decode(&encode(metadata));
    try std.testing.expectEqual(metadata.created_at_unix_seconds, decoded.created_at_unix_seconds);
    try std.testing.expectEqualSlices(u8, &metadata.instance_id, &decoded.instance_id);
}

test "format metadata rejects malformed fields and corruption" {
    const metadata: Metadata = .{
        .instance_id = .{ 0, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
        .created_at_unix_seconds = 1,
    };
    const valid = encode(metadata);

    try std.testing.expectError(error.InvalidLength, decode(valid[0 .. valid.len - 1]));

    var changed = valid;
    changed[0] = 'X';
    try std.testing.expectError(error.InvalidMagic, decode(&changed));

    changed = valid;
    std.mem.writeInt(u16, changed[8..10], major_version + 1, .little);
    writeChecksum(&changed);
    try std.testing.expectError(error.UnsupportedMajorVersion, decode(&changed));

    changed = valid;
    std.mem.writeInt(u16, changed[12..14], encoded_length - 1, .little);
    writeChecksum(&changed);
    try std.testing.expectError(error.InvalidHeaderLength, decode(&changed));

    changed = valid;
    changed[flags_offset] = 1;
    writeChecksum(&changed);
    try std.testing.expectError(error.UnsupportedFlags, decode(&changed));

    changed = valid;
    changed[22] = 0;
    writeChecksum(&changed);
    try std.testing.expectError(error.InvalidInstanceId, decode(&changed));

    changed = valid;
    changed[32] ^= 0xff;
    try std.testing.expectError(error.ChecksumMismatch, decode(&changed));
}

test "format metadata persists instance identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".zigfs");

    const first = try loadOrCreate(tmp.dir, std.testing.io);
    const second = try loadOrCreate(tmp.dir, std.testing.io);
    try std.testing.expectEqualSlices(u8, &first.instance_id, &second.instance_id);
    try std.testing.expectEqual(first.created_at_unix_seconds, second.created_at_unix_seconds);
}

test "corrupt format metadata is never overwritten" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".zigfs");

    _ = try loadOrCreate(tmp.dir, std.testing.io);
    var corrupt: [encoded_length]u8 = undefined;
    _ = try tmp.dir.readFile(std.testing.io, path, &corrupt);
    corrupt[32] ^= 0xff;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = &corrupt });

    try std.testing.expectError(error.ChecksumMismatch, loadOrCreate(tmp.dir, std.testing.io));
    var after_buffer: [encoded_length]u8 = undefined;
    const after = try tmp.dir.readFile(std.testing.io, path, &after_buffer);
    try std.testing.expectEqualSlices(u8, &corrupt, after);
}

test "unknown format major version is never overwritten" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".zigfs");

    _ = try loadOrCreate(tmp.dir, std.testing.io);
    var unknown: [encoded_length]u8 = undefined;
    _ = try tmp.dir.readFile(std.testing.io, path, &unknown);
    std.mem.writeInt(u16, unknown[8..10], major_version + 1, .little);
    writeChecksum(&unknown);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = &unknown });

    try std.testing.expectError(error.UnsupportedMajorVersion, loadOrCreate(tmp.dir, std.testing.io));
    var after_buffer: [encoded_length]u8 = undefined;
    const after = try tmp.dir.readFile(std.testing.io, path, &after_buffer);
    try std.testing.expectEqualSlices(u8, &unknown, after);
}
