//! Internal Web presigning credentials. Never persisted or exposed as AK/SK.
//! The opaque security token encrypts the login session; the signing secret stays
//! on the server. SigV4 binds every URL to its method, object, query and headers.
const std = @import("std");
const Application = @import("../application/mod.zig").Application;
const auth = @import("management_auth.zig");
const session = @import("../auth/management_session.zig");
const box = @import("../auth/secret_box.zig");
const Material = @import("../application/credential_service.zig").AuthMaterial;
pub const access_key = "ZIGFSCONSOLESESSION";
const domain = "zigfs-console-presign-v1";
const Claims = struct { session: []const u8, expires: i64 };

pub fn issue(a: std.mem.Allocator, app: *Application, bearer: []const u8, expires: i64) ![]u8 {
    const plaintext = try std.json.Stringify.valueAlloc(a, Claims{ .session = bearer, .expires = expires }, .{});
    defer {
        std.crypto.secureZero(u8, plaintext);
        a.free(plaintext);
    }
    const sealed = try box.seal(a, app.io.?, app.master_key.?.bytes, domain, plaintext);
    defer sealed.deinit(a);
    const bytes = try std.mem.concat(a, u8, &.{ &sealed.nonce, &sealed.tag, sealed.ciphertext });
    defer a.free(bytes);
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const result = try a.alloc(u8, encoder.calcSize(bytes.len));
    _ = encoder.encode(result, bytes);
    return result;
}

pub fn resolve(a: std.mem.Allocator, app: *Application, token: []const u8, now: i64) !Material {
    if (token.len > 16384) return error.InvalidToken;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const bytes = try temp.alloc(u8, try decoder.calcSizeForSlice(token));
    try decoder.decode(bytes, token);
    if (bytes.len < 28) return error.InvalidToken;
    const plaintext = try box.open(temp, app.master_key.?.bytes, domain, bytes[0..12].*, bytes[12..28].*, bytes[28..]);
    defer std.crypto.secureZero(u8, plaintext);
    const claims = try std.json.parseFromSlice(Claims, temp, plaintext, .{});
    if (claims.value.expires <= now) return error.InvalidToken;
    const principal = (try auth.resolve(temp, app, claims.value.session, now)) orelse return error.InvalidToken;
    var material: Material = undefined;
    if (session.validateCredential(app.config.admin_session_secret, claims.value.session, now)) |credential| {
        material = try app.credentialService().?.resolveForAuth(credential.access_key);
    } else {
        material = .{ .owner = try std.fmt.allocPrint(a, "{s}:{s}", .{ if (principal.federated) "oidc" else "user", principal.username }), .policy = .all, .secret_key = &.{}, .session_token = null };
        errdefer material.deinit(a);
        material.subject_id = try a.dupe(u8, principal.id);
        const documents: []const []const u8 = if (principal.is_root) &.{"{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"*\",\"Resource\":\"*\"}]}"} else principal.documents;
        var owned: std.ArrayList([]u8) = .empty;
        errdefer {
            for (owned.items) |doc| a.free(doc);
            owned.deinit(a);
        }
        for (documents) |document| try owned.append(a, try a.dupe(u8, document));
        material.inherited_documents = try owned.toOwnedSlice(a);
    }
    errdefer material.deinit(a);
    var secret: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&secret, token, app.master_key.?.bytes[0..]);
    defer std.crypto.secureZero(u8, &secret);
    a.free(material.secret_key);
    material.secret_key = &.{};
    material.secret_key = try a.dupe(u8, &std.fmt.bytesToHex(secret, .lower));
    if (material.session_token) |old| a.free(old);
    material.session_token = null;
    material.session_token = try a.dupe(u8, token);
    return material;
}
