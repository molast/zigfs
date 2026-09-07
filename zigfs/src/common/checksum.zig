const std = @import("std");

pub const Crc64Nvme = std.hash.crc.Crc(u64, .{
    .polynomial = 0xad93d23594c93659,
    .initial = 0xffffffffffffffff,
    .reflect_input = true,
    .reflect_output = true,
    .xor_output = 0xffffffffffffffff,
});

pub const Crc32 = std.hash.crc.Crc32;
pub const Crc32C = std.hash.crc.Crc32Iscsi;
pub const Sha1 = std.crypto.hash.Sha1;
pub const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Algorithm = enum {
    crc32,
    crc32c,
    crc64nvme,
    sha1,
    sha256,

    pub fn headerName(self: Algorithm) []const u8 {
        return switch (self) {
            .crc32 => "x-amz-checksum-crc32",
            .crc32c => "x-amz-checksum-crc32c",
            .crc64nvme => "x-amz-checksum-crc64nvme",
            .sha1 => "x-amz-checksum-sha1",
            .sha256 => "x-amz-checksum-sha256",
        };
    }

    pub fn sdkName(self: Algorithm) []const u8 {
        return switch (self) {
            .crc32 => "CRC32",
            .crc32c => "CRC32C",
            .crc64nvme => "CRC64NVME",
            .sha1 => "SHA1",
            .sha256 => "SHA256",
        };
    }

    pub fn encodedLength(self: Algorithm) usize {
        return switch (self) {
            .crc32, .crc32c => 8,
            .crc64nvme => 12,
            .sha1 => 28,
            .sha256 => 44,
        };
    }

    pub fn rawLength(self: Algorithm) usize {
        return switch (self) {
            .crc32, .crc32c => 4,
            .crc64nvme => 8,
            .sha1 => 20,
            .sha256 => 32,
        };
    }

    pub fn parse(value: []const u8) ?Algorithm {
        if (std.ascii.eqlIgnoreCase(value, "CRC32")) return .crc32;
        if (std.ascii.eqlIgnoreCase(value, "CRC32C")) return .crc32c;
        if (std.ascii.eqlIgnoreCase(value, "CRC64NVME")) return .crc64nvme;
        if (std.ascii.eqlIgnoreCase(value, "SHA1")) return .sha1;
        if (std.ascii.eqlIgnoreCase(value, "SHA256")) return .sha256;
        return null;
    }
};

pub const Value = union(Algorithm) {
    crc32: u32,
    crc32c: u32,
    crc64nvme: u64,
    sha1: [20]u8,
    sha256: [32]u8,

    pub fn algorithm(self: Value) Algorithm {
        return self;
    }
};

pub fn encodeValue(value: Value, buffer: []u8) []const u8 {
    const algorithm = value.algorithm();
    std.debug.assert(buffer.len >= algorithm.encodedLength());
    var raw: [32]u8 = undefined;
    const raw_slice = raw[0..algorithm.rawLength()];
    switch (value) {
        .crc32 => |checksum| std.mem.writeInt(u32, raw_slice[0..4], checksum, .big),
        .crc32c => |checksum| std.mem.writeInt(u32, raw_slice[0..4], checksum, .big),
        .crc64nvme => |checksum| std.mem.writeInt(u64, raw_slice[0..8], checksum, .big),
        .sha1 => |digest| @memcpy(raw_slice, &digest),
        .sha256 => |digest| @memcpy(raw_slice, &digest),
    }
    return std.base64.standard.Encoder.encode(buffer[0..algorithm.encodedLength()], raw_slice);
}

pub fn decodeValue(algorithm: Algorithm, encoded: []const u8) ?Value {
    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return null;
    if (decoded_size != algorithm.rawLength()) {
        return null;
    }
    var raw: [32]u8 = undefined;
    const raw_slice = raw[0..algorithm.rawLength()];
    std.base64.standard.Decoder.decode(raw_slice, encoded) catch return null;
    return switch (algorithm) {
        .crc32 => .{ .crc32 = std.mem.readInt(u32, raw_slice[0..4], .big) },
        .crc32c => .{ .crc32c = std.mem.readInt(u32, raw_slice[0..4], .big) },
        .crc64nvme => .{ .crc64nvme = std.mem.readInt(u64, raw_slice[0..8], .big) },
        .sha1 => blk: {
            var digest: [20]u8 = undefined;
            @memcpy(&digest, raw_slice);
            break :blk .{ .sha1 = digest };
        },
        .sha256 => blk: {
            var digest: [32]u8 = undefined;
            @memcpy(&digest, raw_slice);
            break :blk .{ .sha256 = digest };
        },
    };
}

test "CRC64NVME matches the standard check value" {
    try std.testing.expectEqual(@as(u64, 0xae8b14860a799888), Crc64Nvme.hash("123456789"));
}

test "flexible checksum algorithms match standard check values" {
    try std.testing.expectEqual(@as(u32, 0xcbf43926), Crc32.hash("123456789"));
    try std.testing.expectEqual(@as(u32, 0xe3069283), Crc32C.hash("123456789"));
    var sha1: [20]u8 = undefined;
    Sha1.hash("123456789", &sha1, .{});
    try std.testing.expectEqualStrings(
        "f7c3bc1d808e04732adf679965ccc34ca7ae3441",
        &std.fmt.bytesToHex(sha1, .lower),
    );
    var sha256: [32]u8 = undefined;
    Sha256.hash("123456789", &sha256, .{});
    try std.testing.expectEqualStrings(
        "15e2b0d3c33891ebb0f1ef609ec419420c20e320ce94c65fbc8c3312448eb225",
        &std.fmt.bytesToHex(sha256, .lower),
    );
}
