const std = @import("std");

pub const magic = [4]u8{ 'Z', 'F', 'R', 'D' };
pub const major_version: u16 = 1;
pub const minor_version: u16 = 0;
pub const header_length: usize = 32;
pub const checksum_length: usize = 32;
pub const max_payload_length: usize = 64 * 1024 * 1024;

const type_offset: usize = 8;
const flags_offset: usize = 9;
const generation_offset: usize = 12;
const payload_length_offset: usize = 20;

pub const Type = enum(u8) {
    system = 1,
    bucket = 2,
    object = 3,
    multipart = 4,
    credential = 5,
    directory = 6,
};

pub const Decoded = struct {
    record_type: Type,
    generation: u64,
    payload: []const u8,
};

pub const EncodeError = std.mem.Allocator.Error || error{PayloadTooLarge};

pub const DecodeError = error{
    Truncated,
    InvalidMagic,
    UnsupportedMajorVersion,
    InvalidHeaderLength,
    UnsupportedFlags,
    InvalidRecordType,
    PayloadTooLarge,
    InvalidPayloadLength,
    ChecksumMismatch,
};

pub fn encode(
    allocator: std.mem.Allocator,
    record_type: Type,
    generation: u64,
    payload: []const u8,
) EncodeError![]u8 {
    if (payload.len > max_payload_length) return error.PayloadTooLarge;

    const total_length = header_length + payload.len + checksum_length;
    const bytes = try allocator.alloc(u8, total_length);
    errdefer allocator.free(bytes);
    @memset(bytes, 0);

    @memcpy(bytes[0..magic.len], &magic);
    std.mem.writeInt(u16, bytes[4..6], major_version, .little);
    std.mem.writeInt(u16, bytes[6..8], minor_version, .little);
    bytes[type_offset] = @intFromEnum(record_type);
    bytes[flags_offset] = 0;
    std.mem.writeInt(u16, bytes[10..12], header_length, .little);
    std.mem.writeInt(u64, bytes[generation_offset..20], generation, .little);
    std.mem.writeInt(u64, bytes[payload_length_offset..28], payload.len, .little);
    std.mem.writeInt(u32, bytes[28..header_length], 0, .little);
    @memcpy(bytes[header_length .. header_length + payload.len], payload);

    const checksum_offset = header_length + payload.len;
    const checksum: *[checksum_length]u8 = @ptrCast(bytes[checksum_offset..].ptr);
    std.crypto.hash.sha2.Sha256.hash(bytes[0..checksum_offset], checksum, .{});
    return bytes;
}

pub fn decode(bytes: []const u8) DecodeError!Decoded {
    if (bytes.len < header_length + checksum_length) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return error.InvalidMagic;
    if (std.mem.readInt(u16, bytes[4..6], .little) != major_version) {
        return error.UnsupportedMajorVersion;
    }
    if (std.mem.readInt(u16, bytes[10..12], .little) != header_length) {
        return error.InvalidHeaderLength;
    }
    if (bytes[flags_offset] != 0 or std.mem.readInt(u32, bytes[28..header_length], .little) != 0) {
        return error.UnsupportedFlags;
    }

    const record_type: Type = switch (bytes[type_offset]) {
        1 => .system,
        2 => .bucket,
        3 => .object,
        4 => .multipart,
        5 => .credential,
        6 => .directory,
        else => return error.InvalidRecordType,
    };

    const payload_length_u64 = std.mem.readInt(u64, bytes[payload_length_offset..28], .little);
    if (payload_length_u64 > max_payload_length) return error.PayloadTooLarge;
    const payload_length: usize = @intCast(payload_length_u64);
    const expected_length = header_length + payload_length + checksum_length;
    if (bytes.len < expected_length) return error.Truncated;
    if (bytes.len != expected_length) return error.InvalidPayloadLength;

    const checksum_offset = header_length + payload_length;
    var expected_checksum: [checksum_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..checksum_offset], &expected_checksum, .{});
    if (!std.mem.eql(u8, &expected_checksum, bytes[checksum_offset..])) {
        return error.ChecksumMismatch;
    }

    return .{
        .record_type = record_type,
        .generation = std.mem.readInt(u64, bytes[generation_offset..20], .little),
        .payload = bytes[header_length..checksum_offset],
    };
}

test "record envelope round trips payload and empty payload" {
    const allocator = std.testing.allocator;
    const bytes = try encode(allocator, .object, 42, "hello zigfs");
    defer allocator.free(bytes);
    const decoded = try decode(bytes);
    try std.testing.expectEqual(Type.object, decoded.record_type);
    try std.testing.expectEqual(@as(u64, 42), decoded.generation);
    try std.testing.expectEqualStrings("hello zigfs", decoded.payload);

    const empty = try encode(allocator, .system, 0, "");
    defer allocator.free(empty);
    const decoded_empty = try decode(empty);
    try std.testing.expectEqual(@as(usize, 0), decoded_empty.payload.len);
}

test "record envelope rejects malformed header" {
    const allocator = std.testing.allocator;
    const valid = try encode(allocator, .bucket, 1, "payload");
    defer allocator.free(valid);

    try std.testing.expectError(error.Truncated, decode(valid[0 .. valid.len - 1]));

    var changed = try allocator.dupe(u8, valid);
    defer allocator.free(changed);
    changed[0] = 'X';
    try std.testing.expectError(error.InvalidMagic, decode(changed));

    @memcpy(changed, valid);
    std.mem.writeInt(u16, changed[4..6], major_version + 1, .little);
    try std.testing.expectError(error.UnsupportedMajorVersion, decode(changed));

    @memcpy(changed, valid);
    changed[type_offset] = 255;
    try std.testing.expectError(error.InvalidRecordType, decode(changed));

    @memcpy(changed, valid);
    std.mem.writeInt(u16, changed[10..12], header_length - 1, .little);
    try std.testing.expectError(error.InvalidHeaderLength, decode(changed));

    @memcpy(changed, valid);
    changed[flags_offset] = 1;
    try std.testing.expectError(error.UnsupportedFlags, decode(changed));

    @memcpy(changed, valid);
    changed[28] = 1;
    try std.testing.expectError(error.UnsupportedFlags, decode(changed));
}

test "record envelope rejects invalid lengths and checksum corruption" {
    const allocator = std.testing.allocator;
    const valid = try encode(allocator, .multipart, 7, "payload");
    defer allocator.free(valid);

    var changed = try allocator.dupe(u8, valid);
    defer allocator.free(changed);
    std.mem.writeInt(u64, changed[payload_length_offset..28], max_payload_length + 1, .little);
    try std.testing.expectError(error.PayloadTooLarge, decode(changed));

    @memcpy(changed, valid);
    std.mem.writeInt(u64, changed[payload_length_offset..28], 1, .little);
    try std.testing.expectError(error.InvalidPayloadLength, decode(changed));

    @memcpy(changed, valid);
    changed[header_length] ^= 0xff;
    try std.testing.expectError(error.ChecksumMismatch, decode(changed));
}
