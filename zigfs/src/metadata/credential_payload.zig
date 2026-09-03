const std = @import("std");
const credential_domain = @import("../domain/credential.zig");

pub const magic = [4]u8{ 'Z', 'F', 'C', 'R' };
pub const major_version: u16 = 1;
pub const minor_version: u16 = 0;
pub const header_length: usize = 56;

const flags_offset: usize = 8;
const status_offset: usize = 10;
const reserved_offset: usize = 11;
const created_at_offset: usize = 12;
const policy_offset: usize = 20;
const access_key_length_offset: usize = 22;
const owner_length_offset: usize = 24;
const encrypted_secret_length_offset: usize = 26;
const nonce_offset: usize = 28;
const tag_offset: usize = 40;

pub const EncodeError = std.mem.Allocator.Error ||
    credential_domain.ValidationError ||
    error{InvalidPolicy};

pub const DecodeError = error{
    InvalidLength,
    InvalidMagic,
    UnsupportedMajorVersion,
    UnsupportedMinorVersion,
    UnsupportedFlags,
    InvalidStatus,
    InvalidPolicy,
    InvalidAccessKey,
    InvalidOwner,
    InvalidEncryptedSecret,
    InvalidCreatedAt,
};

pub fn encode(
    allocator: std.mem.Allocator,
    value: credential_domain.View,
) EncodeError![]u8 {
    try credential_domain.validateView(value);
    _ = try credential_domain.Policy.fromBits(value.policy.toBits());
    const variable_length = std.math.add(
        usize,
        value.access_key.len,
        value.owner.len,
    ) catch return error.OutOfMemory;
    const fields_length = std.math.add(
        usize,
        variable_length,
        value.encrypted_secret.len,
    ) catch return error.OutOfMemory;
    const total_length = std.math.add(usize, header_length, fields_length) catch {
        return error.OutOfMemory;
    };
    const bytes = try allocator.alloc(u8, total_length);
    @memset(bytes, 0);
    @memcpy(bytes[0..magic.len], &magic);
    std.mem.writeInt(u16, bytes[4..6], major_version, .little);
    std.mem.writeInt(u16, bytes[6..8], minor_version, .little);
    std.mem.writeInt(u16, bytes[flags_offset..status_offset], 0, .little);
    bytes[status_offset] = @intFromEnum(value.status);
    bytes[reserved_offset] = 0;
    std.mem.writeInt(
        i64,
        bytes[created_at_offset..policy_offset],
        value.created_at_unix_seconds,
        .little,
    );
    std.mem.writeInt(u16, bytes[policy_offset..access_key_length_offset], value.policy.toBits(), .little);
    std.mem.writeInt(u16, bytes[access_key_length_offset..owner_length_offset], @intCast(value.access_key.len), .little);
    std.mem.writeInt(u16, bytes[owner_length_offset..encrypted_secret_length_offset], @intCast(value.owner.len), .little);
    std.mem.writeInt(u16, bytes[encrypted_secret_length_offset..nonce_offset], @intCast(value.encrypted_secret.len), .little);
    @memcpy(bytes[nonce_offset..tag_offset], &value.secret_nonce);
    @memcpy(bytes[tag_offset..header_length], &value.secret_tag);

    var cursor = header_length;
    @memcpy(bytes[cursor..][0..value.access_key.len], value.access_key);
    cursor += value.access_key.len;
    @memcpy(bytes[cursor..][0..value.owner.len], value.owner);
    cursor += value.owner.len;
    @memcpy(bytes[cursor..], value.encrypted_secret);
    return bytes;
}

