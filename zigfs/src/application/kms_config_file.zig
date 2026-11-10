const std = @import("std");

// ZigFS's versioned xl.meta container. This is not the RustFS XL2 erasure layout.
const magic = "ZFKM";
const header_size = 44;
pub fn encode(a: std.mem.Allocator, payload: []const u8) ![]u8 {
    if (payload.len > 128 * 1024) return error.InvalidKmsStore;
    const bytes = try a.alloc(u8, header_size + payload.len);
    @memcpy(bytes[0..4], magic);
    std.mem.writeInt(u16, bytes[4..6], 1, .little);
    std.mem.writeInt(u16, bytes[6..8], 2, .little); // Raw AES-GCM nonce, tag, ciphertext
    std.mem.writeInt(u32, bytes[8..12], @intCast(payload.len), .little);
    std.crypto.hash.sha2.Sha256.hash(payload, bytes[12..44], .{});
    @memcpy(bytes[header_size..], payload);
    return bytes;
}
pub fn decode(bytes: []const u8) ![]const u8 {
    if (bytes.len < header_size or !std.mem.eql(u8, bytes[0..4], magic)) return error.InvalidKmsStore;
    if (std.mem.readInt(u16, bytes[4..6], .little) != 1 or (std.mem.readInt(u16, bytes[6..8], .little) != 1 and std.mem.readInt(u16, bytes[6..8], .little) != 2)) return error.InvalidKmsStore;
    const length = std.mem.readInt(u32, bytes[8..12], .little);
    if (length > 128 * 1024 or length != bytes.len - header_size) return error.InvalidKmsStore;
    const payload = bytes[header_size..];
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &hash, .{});
    if (!std.crypto.timing_safe.eql([32]u8, hash, bytes[12..44].*)) return error.InvalidKmsStore;
    return payload;
}
test "KMS xl.meta validates format, length and checksum" {
    const bytes = try encode(std.testing.allocator, "encrypted-envelope");
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("encrypted-envelope", try decode(bytes));
    try std.testing.expectError(error.InvalidKmsStore, decode(bytes[0 .. bytes.len - 1]));
    bytes[bytes.len - 1] ^= 1;
    try std.testing.expectError(error.InvalidKmsStore, decode(bytes));
    bytes[bytes.len - 1] ^= 1;
    bytes[4] = 2;
    try std.testing.expectError(error.InvalidKmsStore, decode(bytes));
}
