const std = @import("std");

pub const Uuid = [16]u8;

pub fn randomV4(io: std.Io) std.Io.RandomSecureError!Uuid {
    var value: Uuid = undefined;
    try io.randomSecure(&value);
    value[6] = (value[6] & 0x0f) | 0x40;
    value[8] = (value[8] & 0x3f) | 0x80;
    return value;
}

test "uuid v4 sets version and variant" {
    const value = try randomV4(std.testing.io);
    try std.testing.expectEqual(@as(u8, 0x40), value[6] & 0xf0);
    try std.testing.expectEqual(@as(u8, 0x80), value[8] & 0xc0);
}
