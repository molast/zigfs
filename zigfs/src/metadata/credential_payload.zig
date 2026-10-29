const std = @import("std");
const credential_domain = @import("../domain/credential.zig");

pub const magic = [4]u8{ 'Z', 'F', 'C', 'R' };
pub const major_version: u16 = 1;
pub const minor_version: u16 = 3;
pub const legacy_minor_version: u16 = 0;
pub const header_length: usize = 80;
pub const legacy_header_length: usize = 56;

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
const expires_at_offset: usize = 56;

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
    InvalidMetadata,
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
    const total_length = std.math.add(usize, header_length + value.name.len + value.description.len + value.policy_document.len, fields_length) catch {
        return error.OutOfMemory;
    };
    const bytes = try allocator.alloc(u8, total_length);
    @memset(bytes, 0);
    @memcpy(bytes[0..magic.len], &magic);
    std.mem.writeInt(u16, bytes[4..6], major_version, .little);
    std.mem.writeInt(u16, bytes[6..8], minor_version, .little);
    std.mem.writeInt(u16, bytes[flags_offset..status_offset], @intFromEnum(value.kind), .little);
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
    @memcpy(bytes[tag_offset .. tag_offset + value.secret_tag.len], &value.secret_tag);
    std.mem.writeInt(
        i64,
        bytes[expires_at_offset..64],
        value.expires_at_unix_seconds orelse 0,
        .little,
    );

    std.mem.writeInt(u16, bytes[64..66], @intCast(value.name.len), .little);
    std.mem.writeInt(u16, bytes[66..68], @intCast(value.description.len), .little);
    bytes[68] = @intFromBool(value.inherit_policy);
    std.mem.writeInt(u32, bytes[72..76], @intCast(value.policy_document.len), .little);
    var cursor = header_length;
    @memcpy(bytes[cursor..][0..value.access_key.len], value.access_key);
    cursor += value.access_key.len;
    @memcpy(bytes[cursor..][0..value.owner.len], value.owner);
    cursor += value.owner.len;
    @memcpy(bytes[cursor..][0..value.encrypted_secret.len], value.encrypted_secret);
    cursor += value.encrypted_secret.len;
    @memcpy(bytes[cursor..][0..value.name.len], value.name);
    cursor += value.name.len;
    @memcpy(bytes[cursor..][0..value.description.len], value.description);
    cursor += value.description.len;
    @memcpy(bytes[cursor..], value.policy_document);
    return bytes;
}

