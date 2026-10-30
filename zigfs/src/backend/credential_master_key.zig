const std = @import("std");
const builtin = @import("builtin");
const durable = @import("../metadata/durable.zig");
const secret_box = @import("../auth/secret_box.zig");

pub const path = ".zigfs/system/credential-master.key";
pub const magic = [4]u8{ 'Z', 'F', 'M', 'K' };
pub const major_version: u16 = 1;
pub const minor_version: u16 = 0;
pub const encoded_length: usize = 72;
const key_offset: usize = 8;
const checksum_offset: usize = 40;

pub const Error = std.Io.Dir.ReadFileError ||
    std.Io.Dir.CreateFileAtomicError ||
    std.Io.File.Writer.Error ||
    std.Io.File.SyncError ||
    std.Io.File.Atomic.LinkError ||
    std.Io.RandomSecureError ||
    durable.SyncParentError ||
    error{
        InvalidLength,
        InvalidMagic,
        UnsupportedVersion,
        ChecksumMismatch,
    };

pub const MasterKey = struct {
    bytes: secret_box.Key,

    pub fn deinit(self: *MasterKey) void {
        std.crypto.secureZero(u8, &self.bytes);
        self.* = undefined;
    }
};

pub fn loadOrCreate(root: std.Io.Dir, io: std.Io) Error!MasterKey {
    var buffer: [encoded_length + 1]u8 = undefined;
    const existing = root.readFile(io, path, &buffer) catch |err| switch (err) {
        error.FileNotFound => return create(root, io),
        else => return err,
    };
    return .{ .bytes = try decode(existing) };
}

pub fn encode(key: secret_box.Key) [encoded_length]u8 {
    var bytes = @as([encoded_length]u8, @splat(0));
    @memcpy(bytes[0..magic.len], &magic);
    std.mem.writeInt(u16, bytes[4..6], major_version, .little);
    std.mem.writeInt(u16, bytes[6..8], minor_version, .little);
    @memcpy(bytes[key_offset..checksum_offset], &key);
    std.crypto.hash.sha2.Sha256.hash(
        bytes[0..checksum_offset],
        bytes[checksum_offset..encoded_length],
        .{},
    );
    return bytes;
}

pub fn decode(bytes: []const u8) error{
    InvalidLength,
    InvalidMagic,
    UnsupportedVersion,
    ChecksumMismatch,
}!secret_box.Key {
    if (bytes.len != encoded_length) return error.InvalidLength;
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return error.InvalidMagic;
    if (std.mem.readInt(u16, bytes[4..6], .little) != major_version or
        std.mem.readInt(u16, bytes[6..8], .little) != minor_version)
    {
        return error.UnsupportedVersion;
    }
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..checksum_offset], &expected, .{});
    if (!std.crypto.timing_safe.eql([32]u8, expected, bytes[checksum_offset..encoded_length].*)) {
        return error.ChecksumMismatch;
    }
    var key: secret_box.Key = undefined;
    @memcpy(&key, bytes[key_offset..checksum_offset]);
    return key;
}

fn create(root: std.Io.Dir, io: std.Io) Error!MasterKey {
    var key: secret_box.Key = undefined;
    try io.randomSecure(&key);
    errdefer std.crypto.secureZero(u8, &key);
    const bytes = encode(key);
    const permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows)
        .default_file
    else
        @enumFromInt(0o600);
    var atomic_file = try root.createFileAtomic(io, path, .{
        .replace = false,
        .permissions = permissions,
    });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, &bytes);
    try atomic_file.file.sync(io);
    try atomic_file.link(io);
    try durable.syncParent(root, io, path);
    return .{ .bytes = key };
}

test "credential master key is persistent and corruption is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".zigfs/system");

    var first = try loadOrCreate(tmp.dir, std.testing.io);
    defer first.deinit();
    var second = try loadOrCreate(tmp.dir, std.testing.io);
    defer second.deinit();
    try std.testing.expectEqualSlices(u8, &first.bytes, &second.bytes);

    var corrupt: [encoded_length]u8 = undefined;
    _ = try tmp.dir.readFile(std.testing.io, path, &corrupt);
    corrupt[key_offset] ^= 0xff;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = &corrupt });
    try std.testing.expectError(error.ChecksumMismatch, loadOrCreate(tmp.dir, std.testing.io));
}
