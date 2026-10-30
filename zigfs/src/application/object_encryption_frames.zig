const std = @import("std");
const secret_box = @import("../auth/secret_box.zig");

pub const frame_version: u16 = 1;
pub const plaintext_frame_size: usize = 1024 * 1024;
pub const header_length: usize = 48;

pub const Frame = struct {
    index: u64,
    plaintext_length: u32,
    nonce: secret_box.Nonce,
    tag: secret_box.Tag,
    ciphertext: []u8,

    pub fn deinit(self: Frame, allocator: std.mem.Allocator) void {
        std.crypto.secureZero(u8, self.ciphertext);
        allocator.free(self.ciphertext);
    }
};

pub const Error = std.mem.Allocator.Error || std.Io.RandomSecureError || secret_box.Error || error{
    InvalidHeader,
    InvalidFrame,
    FrameTooLarge,
};

pub fn seal(
    allocator: std.mem.Allocator,
    io: std.Io,
    key: secret_box.Key,
    associated_data: []const u8,
    index: u64,
    plaintext: []const u8,
) Error!Frame {
    if (plaintext.len > plaintext_frame_size or plaintext.len > std.math.maxInt(u32)) return error.FrameTooLarge;
    const ad = try frameAssociatedData(allocator, associated_data, index);
    defer allocator.free(ad);
    const sealed = try secret_box.seal(allocator, io, key, ad, plaintext);
    return .{
        .index = index,
        .plaintext_length = @intCast(plaintext.len),
        .nonce = sealed.nonce,
        .tag = sealed.tag,
        .ciphertext = sealed.ciphertext,
    };
}

pub fn open(
    allocator: std.mem.Allocator,
    key: secret_box.Key,
    associated_data: []const u8,
    frame: Frame,
) Error![]u8 {
    if (frame.ciphertext.len != frame.plaintext_length) return error.InvalidFrame;
    const ad = try frameAssociatedData(allocator, associated_data, frame.index);
    defer allocator.free(ad);
    return secret_box.open(allocator, key, ad, frame.nonce, frame.tag, frame.ciphertext);
}

pub fn encodeHeader(frame: Frame) Error![header_length]u8 {
    if (frame.ciphertext.len != frame.plaintext_length or frame.ciphertext.len > std.math.maxInt(u32)) return error.InvalidFrame;
    var header = @as([header_length]u8, @splat(0));
    std.mem.writeInt(u16, header[0..2], frame_version, .little);
    std.mem.writeInt(u64, header[4..12], frame.index, .little);
    std.mem.writeInt(u32, header[12..16], frame.plaintext_length, .little);
    std.mem.writeInt(u32, header[16..20], @intCast(frame.ciphertext.len), .little);
    @memcpy(header[20..32], &frame.nonce);
    @memcpy(header[32..header_length], &frame.tag);
    return header;
}

pub fn decodeHeader(bytes: []const u8) Error!struct { index: u64, plaintext_length: u32, ciphertext_length: u32, nonce: secret_box.Nonce, tag: secret_box.Tag } {
    if (bytes.len != header_length) return error.InvalidHeader;
    if (std.mem.readInt(u16, bytes[0..2], .little) != frame_version or bytes[2] != 0 or bytes[3] != 0) return error.InvalidHeader;
    const plaintext_length = std.mem.readInt(u32, bytes[12..16], .little);
    const ciphertext_length = std.mem.readInt(u32, bytes[16..20], .little);
    if (plaintext_length != ciphertext_length or plaintext_length > plaintext_frame_size) return error.InvalidFrame;
    var nonce: secret_box.Nonce = undefined;
    var tag: secret_box.Tag = undefined;
    @memcpy(&nonce, bytes[20..32]);
    @memcpy(&tag, bytes[32..header_length]);
    return .{
        .index = std.mem.readInt(u64, bytes[4..12], .little),
        .plaintext_length = plaintext_length,
        .ciphertext_length = ciphertext_length,
        .nonce = nonce,
        .tag = tag,
    };
}

fn frameAssociatedData(allocator: std.mem.Allocator, associated_data: []const u8, index: u64) std.mem.Allocator.Error![]u8 {
    const prefix = "ZIGFS-OBJECT-FRAME-V1:";
    const result = try allocator.alloc(u8, prefix.len + associated_data.len + @sizeOf(u64));
    @memcpy(result[0..prefix.len], prefix);
    @memcpy(result[prefix.len .. prefix.len + associated_data.len], associated_data);
    std.mem.writeInt(u64, result[prefix.len + associated_data.len ..][0..8], index, .little);
    return result;
}

test "object encryption frames authenticate index and round trip headers" {
    const key = @as([@sizeOf(secret_box.Key)]u8, @splat(0x19));
    const frame = try seal(std.testing.allocator, std.testing.io, key, "object-ad", 7, "frame plaintext");
    defer frame.deinit(std.testing.allocator);
    const header = try encodeHeader(frame);
    const decoded = try decodeHeader(&header);
    const opened = try open(std.testing.allocator, key, "object-ad", .{
        .index = decoded.index,
        .plaintext_length = decoded.plaintext_length,
        .nonce = decoded.nonce,
        .tag = decoded.tag,
        .ciphertext = frame.ciphertext,
    });
    defer std.testing.allocator.free(opened);
    try std.testing.expectEqualStrings("frame plaintext", opened);
    try std.testing.expectError(error.AuthenticationFailed, open(std.testing.allocator, key, "object-ad", .{
        .index = 8,
        .plaintext_length = decoded.plaintext_length,
        .nonce = decoded.nonce,
        .tag = decoded.tag,
        .ciphertext = frame.ciphertext,
    }));
}

test "object encryption frames reject tag tampering" {
    const key = @as([@sizeOf(secret_box.Key)]u8, @splat(0x29));
    var frame = try seal(std.testing.allocator, std.testing.io, key, "object-ad", 0, "payload");
    defer frame.deinit(std.testing.allocator);
    frame.tag[0] ^= 1;
    try std.testing.expectError(error.AuthenticationFailed, open(std.testing.allocator, key, "object-ad", frame));
}
