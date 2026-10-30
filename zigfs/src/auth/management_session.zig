const std = @import("std");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const nonce_length = 16;
const nonce_hex_length = nonce_length * 2;
const mac_hex_length = HmacSha256.mac_length * 2;

pub const max_token_length = 128;

pub const IssuedToken = struct {
    bytes: [max_token_length]u8,
    len: usize,
    expires_at_unix_seconds: i64,

    pub fn value(self: *const IssuedToken) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub fn authenticate(
    configured_username: []const u8,
    configured_password: []const u8,
    username: []const u8,
    password: []const u8,
) bool {
    return timingSafeStringEqual(configured_username, username) and
        timingSafeStringEqual(configured_password, password);
}

pub fn issue(
    io: std.Io,
    secret: []const u8,
    ttl_seconds: u64,
    now_unix_seconds: i64,
) (std.Io.RandomSecureError || error{NoSpaceLeft})!IssuedToken {
    var nonce: [nonce_length]u8 = undefined;
    try io.randomSecure(&nonce);
    const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
    const expires_at = std.math.add(i64, now_unix_seconds, @intCast(ttl_seconds)) catch {
        return error.NoSpaceLeft;
    };

    var result: IssuedToken = .{
        .bytes = undefined,
        .len = 0,
        .expires_at_unix_seconds = expires_at,
    };
    const signed_value = std.fmt.bufPrint(&result.bytes, "{d}.{s}", .{
        expires_at,
        &nonce_hex,
    }) catch return error.NoSpaceLeft;

    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, signed_value, secret);
    const mac_hex = std.fmt.bytesToHex(mac, .lower);
    const remaining = result.bytes[signed_value.len..];
    const suffix = std.fmt.bufPrint(remaining, ".{s}", .{&mac_hex}) catch {
        return error.NoSpaceLeft;
    };
    result.len = signed_value.len + suffix.len;
    return result;
}

pub fn validate(secret: []const u8, token: []const u8, now_unix_seconds: i64) ?i64 {
    var parts = std.mem.splitScalar(u8, token, '.');
    const expires_text = parts.next() orelse return null;
    const nonce_hex = parts.next() orelse return null;
    const provided_mac_hex = parts.next() orelse return null;
    if (parts.next() != null or
        nonce_hex.len != nonce_hex_length or
        provided_mac_hex.len != mac_hex_length)
    {
        return null;
    }

    const expires_at = std.fmt.parseInt(i64, expires_text, 10) catch return null;
    if (expires_at <= now_unix_seconds) return null;

    var nonce: [nonce_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&nonce, nonce_hex) catch return null;
    var provided_mac: [HmacSha256.mac_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&provided_mac, provided_mac_hex) catch return null;

    const mac_separator = std.mem.lastIndexOfScalar(u8, token, '.') orelse return null;
    var expected_mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&expected_mac, token[0..mac_separator], secret);
    if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, expected_mac, provided_mac)) {
        return null;
    }
    return expires_at;
}

fn timingSafeStringEqual(expected: []const u8, actual: []const u8) bool {
    var expected_digest: [32]u8 = undefined;
    var actual_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(expected, &expected_digest, .{});
    std.crypto.hash.sha2.Sha256.hash(actual, &actual_digest, .{});
    return std.crypto.timing_safe.eql([32]u8, expected_digest, actual_digest);
}

test "management credentials are checked by ZigFS" {
    try std.testing.expect(authenticate("admin", "correct", "admin", "correct"));
    try std.testing.expect(!authenticate("admin", "correct", "other", "correct"));
    try std.testing.expect(!authenticate("admin", "correct", "admin", "wrong"));
}