pub fn decode(bytes: []const u8) DecodeError!credential_domain.View {
    if (bytes.len < legacy_header_length) return error.InvalidLength;
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return error.InvalidMagic;
    if (std.mem.readInt(u16, bytes[4..6], .little) != major_version) {
        return error.UnsupportedMajorVersion;
    }
    const encoded_minor_version = std.mem.readInt(u16, bytes[6..8], .little);
    if (encoded_minor_version > minor_version) {
        return error.UnsupportedMinorVersion;
    }
    const encoded_header_length = if (encoded_minor_version == legacy_minor_version)
        legacy_header_length
    else if (encoded_minor_version == 1)
        64
    else if (encoded_minor_version == 2)
        72
    else
        header_length;
    if (bytes.len < encoded_header_length) return error.InvalidLength;
    const flags = std.mem.readInt(u16, bytes[flags_offset..status_offset], .little);
    const kind: credential_domain.Kind = if (encoded_minor_version == legacy_minor_version) blk: {
        if (flags != 0) return error.UnsupportedFlags;
        break :blk .permanent;
    } else switch (flags) {
        1 => .permanent,
        2 => .temporary,
        else => return error.UnsupportedFlags,
    };
    if (bytes[reserved_offset] != 0) return error.UnsupportedFlags;
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
    const name_length: usize = if (encoded_minor_version >= 2) std.mem.readInt(u16, bytes[64..66], .little) else 0;
    const description_length: usize = if (encoded_minor_version >= 2) std.mem.readInt(u16, bytes[66..68], .little) else 0;
    if (encoded_minor_version >= 2 and (bytes[68] > 1 or !std.mem.allEqual(u8, bytes[69..72], 0))) return error.UnsupportedFlags;
    const document_length: usize = if (encoded_minor_version >= 3) std.mem.readInt(u32, bytes[72..76], .little) else 0;
    if (document_length > 256 * 1024 or (encoded_minor_version >= 3 and !std.mem.allEqual(u8, bytes[76..80], 0))) return error.InvalidMetadata;
    const expected_length = std.math.add(usize, encoded_header_length + name_length + description_length + document_length, fields_length) catch {
        return error.InvalidLength;
    };
    if (bytes.len != expected_length) return error.InvalidLength;

    var nonce: [12]u8 = undefined;
    @memcpy(&nonce, bytes[nonce_offset..tag_offset]);
    var tag: [16]u8 = undefined;
    @memcpy(&tag, bytes[tag_offset .. tag_offset + tag.len]);
    const expires_at_raw = if (encoded_minor_version == legacy_minor_version)
        0
    else
        std.mem.readInt(i64, bytes[expires_at_offset..64], .little);
    if (encoded_minor_version < 2 and kind == .permanent and expires_at_raw != 0) return error.UnsupportedFlags;
    const expires_at_unix_seconds: ?i64 = if (expires_at_raw != 0) expires_at_raw else null;
    var cursor = encoded_header_length;
    const access_key = bytes[cursor..][0..access_key_length];
    cursor += access_key_length;
    const owner = bytes[cursor..][0..owner_length];
    cursor += owner_length;
    const encrypted_secret = bytes[cursor..][0..encrypted_secret_length];
    cursor += encrypted_secret_length;
    const name = bytes[cursor..][0..name_length];
    cursor += name_length;
    const description = bytes[cursor..][0..description_length];
    cursor += description_length;
    const document = bytes[cursor..][0..document_length];
    const value: credential_domain.View = .{
        .access_key = access_key,
        .owner = owner,
        .status = status,
        .policy = policy,
        .created_at_unix_seconds = created_at_unix_seconds,
        .secret_nonce = nonce,
        .secret_tag = tag,
        .encrypted_secret = encrypted_secret,
        .kind = kind,
        .expires_at_unix_seconds = expires_at_unix_seconds,
        .name = name,
        .description = description,
        .inherit_policy = encoded_minor_version >= 2 and bytes[68] == 1,
        .policy_document = document,
    };
    credential_domain.validateView(value) catch |err| return switch (err) {
        error.InvalidAccessKey => error.InvalidAccessKey,
        error.InvalidOwner => error.InvalidOwner,
        error.InvalidEncryptedSecret => error.InvalidEncryptedSecret,
        error.InvalidCreatedAt => error.InvalidCreatedAt,
        error.InvalidExpiration => error.InvalidLength,
        error.InvalidMetadata => error.InvalidMetadata,
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
    try std.testing.expectEqual(value.kind, decoded.kind);
    try std.testing.expectEqual(value.expires_at_unix_seconds, decoded.expires_at_unix_seconds);
}

test "credential payload keeps V1.0 records readable as permanent credentials" {
    const current = try encode(std.testing.allocator, testValue());
    defer std.testing.allocator.free(current);
    const fields = current[header_length..];
    const legacy = try std.testing.allocator.alloc(u8, legacy_header_length + fields.len);
    defer std.testing.allocator.free(legacy);
    @memcpy(legacy[0..legacy_header_length], current[0..legacy_header_length]);
    std.mem.writeInt(u16, legacy[6..8], legacy_minor_version, .little);
    std.mem.writeInt(u16, legacy[flags_offset..status_offset], 0, .little);
    @memcpy(legacy[legacy_header_length..], fields);
    const decoded = try decode(legacy);
    try std.testing.expectEqual(credential_domain.Kind.permanent, decoded.kind);
    try std.testing.expectEqual(@as(?i64, null), decoded.expires_at_unix_seconds);
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

test "credential V1.3 persists metadata inheritance policies and expiry while old records stay readable" {
    const a = std.testing.allocator;
    var value = testValue();
    value.name = "backup";
    value.description = "daily backup credential";
    value.inherit_policy = true;
    value.policy_document = "{\"Version\":\"2012-10-17\",\"Statement\":[]}";
    value.expires_at_unix_seconds = value.created_at_unix_seconds + 86400 * 30;
    const encoded = try encode(a, value);
    defer a.free(encoded);
    const decoded = try decode(encoded);
    try std.testing.expectEqualStrings(value.name, decoded.name);
    try std.testing.expectEqualStrings(value.description, decoded.description);
    try std.testing.expect(decoded.inherit_policy);
    try std.testing.expectEqualStrings(value.policy_document, decoded.policy_document);
    try std.testing.expectEqual(value.expires_at_unix_seconds, decoded.expires_at_unix_seconds);
    const plain = try encode(a, testValue());
    defer a.free(plain);
    const legacy = try a.alloc(u8, 64 + plain.len - header_length);
    defer a.free(legacy);
    @memcpy(legacy[0..64], plain[0..64]);
    std.mem.writeInt(u16, legacy[6..8], 1, .little);
    @memcpy(legacy[64..], plain[header_length..]);
    const old = try decode(legacy);
    try std.testing.expectEqualStrings("", old.name);
    try std.testing.expectEqualStrings("", old.description);
    try std.testing.expect(!old.inherit_policy);
    try std.testing.expectEqualStrings("", old.policy_document);
    const v12 = try a.alloc(u8, 72 + plain.len - header_length);
    defer a.free(v12);
    @memcpy(v12[0..72], plain[0..72]);
    std.mem.writeInt(u16, v12[6..8], 2, .little);
    @memcpy(v12[72..], plain[header_length..]);
    const previous = try decode(v12);
    try std.testing.expectEqualStrings("", previous.policy_document);
}
