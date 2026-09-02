const std = @import("std");

pub const magic = [4]u8{ 'Z', 'F', 'M', 'D' };

pub const Type = enum(u8) {
    system,
    bucket,
    object,
    multipart,
    credential,
};

pub const Header = extern struct {
    record_magic: [4]u8 = magic,
    format_version: u16 = 1,
    record_type: Type,
    generation: u64,
    payload_length: u64,
    checksum: [32]u8,
};

test "metadata header uses zigfs magic" {
    const header: Header = .{
        .record_type = .object,
        .generation = 1,
        .payload_length = 0,
        .checksum = [_]u8{0} ** 32,
    };
    try std.testing.expectEqualSlices(u8, &magic, &header.record_magic);
}
