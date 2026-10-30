const std = @import("std");
const secret_box = @import("../auth/secret_box.zig");

pub const Error = std.mem.Allocator.Error || std.Io.RandomSecureError || secret_box.Error || error{
    InvalidWrappedKey,
};

pub const SealedObject = struct {
    wrapped_key_nonce: secret_box.Nonce,
    wrapped_key_tag: secret_box.Tag,
    wrapped_key: []u8,
    data_nonce: secret_box.Nonce,
    data_tag: secret_box.Tag,
    ciphertext: []u8,

    pub fn deinit(self: SealedObject, allocator: std.mem.Allocator) void {
        std.crypto.secureZero(u8, self.wrapped_key);
        allocator.free(self.wrapped_key);
        std.crypto.secureZero(u8, self.ciphertext);
        allocator.free(self.ciphertext);
    }
};

pub const WrappedKey = struct {
    nonce: secret_box.Nonce,
    tag: secret_box.Tag,
    ciphertext: [@sizeOf(secret_box.Key)]u8,
};

const wrapped_key_label = "ZIGFS-OBJECT-DEK-V1:";
const data_label = "ZIGFS-OBJECT-DATA-V1:";

pub fn generateDataKey(io: std.Io) Error!secret_box.Key {
    var key: secret_box.Key = undefined;
    try io.randomSecure(&key);
    return key;
}

pub fn wrapDataKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    master_key: secret_box.Key,
    associated_data: []const u8,
    data_key: secret_box.Key,
) Error!WrappedKey {
    const wrapped_ad = try domainSeparatedAssociatedData(allocator, wrapped_key_label, associated_data);
    defer allocator.free(wrapped_ad);
    const sealed = try secret_box.seal(allocator, io, master_key, wrapped_ad, &data_key);
    defer sealed.deinit(allocator);
    if (sealed.ciphertext.len != @sizeOf(secret_box.Key)) return error.InvalidWrappedKey;
    var result: WrappedKey = .{ .nonce = sealed.nonce, .tag = sealed.tag, .ciphertext = undefined };
    @memcpy(&result.ciphertext, sealed.ciphertext);
    return result;
}

pub fn unwrapDataKey(
    allocator: std.mem.Allocator,
    master_key: secret_box.Key,
    associated_data: []const u8,
    wrapped: WrappedKey,
) Error!secret_box.Key {
    const wrapped_ad = try domainSeparatedAssociatedData(allocator, wrapped_key_label, associated_data);
    defer allocator.free(wrapped_ad);
    const bytes = try secret_box.open(allocator, master_key, wrapped_ad, wrapped.nonce, wrapped.tag, &wrapped.ciphertext);
    defer {
        std.crypto.secureZero(u8, bytes);
        allocator.free(bytes);
    }
    if (bytes.len != @sizeOf(secret_box.Key)) return error.InvalidWrappedKey;
    var result: secret_box.Key = undefined;
    @memcpy(&result, bytes);
    return result;
}

pub fn seal(
    allocator: std.mem.Allocator,
    io: std.Io,
    master_key: secret_box.Key,
    associated_data: []const u8,
    plaintext: []const u8,
) Error!SealedObject {
    var dek: secret_box.Key = undefined;
    try io.randomSecure(&dek);
    defer std.crypto.secureZero(u8, &dek);

    const wrapped_ad = try domainSeparatedAssociatedData(allocator, wrapped_key_label, associated_data);
    defer allocator.free(wrapped_ad);
    const wrapped = try secret_box.seal(allocator, io, master_key, wrapped_ad, &dek);
    errdefer wrapped.deinit(allocator);

    const data_ad = try domainSeparatedAssociatedData(allocator, data_label, associated_data);
    defer allocator.free(data_ad);
    const data = secret_box.seal(allocator, io, dek, data_ad, plaintext) catch |err| {
        return err;
    };
    return .{
        .wrapped_key_nonce = wrapped.nonce,
        .wrapped_key_tag = wrapped.tag,
        .wrapped_key = wrapped.ciphertext,
        .data_nonce = data.nonce,
        .data_tag = data.tag,
        .ciphertext = data.ciphertext,
    };
}

pub fn open(
    allocator: std.mem.Allocator,
    master_key: secret_box.Key,
    associated_data: []const u8,
    sealed: SealedObject,
) Error![]u8 {
    if (sealed.wrapped_key.len != @sizeOf(secret_box.Key)) return error.InvalidWrappedKey;
    const wrapped_ad = try domainSeparatedAssociatedData(allocator, wrapped_key_label, associated_data);
    defer allocator.free(wrapped_ad);
    const dek_bytes = try secret_box.open(
        allocator,
        master_key,
        wrapped_ad,
        sealed.wrapped_key_nonce,
        sealed.wrapped_key_tag,
        sealed.wrapped_key,
    );
    defer {
        std.crypto.secureZero(u8, dek_bytes);
        allocator.free(dek_bytes);
    }
    var dek: secret_box.Key = undefined;
    @memcpy(&dek, dek_bytes);
    const data_ad = try domainSeparatedAssociatedData(allocator, data_label, associated_data);
    defer allocator.free(data_ad);
    return secret_box.open(allocator, dek, data_ad, sealed.data_nonce, sealed.data_tag, sealed.ciphertext);
}

fn domainSeparatedAssociatedData(
    allocator: std.mem.Allocator,
    label: []const u8,
    associated_data: []const u8,
) std.mem.Allocator.Error![]u8 {
    const result = try allocator.alloc(u8, label.len + associated_data.len);
    @memcpy(result[0..label.len], label);
    @memcpy(result[label.len..], associated_data);
    return result;
}

test "object encryption seals and authenticates DEK and data" {
    const master_key = @as([@sizeOf(secret_box.Key)]u8, @splat(0x42));
    const sealed = try seal(std.testing.allocator, std.testing.io, master_key, "bucket/object/generation", "secret object data");
    defer sealed.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, sealed.ciphertext, "secret object data") == null);
    const plaintext = try open(std.testing.allocator, master_key, "bucket/object/generation", sealed);
    defer {
        std.crypto.secureZero(u8, plaintext);
        std.testing.allocator.free(plaintext);
    }
    try std.testing.expectEqualStrings("secret object data", plaintext);
    try std.testing.expectError(error.AuthenticationFailed, open(std.testing.allocator, master_key, "bucket/other/generation", sealed));
}

test "object encryption rejects wrapped DEK tampering" {
    const master_key = @as([@sizeOf(secret_box.Key)]u8, @splat(0x11));
    var sealed = try seal(std.testing.allocator, std.testing.io, master_key, "object-ad", "payload");
    defer sealed.deinit(std.testing.allocator);
    sealed.wrapped_key_tag[0] ^= 0x80;
    try std.testing.expectError(error.AuthenticationFailed, open(std.testing.allocator, master_key, "object-ad", sealed));
}
