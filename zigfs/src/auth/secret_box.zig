const std = @import("std");

const Aead = std.crypto.aead.aes_gcm.Aes256Gcm;

pub const Key = [Aead.key_length]u8;
pub const Nonce = [Aead.nonce_length]u8;
pub const Tag = [Aead.tag_length]u8;

pub const Sealed = struct {
    nonce: Nonce,
    tag: Tag,
    ciphertext: []u8,

    pub fn deinit(self: Sealed, allocator: std.mem.Allocator) void {
        allocator.free(self.ciphertext);
    }
};

pub const Error = std.mem.Allocator.Error || std.Io.RandomSecureError || error{
    AuthenticationFailed,
};

pub fn seal(
    allocator: std.mem.Allocator,
    io: std.Io,
    key: Key,
    associated_data: []const u8,
    plaintext: []const u8,
) Error!Sealed {
    var nonce: Nonce = undefined;
    try io.randomSecure(&nonce);
    const ciphertext = try allocator.alloc(u8, plaintext.len);
    errdefer allocator.free(ciphertext);
    var tag: Tag = undefined;
    Aead.encrypt(ciphertext, &tag, plaintext, associated_data, nonce, key);
    return .{ .nonce = nonce, .tag = tag, .ciphertext = ciphertext };
}

pub fn open(
    allocator: std.mem.Allocator,
    key: Key,
    associated_data: []const u8,
    nonce: Nonce,
    tag: Tag,
    ciphertext: []const u8,
) Error![]u8 {
    const plaintext = try allocator.alloc(u8, ciphertext.len);
    errdefer {
        std.crypto.secureZero(u8, plaintext);
        allocator.free(plaintext);
    }
    Aead.decrypt(plaintext, ciphertext, tag, associated_data, nonce, key) catch {
        return error.AuthenticationFailed;
    };
    return plaintext;
}

test "AES-256-GCM credential secret round trip binds access key" {
    const key = [_]u8{0x42} ** Aead.key_length;
    const sealed = try seal(
        std.testing.allocator,
        std.testing.io,
        key,
        "ZF0123456789ABCDEF",
        "0123456789abcdef0123456789abcdef01234567",
    );
    defer sealed.deinit(std.testing.allocator);
    const plaintext = try open(
        std.testing.allocator,
        key,
        "ZF0123456789ABCDEF",
        sealed.nonce,
        sealed.tag,
        sealed.ciphertext,
    );
    defer {
        std.crypto.secureZero(u8, plaintext);
        std.testing.allocator.free(plaintext);
    }
    try std.testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef01234567",
        plaintext,
    );
    try std.testing.expectError(
        error.AuthenticationFailed,
        open(
            std.testing.allocator,
            key,
            "ZF999999999999999999",
            sealed.nonce,
            sealed.tag,
            sealed.ciphertext,
        ),
    );
}
