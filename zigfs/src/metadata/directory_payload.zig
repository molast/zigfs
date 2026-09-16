const std = @import("std");
const bucket_domain = @import("../domain/bucket.zig");
const object_domain = @import("../domain/object.zig");

pub const magic = [4]u8{ 'Z', 'F', 'D', 'R' };
pub const major_version: u16 = 1;
pub const minor_version: u16 = 0;
pub const header_length: usize = 32;

const bucket_length_offset: usize = 8;
const key_length_offset: usize = 10;
const created_at_offset: usize = 12;
const modified_at_offset: usize = 20;

pub const Value = struct {
    bucket_name: []const u8,
    key: []const u8,
    created_at_unix_seconds: i64,
    last_modified_unix_seconds: i64,
};

pub const Decoded = Value;

pub const EncodeError = std.mem.Allocator.Error || error{
    InvalidBucketName,
    InvalidObjectKey,
    InvalidDirectoryKey,
    InvalidTimestamp,
    PayloadTooLarge,
};

pub const DecodeError = error{
    Truncated,
    InvalidMagic,
    UnsupportedVersion,
    UnsupportedFlags,
    InvalidLength,
    InvalidBucketName,
    InvalidObjectKey,
    InvalidDirectoryKey,
    InvalidTimestamp,
};

pub fn encode(allocator: std.mem.Allocator, value: Value) EncodeError![]u8 {
    bucket_domain.validateName(value.bucket_name) catch return error.InvalidBucketName;
    object_domain.validateKey(value.key) catch return error.InvalidObjectKey;
    if (value.key.len == 0 or value.key[value.key.len - 1] != '/') return error.InvalidDirectoryKey;
    if (value.created_at_unix_seconds <= 0 or value.last_modified_unix_seconds <= 0) return error.InvalidTimestamp;
    if (value.bucket_name.len > std.math.maxInt(u16) or value.key.len > std.math.maxInt(u16)) return error.PayloadTooLarge;
    const payload_length = std.math.add(usize, header_length, value.bucket_name.len) catch return error.PayloadTooLarge;
    const total_length = std.math.add(usize, payload_length, value.key.len) catch return error.PayloadTooLarge;
    const bytes = try allocator.alloc(u8, total_length);
    @memset(bytes, 0);
    @memcpy(bytes[0..magic.len], &magic);
    std.mem.writeInt(u16, bytes[4..6], major_version, .little);
    std.mem.writeInt(u16, bytes[6..8], minor_version, .little);
    std.mem.writeInt(u16, bytes[bucket_length_offset..key_length_offset], @intCast(value.bucket_name.len), .little);
    std.mem.writeInt(u16, bytes[key_length_offset..12], @intCast(value.key.len), .little);
    std.mem.writeInt(i64, bytes[created_at_offset..20], value.created_at_unix_seconds, .little);
    std.mem.writeInt(i64, bytes[modified_at_offset..28], value.last_modified_unix_seconds, .little);
    const offset = header_length;
    @memcpy(bytes[offset .. offset + value.bucket_name.len], value.bucket_name);
    @memcpy(bytes[offset + value.bucket_name.len ..], value.key);
    return bytes;
}

pub fn decode(bytes: []const u8) DecodeError!Decoded {
    if (bytes.len < header_length) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return error.InvalidMagic;
    if (std.mem.readInt(u16, bytes[4..6], .little) != major_version or
        std.mem.readInt(u16, bytes[6..8], .little) != minor_version) return error.UnsupportedVersion;
    const bucket_length = std.mem.readInt(u16, bytes[bucket_length_offset..key_length_offset], .little);
    const key_length = std.mem.readInt(u16, bytes[key_length_offset..12], .little);
    const expected_length = std.math.add(usize, header_length, bucket_length) catch return error.InvalidLength;
    const full_length = std.math.add(usize, expected_length, key_length) catch return error.InvalidLength;
    if (bytes.len != full_length) return error.InvalidLength;
    const created_at = std.mem.readInt(i64, bytes[created_at_offset..20], .little);
    const modified_at = std.mem.readInt(i64, bytes[modified_at_offset..28], .little);
    if (created_at <= 0 or modified_at <= 0) return error.InvalidTimestamp;
    const bucket_start = header_length;
    const key_start = bucket_start + bucket_length;
    const bucket_name = bytes[bucket_start..key_start];
    const key = bytes[key_start..full_length];
    bucket_domain.validateName(bucket_name) catch return error.InvalidBucketName;
    object_domain.validateKey(key) catch return error.InvalidObjectKey;
    if (key.len == 0 or key[key.len - 1] != '/') return error.InvalidDirectoryKey;
    return .{
        .bucket_name = bucket_name,
        .key = key,
        .created_at_unix_seconds = created_at,
        .last_modified_unix_seconds = modified_at,
    };
}

test "directory payload round trips typed directory metadata" {
    const bytes = try encode(std.testing.allocator, .{
        .bucket_name = "photos",
        .key = "images/",
        .created_at_unix_seconds = 100,
        .last_modified_unix_seconds = 200,
    });
    defer std.testing.allocator.free(bytes);
    const decoded = try decode(bytes);
    try std.testing.expectEqualStrings("photos", decoded.bucket_name);
    try std.testing.expectEqualStrings("images/", decoded.key);
    try std.testing.expectEqual(@as(i64, 200), decoded.last_modified_unix_seconds);
}
