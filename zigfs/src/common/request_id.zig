const std = @import("std");
const id = @import("id.zig");

pub const max_length = 128;
pub const generated_length = 32;

pub fn generate(io: std.Io) std.Io.RandomSecureError![generated_length]u8 {
    const value = try id.randomV4(io);
    return std.fmt.bytesToHex(value, .lower);
}

pub fn isValid(value: []const u8) bool {
    if (value.len == 0 or value.len > max_length) return false;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.' and byte != ':') {
            return false;
        }
    }
    return true;
}

test "generated request IDs are lowercase hexadecimal UUIDs" {
    const value = try generate(std.testing.io);
    try std.testing.expectEqual(generated_length, value.len);
    try std.testing.expect(isValid(&value));
    for (value) |byte| {
        try std.testing.expect(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'));
    }
}

test "request ID validation rejects unsafe values" {
    try std.testing.expect(isValid("client-request_01"));
    try std.testing.expect(!isValid(""));
    try std.testing.expect(!isValid("contains whitespace"));
    try std.testing.expect(!isValid("contains\r\nheader"));
    try std.testing.expect(!isValid("x" ** (max_length + 1)));
}
