const std = @import("std");

pub const Crc64Nvme = std.hash.crc.Crc(u64, .{
    .polynomial = 0xad93d23594c93659,
    .initial = 0xffffffffffffffff,
    .reflect_input = true,
    .reflect_output = true,
    .xor_output = 0xffffffffffffffff,
});

test "CRC64NVME matches the standard check value" {
    try std.testing.expectEqual(@as(u64, 0xae8b14860a799888), Crc64Nvme.hash("123456789"));
}