pub fn decode(bytes: []const u8) DecodeError!credential_domain.View {
    if (bytes.len < header_length) return error.InvalidLength;
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return error.InvalidMagic;
    if (std.mem.readInt(u16, bytes[4..6], .little) != major_version) {
        return error.UnsupportedMajorVersion;
    }
    if (std.mem.readInt(u16, bytes[6..8], .little) != minor_version) {
        return error.UnsupportedMinorVersion;
    }
    if (std.mem.readInt(u16, bytes[flags_offset..status_offset], .little) != 0 or
        bytes[reserved_offset] != 0)
    {
        return error.UnsupportedFlags;
    }
    const status: credential_domain.Status = switch (bytes[status_offset]) {
        1 => .active,
        2 => .disabled,
        else => return error.InvalidStatus,
    };
    const created_at_unix_seconds = std.mem.readInt(
        i64,
        bytes[created_at_offset..policy_offset],
        .little,
    );
    const policy = credential_domain.Policy.fromBits(std.mem.readInt(
        u16,
        bytes[policy_offset..access_key_length_offset],
        .little,
    )) catch return error.InvalidPolicy;
    const access_key_length = std.mem.readInt(
        u16,
        bytes[access_key_length_offset..owner_length_offset],
        .little,
    );
    const owner_length = std.mem.readInt(
        u16,
        bytes[owner_length_offset..encrypted_secret_length_offset],
        .little,
    );
    const encrypted_secret_length = std.mem.readInt(
        u16,
        bytes[encrypted_secret_length_offset..nonce_offset],
        .little,
    );
    const first_length = std.math.add(usize, access_key_length, owner_length) catch {
        return error.InvalidLength;
    };
    const fields_length = std.math.add(usize, first_length, encrypted_secret_length) catch {
        return error.InvalidLength;
    };
    const expected_length = std.math.add(usize, header_length, fields_length) catch {
        return error.InvalidLength;
    };
    if (bytes.len != expected_length) return error.InvalidLength;

    var nonce: [12]u8 = undefined;
    @memcpy(&nonce, bytes[nonce_offset..tag_offset]);
    var tag: [16]u8 = undefined;
    @memcpy(&tag, bytes[tag_offset..header_length]);
    var cursor = header_length;
    const access_key = bytes[cursor..][0..access_key_length];
    cursor += access_key_length;
    const owner = bytes[cursor..][0..owner_length];
    cursor += owner_length;
    const encrypted_secret = bytes[cursor..];
    const value: credential_domain.View = .{
        .access_key = access_key,
        .owner = owner,
        .status = status,
        .policy = policy,
        .created_at_unix_seconds = created_at_unix_seconds,
        .secret_nonce = nonce,
        .secret_tag = tag,
        .encrypted_secret = encrypted_secret,
    };
    credential_domain.validateView(value) catch |err| return switch (err) {
        error.InvalidAccessKey => error.InvalidAccessKey,
        error.InvalidOwner => error.InvalidOwner,
        error.InvalidEncryptedSecret => error.InvalidEncryptedSecret,
        error.InvalidCreatedAt => error.InvalidCreatedAt,
    };
    return value;
}

fn testValue() credential_domain.View {
    return .{
        .access_key = "ZF0123456789ABCDEF",
        .owner = "tenant-a",
        .status = .active,
        .policy = .all,
        .created_at_unix_seconds = 1_800_000_000,
        .secret_nonce = .{1} ** 12,
        .secret_tag = .{2} ** 16,
        .encrypted_secret = "0123456789abcdef0123456789abcdef01234567",
    };
}

test "credential payload round trips encrypted secret metadata" {
    const value = testValue();
    const encoded = try encode(std.testing.allocator, value);
    defer std.testing.allocator.free(encoded);
    const decoded = try decode(encoded);
    try std.testing.expectEqualStrings(value.access_key, decoded.access_key);
    try std.testing.expectEqualStrings(value.owner, decoded.owner);
    try std.testing.expectEqual(value.status, decoded.status);
    try std.testing.expectEqual(value.policy, decoded.policy);
    try std.testing.expectEqualStrings(value.encrypted_secret, decoded.encrypted_secret);
}

test "credential payload rejects corruption and plaintext-shaped invalid fields" {
    const valid = try encode(std.testing.allocator, testValue());
    defer std.testing.allocator.free(valid);
    try std.testing.expectError(error.InvalidLength, decode(valid[0 .. valid.len - 1]));

    const invalid = try std.testing.allocator.dupe(u8, valid);
    defer std.testing.allocator.free(invalid);
    invalid[status_offset] = 9;
    try std.testing.expectError(error.InvalidStatus, decode(invalid));
}
