const std = @import("std");

pub const Uuid = [16]u8;

pub fn randomV4(io: std.Io) std.Io.RandomSecureError!Uuid {
    var value: Uuid = undefined;
    try io.randomSecure(&value);
    value[6] = (value[6] & 0x0f) | 0x40;
    value[8] = (value[8] & 0x3f) | 0x80;
    return value;
}

pub fn isValidV4(value: Uuid) bool {
    return value[6] & 0xf0 == 0x40 and value[8] & 0xc0 == 0x80;
}

test "uuid v4 sets version and variant" {
    const value = try randomV4(std.testing.io);
    try std.testing.expect(isValidV4(value));
}

test "uuid v4 validation rejects invalid version and variant" {
    var value = @as([16]u8, @splat(0));
    value[6] = 0x40;
    value[8] = 0x80;
    try std.testing.expect(isValidV4(value));

    value[6] = 0x30;
    try std.testing.expect(!isValidV4(value));
    value[6] = 0x40;
    value[8] = 0xc0;
    try std.testing.expect(!isValidV4(value));
}
