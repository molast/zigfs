const std = @import("std");

pub const magic = [4]u8{ 'Z', 'F', 'M', 'P' };
pub const header_length: usize = 8;
pub const max_key_length: usize = 2048;

pub const Decoded = struct {
    key: []const u8,
    tombstone: bool,
    payload: []const u8,
};

pub const EncodeError = std.mem.Allocator.Error || error{
    InvalidKey,
    PayloadTooLarge,
};

pub const DecodeError = error{
    Truncated,
    InvalidMagic,
    UnsupportedFlags,
    InvalidKey,
};

pub fn encode(
    allocator: std.mem.Allocator,
    key: []const u8,
    payload: []const u8,
) EncodeError![]u8 {
    return encodeWithFlags(allocator, key, payload, false);
}

pub fn encodeTombstone(
    allocator: std.mem.Allocator,
    key: []const u8,
) EncodeError![]u8 {
    return encodeWithFlags(allocator, key, "", true);
}

fn encodeWithFlags(
    allocator: std.mem.Allocator,
    key: []const u8,
    payload: []const u8,
    tombstone: bool,
) EncodeError![]u8 {
    if (!isValidKey(key)) return error.InvalidKey;
    const total_length = std.math.add(usize, header_length + key.len, payload.len) catch {
        return error.PayloadTooLarge;
    };
    const bytes = try allocator.alloc(u8, total_length);
    @memcpy(bytes[0..magic.len], &magic);
    std.mem.writeInt(u16, bytes[4..6], @intCast(key.len), .little);
    std.mem.writeInt(u16, bytes[6..header_length], @intFromBool(tombstone), .little);
    @memcpy(bytes[header_length .. header_length + key.len], key);
    @memcpy(bytes[header_length + key.len ..], payload);
    return bytes;
}

pub fn decode(bytes: []const u8) DecodeError!Decoded {
    if (bytes.len < header_length) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return error.InvalidMagic;
    const flags = std.mem.readInt(u16, bytes[6..header_length], .little);
    if (flags & ~@as(u16, 1) != 0) {
        return error.UnsupportedFlags;
    }
    const key_length = std.mem.readInt(u16, bytes[4..6], .little);
    if (key_length == 0 or key_length > max_key_length) return error.InvalidKey;
    const payload_offset = header_length + key_length;
    if (bytes.len < payload_offset) return error.Truncated;
    const key = bytes[header_length..payload_offset];
    if (!isValidKey(key)) return error.InvalidKey;
    const tombstone = flags & 1 != 0;
    const payload = bytes[payload_offset..];
    if (tombstone and payload.len != 0) return error.UnsupportedFlags;
    return .{ .key = key, .tombstone = tombstone, .payload = payload };
}

pub fn isValidKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_key_length) return false;
    return std.mem.indexOfScalar(u8, key, 0) == null;
}

test "repository payload preserves original key and data" {
    const encoded = try encode(std.testing.allocator, "bucket/photos/a.jpg", "metadata");
    defer std.testing.allocator.free(encoded);
    const decoded = try decode(encoded);
    try std.testing.expectEqualStrings("bucket/photos/a.jpg", decoded.key);
    try std.testing.expect(!decoded.tombstone);
    try std.testing.expectEqualStrings("metadata", decoded.payload);

    const tombstone = try encodeTombstone(std.testing.allocator, "bucket/photos/a.jpg");
    defer std.testing.allocator.free(tombstone);
    const decoded_tombstone = try decode(tombstone);
    try std.testing.expect(decoded_tombstone.tombstone);
    try std.testing.expectEqual(@as(usize, 0), decoded_tombstone.payload.len);
}

test "repository payload rejects malformed keys" {
    try std.testing.expectError(error.InvalidKey, encode(std.testing.allocator, "", "data"));
    try std.testing.expectError(error.InvalidKey, encode(std.testing.allocator, "a\x00b", "data"));

    var invalid = [_]u8{0} ** header_length;
    @memcpy(invalid[0..magic.len], &magic);
    try std.testing.expectError(error.InvalidKey, decode(&invalid));
}