test "management session token is signed and expires" {
    const issued = try issue(
        std.testing.io,
        "0123456789abcdef0123456789abcdef",
        3600,
        1_800_000_000,
    );
    try std.testing.expectEqual(
        @as(?i64, 1_800_003_600),
        validate("0123456789abcdef0123456789abcdef", issued.value(), 1_800_000_001),
    );
    try std.testing.expectEqual(
        @as(?i64, null),
        validate("wrong-secret", issued.value(), 1_800_000_001),
    );
    try std.testing.expectEqual(
        @as(?i64, null),
        validate("0123456789abcdef0123456789abcdef", issued.value(), 1_800_003_600),
    );
}

test "management session token rejects tampering" {
    var issued = try issue(
        std.testing.io,
        "0123456789abcdef0123456789abcdef",
        3600,
        1_800_000_000,
    );
    issued.bytes[0] = if (issued.bytes[0] == '1') '2' else '1';
    try std.testing.expectEqual(
        @as(?i64, null),
        validate("0123456789abcdef0123456789abcdef", issued.value(), 1_800_000_001),
    );
}

pub const UserClaims = struct {
    subject: [32]u8,
    version: u64,
    expires_at: i64,
};
pub const UserToken = struct {
    bytes: [256]u8,
    len: usize,
    pub fn value(self: *const UserToken) []const u8 {
        return self.bytes[0..self.len];
    }
};

// Purpose-separated, signed identity claims. Permissions are never embedded:
// each request resolves the current user and policies from durable storage.
pub fn issueUser(io: std.Io, secret: []const u8, subject: []const u8, version: u64, ttl: u64, now: i64) !UserToken {
    if (subject.len != 32) return error.InvalidSubject;
    var nonce: [16]u8 = undefined;
    try io.randomSecure(&nonce);
    const expires = try std.math.add(i64, now, @intCast(ttl));
    var result: UserToken = .{ .bytes = undefined, .len = 0 };
    const payload = try std.fmt.bufPrint(&result.bytes, "u1.{s}.{d}.{d}.{s}", .{ subject, version, expires, std.fmt.bytesToHex(nonce, .lower) });
    var mac: [32]u8 = undefined;
    HmacSha256.create(&mac, payload, secret);
    const suffix = try std.fmt.bufPrint(result.bytes[payload.len..], ".{s}", .{std.fmt.bytesToHex(mac, .lower)});
    result.len = payload.len + suffix.len;
    return result;
}
pub fn validateUser(secret: []const u8, token: []const u8, now: i64) ?UserClaims {
    var parts = std.mem.splitScalar(u8, token, '.');
    if (!std.mem.eql(u8, parts.next() orelse return null, "u1")) return null;
    const subject = parts.next() orelse return null;
    const version = std.fmt.parseInt(u64, parts.next() orelse return null, 10) catch return null;
    const expires = std.fmt.parseInt(i64, parts.next() orelse return null, 10) catch return null;
    const nonce = parts.next() orelse return null;
    const signature = parts.next() orelse return null;
    if (parts.next() != null or subject.len != 32 or nonce.len != 32 or signature.len != 64 or expires <= now) return null;
    var id: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&id, subject) catch return null;
    _ = std.fmt.hexToBytes(&id, nonce) catch return null;
    var actual: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&actual, signature) catch return null;
    var expected: [32]u8 = undefined;
    HmacSha256.create(&expected, token[0..std.mem.lastIndexOfScalar(u8, token, '.').?], secret);
    if (!std.crypto.timing_safe.eql([32]u8, expected, actual)) return null;
    var claims: UserClaims = .{ .subject = undefined, .version = version, .expires_at = expires };
    @memcpy(&claims.subject, subject);
    return claims;
}

test "user sessions bind purpose identity version and expiration" {
    const token = try issueUser(std.testing.io, "test-secret", "0123456789abcdef0123456789abcdef", 9, 60, 100);
    const claims = validateUser("test-secret", token.value(), 159).?;
    try std.testing.expectEqual(@as(u64, 9), claims.version);
    try std.testing.expect(validateUser("test-secret", token.value(), 160) == null);
    try std.testing.expect(validateUser("other-secret", token.value(), 100) == null);
    try std.testing.expect(validate("test-secret", token.value(), 100) == null);
}
