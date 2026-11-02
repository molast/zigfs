//! OIDC verification and authorization live in ZigFS; the BFF only transports browser redirects.
const std = @import("std");
const store = @import("oidc_store.zig");
const Application = @import("mod.zig").Application;
const Value = std.json.Value;
const Sha256 = std.crypto.hash.sha2.Sha256;
const rsa = std.crypto.Certificate.rsa;

pub fn string(v: Value, key: []const u8) ![]const u8 {
    if (v != .object) return error.InvalidResponse;
    const result = v.object.get(key) orelse return error.InvalidResponse;
    if (result != .string or result.string.len == 0) return error.InvalidResponse;
    return result.string;
}
pub fn digest(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    Sha256.hash(value, &hash, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}
pub fn fingerprint(a: std.mem.Allocator, p: store.Provider) ![]const u8 {
    return digest(a, try std.json.Stringify.valueAlloc(a, p, .{}));
}
fn random(a: std.mem.Allocator, io: std.Io) ![]const u8 {
    var bytes: [32]u8 = undefined;
    try io.randomSecure(&bytes);
    return a.dupe(u8, &std.fmt.bytesToHex(bytes, .lower));
}
fn b64decode(a: std.mem.Allocator, text: []const u8) ![]u8 {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const out = try a.alloc(u8, try decoder.calcSizeForSlice(text));
    try decoder.decode(out, text);
    return out;
}
fn b64encode(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out = try a.alloc(u8, encoder.calcSize(bytes.len));
    return encoder.encode(out, bytes);
}
pub fn escape(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const hex = "0123456789ABCDEF";
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~", c) != null) try out.append(a, c) else try out.appendSlice(a, &.{ '%', hex[c >> 4], hex[c & 15] });
    }
    return out.items;
}
fn secureUrl(url: []const u8) !void {
    const uri = try std.Uri.parse(url);
    if (uri.user != null or uri.password != null or uri.fragment != null or uri.host == null) return error.InvalidEndpoint;
    if (std.mem.eql(u8, uri.scheme, "https")) return;
    // Plain HTTP is restricted to loopback for local IdP integration tests.
    const host = switch (uri.host.?) {
        .raw => |h| h,
        .percent_encoded => |h| h,
    };
    if (std.mem.eql(u8, uri.scheme, "http") and (std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "[::1]"))) return;
    return error.InsecureEndpoint;
}
fn fetch(a: std.mem.Allocator, io: std.Io, url: []const u8, body: ?[]const u8) !Value {
    return fetchAuthenticated(a, io, url, body, null);
}
fn fetchAuthenticated(a: std.mem.Allocator, io: std.Io, url: []const u8, body: ?[]const u8, authorization: ?[]const u8) !Value {
    var done: std.Io.Event = .unset;
    var future = try io.concurrent(fetchWork, .{ a, io, url, body, authorization, &done });
    defer _ = future.cancel(io) catch {};
    try done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    return future.await(io);
}
fn fetchWork(a: std.mem.Allocator, io: std.Io, url: []const u8, body: ?[]const u8, authorization: ?[]const u8, done: *std.Io.Event) !Value {
    defer done.set(io);
    try secureUrl(url);
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    const buffer = try a.alloc(u8, 1024 * 1024);
    var writer = std.Io.Writer.fixed(buffer);
    var headers: std.ArrayList(std.http.Header) = .empty;
    try headers.append(a, .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" });
    if (authorization) |auth| try headers.append(a, .{ .name = "Authorization", .value = auth });
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .payload = body,
        .response_writer = &writer,
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .extra_headers = headers.items,
    });
    if (result.status != .ok) return error.ProviderUnavailable;
    return (try std.json.parseFromSlice(Value, a, writer.buffered(), .{ .allocate = .alloc_always })).value;
}
const Discovery = struct { issuer: []const u8, authorization: []const u8, token: []const u8, jwks: []const u8, end_session: []const u8 = "", secret_post: bool = false };
fn discovery(a: std.mem.Allocator, io: std.Io, p: store.Provider) !Discovery {
    const data = try fetch(a, io, p.configuration_url, null);
    var result: Discovery = .{ .issuer = try string(data, "issuer"), .authorization = try string(data, "authorization_endpoint"), .token = try string(data, "token_endpoint"), .jwks = try string(data, "jwks_uri") };
    if (data.object.get("token_endpoint_auth_methods_supported")) |methods| {
        if (methods != .array) return error.InvalidResponse;
        var basic = false;
        for (methods.array.items) |method| {
            if (method == .string and std.mem.eql(u8, method.string, "client_secret_post")) result.secret_post = true;
            if (method == .string and std.mem.eql(u8, method.string, "client_secret_basic")) basic = true;
        }
        if (!result.secret_post and !basic) return error.UnsupportedClientAuthentication;
    }
    result.end_session = string(data, "end_session_endpoint") catch "";
    if (result.end_session.len > 0) try secureUrl(result.end_session);
    try secureUrl(result.issuer);
    try secureUrl(result.authorization);
    try secureUrl(result.token);
    try secureUrl(result.jwks);
    // Bind issuer to the configured discovery location rather than trusting a JWT issuer.
    const expected = try std.fmt.allocPrint(a, "{s}/.well-known/openid-configuration", .{std.mem.trimEnd(u8, result.issuer, "/")});
    if (!std.mem.eql(u8, expected, p.configuration_url)) return error.IssuerMismatch;
    return result;
}
fn findProvider(snapshot: store.Snapshot, id: []const u8) !store.Provider {
    for (snapshot.items) |p| if (std.mem.eql(u8, p.provider_id, id) and p.enabled) return p;
    return error.ProviderDisabled;
}
fn prune(a: std.mem.Allocator, snapshot: *store.Snapshot, now: i64) !void {
    var flows: std.ArrayList(store.Flow) = .empty;
    for (snapshot.flows) |flow| if (flow.expires_at > now) {
        try flows.append(a, flow);
    };
    snapshot.flows = flows.items;
    var sessions: std.ArrayList(store.Session) = .empty;
    for (snapshot.sessions) |session| if (@max(session.expires_at, session.hard_expires_at) > now) {
        try sessions.append(a, session);
    };
    snapshot.sessions = sessions.items;
}
pub const Start = struct { authorization_url: []const u8, state: []const u8 };
pub fn start(a: std.mem.Allocator, app: *Application, id: []const u8) !Start {
    const root = app.data_root orelse return error.Unavailable;
    const io = app.io orelse return error.Unavailable;
    const key = app.master_key.?.bytes;
    var p: store.Provider = undefined;
    {
        app.policy_mutex.lockUncancelable(io);
        defer app.policy_mutex.unlock(io);
        const loaded = try store.load(root, io, a, key);
        p = try findProvider(loaded.value, id);
    }
    // The BFF callback is never derived from a caller-supplied Host header. Even
    // dynamic mode uses the explicitly registered callback as its trust anchor.
    const callback_url = if (p.dynamic_redirect) blk: {
        try secureUrl(p.redirect_uri);
        const authority_start = (std.mem.indexOf(u8, p.redirect_uri, "://") orelse return error.InvalidCallback) + 3;
        const authority_end = std.mem.indexOfPos(u8, p.redirect_uri, authority_start, "/") orelse p.redirect_uri.len;
        break :blk try std.fmt.allocPrint(a, "{s}/api/v1/auth/oidc/callback", .{p.redirect_uri[0..authority_end]});
    } else p.redirect_uri;
    if (callback_url.len == 0) return error.InvalidCallback;
    try secureUrl(callback_url);
    const config = try discovery(a, io, p);
    const state = try random(a, io);
    const nonce = try random(a, io);
    const verifier = try random(a, io);
    var hash: [32]u8 = undefined;
    Sha256.hash(verifier, &hash, .{});
    const challenge = try b64encode(a, &hash);
    const stamp = try fingerprint(a, p);
    const now = std.Io.Clock.real.now(io).toSeconds();
    app.policy_mutex.lockUncancelable(io);
    defer app.policy_mutex.unlock(io);
    const loaded = try store.load(root, io, a, key);
    if (!std.mem.eql(u8, stamp, try fingerprint(a, try findProvider(loaded.value, id)))) return error.ProviderChanged;
    var snapshot = loaded.value;
    try prune(a, &snapshot, now);
    var flows: std.ArrayList(store.Flow) = .empty;
    try flows.appendSlice(a, snapshot.flows);
    try flows.append(a, .{ .state = state, .provider_id = id, .fingerprint = stamp, .nonce = nonce, .verifier = verifier, .redirect_uri = callback_url, .expires_at = now + 300 });
    snapshot.flows = flows.items;
    try store.save(root, io, a, key, snapshot);
    const scopes = try a.dupe(u8, p.scopes);
    for (scopes) |*c| if (c.* == ',') {
        c.* = ' ';
    };
    return .{ .state = state, .authorization_url = try std.fmt.allocPrint(a, "{s}{s}response_type=code&client_id={s}&redirect_uri={s}&scope={s}&state={s}&nonce={s}&code_challenge={s}&code_challenge_method=S256", .{ config.authorization, if (std.mem.indexOfScalar(u8, config.authorization, '?') == null) "?" else "&", try escape(a, p.client_id), try escape(a, callback_url), try escape(a, scopes), state, nonce, challenge }) };
}
fn numeric(v: Value, key: []const u8) !i64 {
    const n = if (v == .object) v.object.get(key) orelse return error.InvalidClaims else return error.InvalidClaims;
    return if (n == .integer) n.integer else error.InvalidClaims;
}
fn audienceHas(value: Value, audience: []const u8) bool {
    if (value == .string) return std.mem.eql(u8, value.string, audience);
    if (value == .array) for (value.array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, audience)) return true;
    };
    return false;
}
fn verifySignature(a: std.mem.Allocator, algorithm: []const u8, key: Value, sig: []const u8, message: []const u8) !void {
    inline for (.{ .{ "RS256", Sha256, false }, .{ "RS384", std.crypto.hash.sha2.Sha384, false }, .{ "RS512", std.crypto.hash.sha2.Sha512, false }, .{ "PS256", Sha256, true }, .{ "PS384", std.crypto.hash.sha2.Sha384, true }, .{ "PS512", std.crypto.hash.sha2.Sha512, true } }) |scheme| {
        if (std.mem.eql(u8, algorithm, scheme[0])) {
            if (!std.mem.eql(u8, try string(key, "kty"), "RSA")) return error.InvalidKey;
            const modulus = try b64decode(a, try string(key, "n"));
            const exponent = try b64decode(a, try string(key, "e"));
            const pk = try rsa.PublicKey.fromBytes(exponent, modulus);
            switch (modulus.len) {
                inline 256, 384, 512 => |len| {
                    if (sig.len != len) return error.InvalidSignature;
                    const Scheme = if (scheme[2]) rsa.PSSSignature else rsa.PKCS1v1_5Signature;
                    try Scheme.verify(len, sig[0..len], message, pk, scheme[1]);
                },
                else => return error.InvalidKey,
            }
            return;
        }
    }
    inline for (.{ .{ "ES256", "P-256", std.crypto.sign.ecdsa.EcdsaP256Sha256 }, .{ "ES384", "P-384", std.crypto.sign.ecdsa.EcdsaP384Sha384 } }) |scheme| {
        if (std.mem.eql(u8, algorithm, scheme[0])) {
            if (!std.mem.eql(u8, try string(key, "kty"), "EC") or !std.mem.eql(u8, try string(key, "crv"), scheme[1])) return error.InvalidKey;
            const Scheme = scheme[2];
            const len = Scheme.Signature.encoded_length / 2;
            const x = try b64decode(a, try string(key, "x"));
            const y = try b64decode(a, try string(key, "y"));
            if (x.len != len or y.len != len or sig.len != 2 * len) return error.InvalidKey;
            var sec1: [1 + 2 * len]u8 = undefined;
            sec1[0] = 4;
            @memcpy(sec1[1..][0..len], x);
            @memcpy(sec1[1 + len ..], y);
            try Scheme.Signature.fromBytes(sig[0 .. 2 * len].*).verify(message, try Scheme.PublicKey.fromSec1(&sec1));
            return;
        }
    }
    if (std.mem.eql(u8, algorithm, "EdDSA")) {
        if (!std.mem.eql(u8, try string(key, "kty"), "OKP") or !std.mem.eql(u8, try string(key, "crv"), "Ed25519")) return error.InvalidKey;
        const x = try b64decode(a, try string(key, "x"));
        if (x.len != 32 or sig.len != 64) return error.InvalidKey;
        try std.crypto.sign.Ed25519.Signature.fromBytes(sig[0..64].*).verify(message, try std.crypto.sign.Ed25519.PublicKey.fromBytes(x[0..32].*));
        return;
    }
    return error.InvalidAlgorithm;
}
fn signedClaims(a: std.mem.Allocator, jwt: []const u8, jwks: Value) !Value {
    if (jwt.len > 65536) return error.InvalidToken;
    var parts = std.mem.splitScalar(u8, jwt, '.');
    const h = parts.next() orelse return error.InvalidToken;
    const b = parts.next() orelse return error.InvalidToken;
    const s = parts.next() orelse return error.InvalidToken;
    if (parts.next() != null) return error.InvalidToken;
    const header = (try std.json.parseFromSlice(Value, a, try b64decode(a, h), .{})).value;
    const algorithm = try string(header, "alg");
    if (header.object.contains("crit") or header.object.contains("b64")) return error.InvalidAlgorithm;
    const kid = try string(header, "kid");
    const sig = try b64decode(a, s);
    if (jwks != .object) return error.InvalidKey;
    const keys = jwks.object.get("keys") orelse return error.InvalidKey;
    if (keys != .array or keys.array.items.len > 64) return error.InvalidKey;
    var matched: ?Value = null;
    for (keys.array.items) |key| {
        const key_id = string(key, "kid") catch continue;
        if (!std.mem.eql(u8, key_id, kid)) continue;
        if (matched != null) return error.InvalidKey;
        matched = key;
    }
    const key = matched orelse return error.InvalidKey;
    if (key.object.get("alg")) |alg| if (alg != .string or !std.mem.eql(u8, alg.string, algorithm)) return error.InvalidKey;
    if (key.object.get("use")) |use| if (use != .string or !std.mem.eql(u8, use.string, "sig")) return error.InvalidKey;
    if (key.object.get("key_ops")) |ops| {
        if (ops != .array or !audienceHas(ops, "verify")) return error.InvalidKey;
    }
    const message = jwt[0 .. h.len + 1 + b.len];
    try verifySignature(a, algorithm, key, sig, message);
    return (try std.json.parseFromSlice(Value, a, try b64decode(a, b), .{})).value;
}
pub fn verifyJwt(a: std.mem.Allocator, jwt: []const u8, jwks: Value, issuer: []const u8, p: store.Provider, nonce: ?[]const u8, now: i64) !Value {
    const claims = try signedClaims(a, jwt, jwks);
    if (!std.mem.eql(u8, try string(claims, "iss"), issuer)) return error.IssuerMismatch;
    _ = try string(claims, "sub");
    const aud = claims.object.get("aud") orelse return error.InvalidAudience;
    if (aud == .array) {
        if (aud.array.items.len == 0) return error.InvalidAudience;
        for (aud.array.items) |value| if (value != .string or value.string.len == 0) return error.InvalidAudience;
    } else if (aud != .string or aud.string.len == 0) return error.InvalidAudience;
    // ID tokens must always be intended for this client, regardless of additional audiences.
    var valid_audience = audienceHas(aud, p.client_id);
    if (nonce == null and !valid_audience) {
        var others = std.mem.splitScalar(u8, p.audiences, ',');
        while (others.next()) |item| {
            const candidate = std.mem.trim(u8, item, " \t");
            if (candidate.len > 0 and audienceHas(aud, candidate)) valid_audience = true;
        }
    }
    if (!valid_audience) return error.InvalidAudience;
    if (claims.object.get("azp")) |azp| {
        if (azp != .string or !std.mem.eql(u8, azp.string, p.client_id)) return error.InvalidAudience;
    } else if (aud == .array and aud.array.items.len > 1) return error.InvalidAudience;
    if (try numeric(claims, "exp") <= now or try numeric(claims, "iat") > now + 60) return error.ExpiredToken;
    if (claims.object.contains("nbf") and try numeric(claims, "nbf") > now + 60) return error.ExpiredToken;
    if (nonce) |expected| if (!std.mem.eql(u8, try string(claims, "nonce"), expected)) return error.InvalidNonce;
    return claims;
}
fn claim(v: Value, path: []const u8) ?Value {
    if (path.len == 0) return null;
    var current = v;
    var segments = std.mem.splitScalar(u8, path, '.');
    while (segments.next()) |part| {
        if (current != .object) return null;
        current = current.object.get(part) orelse return null;
    }
    return current;
}
fn addName(a: std.mem.Allocator, names: *std.ArrayList([]const u8), value: Value, prefix: []const u8) !void {
    if (value == .array) {
        for (value.array.items) |item| {
            if (item != .string) return error.InvalidClaims;
            try addName(a, names, item, prefix);
        }
    } else if (value == .string) {
        if (!std.mem.startsWith(u8, value.string, prefix)) return;
        const name = value.string[prefix.len..];
        if (!@import("identity_store.zig").validName(name)) return error.InvalidClaims;
        for (names.items) |existing| if (std.mem.eql(u8, existing, name)) return;
        if (names.items.len >= 128) return error.InvalidClaims;
        try names.append(a, name);
    } else return error.InvalidClaims;
}
pub fn policyNames(a: std.mem.Allocator, p: store.Provider, claims: Value) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    if (p.role_policy.len > 0) {
        var tokens = std.mem.splitScalar(u8, p.role_policy, ',');
        while (tokens.next()) |name| try addName(a, &names, .{ .string = std.mem.trim(u8, name, " \t") }, "");
    } else {
        for ([_][]const u8{ p.claim_name, p.groups_claim, p.roles_claim }) |path| if (claim(claims, path)) |value| {
            try addName(a, &names, value, p.claim_prefix);
        };
    }
    if (names.items.len == 0) return error.NoPolicies;
    return names.items;
}
pub const Login = struct { token: []const u8, token_type: []const u8 = "Bearer", subject_id: []const u8, username: []const u8, display_name: []const u8 = "", email: []const u8 = "", external_subject: []const u8 = "", issuer: []const u8 = "", audience: []const u8 = "", expires_at: i64, cookie_expires_at: i64 = 0, is_root: bool = false, federated: bool = true, refreshable: bool = false };
fn profile(claims: Value, path: []const u8) ![]const u8 {
    const value = claim(claims, path) orelse return "";
    if (value != .string or value.string.len > 1024 or !std.unicode.utf8ValidateSlice(value.string)) return error.InvalidClaims;
    for (value.string) |c| if (c < 32 or c == 127) return error.InvalidClaims;
    return value.string;
}
pub fn callback(a: std.mem.Allocator, app: *Application, state: []const u8, code: []const u8) !Login {
    if (state.len != 64 or code.len == 0 or code.len > 8192) return error.InvalidState;
    const root = app.data_root.?;
    const io = app.io.?;
    const key = app.master_key.?.bytes;
    const now = std.Io.Clock.real.now(io).toSeconds();
    var p: store.Provider = undefined;
    var pending: ?store.Flow = null;
    {
        app.policy_mutex.lockUncancelable(io);
        defer app.policy_mutex.unlock(io);
        const loaded = try store.load(root, io, a, key);
        var snapshot = loaded.value;
        var flows: std.ArrayList(store.Flow) = .empty;
        for (snapshot.flows) |flow| {
            if (std.mem.eql(u8, flow.state, state)) pending = flow else if (flow.expires_at > now) try flows.append(a, flow);
        }
        const flow = pending orelse return error.InvalidState;
        if (flow.expires_at <= now) return error.InvalidState;
        p = try findProvider(snapshot, flow.provider_id);
        if (!std.mem.eql(u8, flow.fingerprint, try fingerprint(a, p))) return error.ProviderChanged;
        // Consume before network access; failed or concurrent callbacks cannot replay.
        snapshot.flows = flows.items;
        try store.save(root, io, a, key, snapshot);
    }
    const flow = pending.?;
    const config = try discovery(a, io, p);
    const base_body = try std.fmt.allocPrint(a, "grant_type=authorization_code&code={s}&redirect_uri={s}&client_id={s}&code_verifier={s}", .{ try escape(a, code), try escape(a, flow.redirect_uri), try escape(a, p.client_id), flow.verifier });
    const token = try tokenRequest(a, io, p, config, base_body);
    const jwks = try fetch(a, io, config.jwks, null);
    const claims = try verifyJwt(a, try string(token, "id_token"), jwks, config.issuer, p, flow.nonce, std.Io.Clock.real.now(io).toSeconds());
    return issue(a, app, p, flow.fingerprint, config.issuer, claims, try string(token, "id_token"), string(token, "refresh_token") catch "");
}
fn issue(a: std.mem.Allocator, app: *Application, p: store.Provider, stamp: []const u8, issuer: []const u8, claims: Value, id_token: []const u8, refresh_token: []const u8) !Login {
    const root = app.data_root.?;
    const io = app.io.?;
    const key = app.master_key.?.bytes;
    const now = std.Io.Clock.real.now(io).toSeconds();
    const names = try policyNames(a, p, claims);
    const subject = try digest(a, try std.json.Stringify.valueAlloc(a, .{ p.provider_id, issuer, try string(claims, "sub") }, .{}));
    // Use an internal namespace, never an IdP-controlled username as a local identity.
    const username = try std.fmt.allocPrint(a, "oidc-{s}", .{subject});
    if (try numeric(claims, "exp") <= now) return error.ExpiredToken;
    const hard_expiry = now + @as(i64, @intCast(app.config.admin_session_ttl_seconds));
    const result: Login = .{ .display_name = try profile(claims, p.username_claim), .email = try profile(claims, p.email_claim), .external_subject = try string(claims, "sub"), .issuer = issuer, .audience = if (claims.object.get("aud").? == .string) claims.object.get("aud").?.string else p.client_id, .refreshable = refresh_token.len > 0, .cookie_expires_at = if (refresh_token.len > 0) hard_expiry else 0, .token = try std.fmt.allocPrint(a, "o1.{s}", .{try random(a, io)}), .subject_id = subject, .username = username, .expires_at = @min(try numeric(claims, "exp"), now + @as(i64, @intCast(app.config.admin_session_ttl_seconds))) };
    app.policy_mutex.lockUncancelable(io);
    defer app.policy_mutex.unlock(io);
    const loaded = try store.load(root, io, a, key);
    if (!std.mem.eql(u8, stamp, try fingerprint(a, try findProvider(loaded.value, p.provider_id)))) return error.ProviderChanged;
    const policies = try @import("policy_store.zig").load(root, io, a);
    for (names) |name| {
        var found = false;
        for (policies.value) |policy| if (std.mem.eql(u8, policy.name, name)) {
            found = true;
        };
        if (!found) return error.NoPolicies;
    }
    var snapshot = loaded.value;
    try prune(a, &snapshot, now);
    var sessions: std.ArrayList(store.Session) = .empty;
    try sessions.appendSlice(a, snapshot.sessions);
    try sessions.append(a, .{ .token_hash = try digest(a, result.token), .provider_id = p.provider_id, .fingerprint = stamp, .subject_id = subject, .username = username, .display_name = result.display_name, .email = result.email, .issuer = issuer, .external_subject = result.external_subject, .sid = string(claims, "sid") catch "", .nonce = string(claims, "nonce") catch "", .id_token = id_token, .refresh_token = refresh_token, .hard_expires_at = hard_expiry, .policies = names, .expires_at = result.expires_at });
    snapshot.sessions = sessions.items;
    try store.save(root, io, a, key, snapshot);
    return result;
}
// Caller holds policy_mutex. Every authorization rechecks current provider and policy state.
pub fn resolve(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, key: @import("../auth/secret_box.zig").Key, hash: []const u8, now: i64) !?store.Session {
    const loaded = try store.load(root, io, a, key);
    for (loaded.value.sessions) |session| {
        if (!std.mem.eql(u8, session.token_hash, hash) or session.expires_at <= now) continue;
        const p = findProvider(loaded.value, session.provider_id) catch return null;
        if (!std.mem.eql(u8, session.fingerprint, try fingerprint(a, p))) return null;
        return session;
    }
    return null;
}
pub fn documents(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, session: store.Session) ![][]u8 {
    const policies = try @import("policy_store.zig").load(root, io, a);
    defer policies.deinit();
    var docs: std.ArrayList([]u8) = .empty;
    for (session.policies) |name| for (policies.value) |policy| if (std.mem.eql(u8, policy.name, name)) {
        try docs.append(a, try a.dupe(u8, policy.document));
    };
    return docs.toOwnedSlice(a);
}

pub fn webIdentity(a: std.mem.Allocator, app: *Application, id: []const u8, token: []const u8) !Login {
    const root = app.data_root.?;
    const io = app.io.?;
    var p: store.Provider = undefined;
    {
        app.policy_mutex.lockUncancelable(io);
        defer app.policy_mutex.unlock(io);
        const loaded = try store.load(root, io, a, app.master_key.?.bytes);
        p = try findProvider(loaded.value, id);
    }
    const stamp = try fingerprint(a, p);
    const config = try discovery(a, io, p);
    const jwks = try fetch(a, io, config.jwks, null);
    const claims = try verifyJwt(a, token, jwks, config.issuer, p, null, std.Io.Clock.real.now(io).toSeconds());
    return issue(a, app, p, stamp, config.issuer, claims, "", "");
}
pub fn logout(a: std.mem.Allocator, app: *Application, token: []const u8) !void {
    if (!std.mem.startsWith(u8, token, "o1.") or token.len != 67) return;
    const hash = try digest(a, token);
    const root = app.data_root.?;
    const io = app.io.?;
    app.policy_mutex.lockUncancelable(io);
    defer app.policy_mutex.unlock(io);
    const loaded = try store.load(root, io, a, app.master_key.?.bytes);
    var snapshot = loaded.value;
    var sessions: std.ArrayList(store.Session) = .empty;
    for (snapshot.sessions) |session| if (!std.mem.eql(u8, session.token_hash, hash)) {
        try sessions.append(a, session);
    };
    snapshot.sessions = sessions.items;
    try store.save(root, io, a, app.master_key.?.bytes, snapshot);
}

pub fn validateDiscovery(a: std.mem.Allocator, io: std.Io, p: store.Provider) ![]const u8 {
    const config = try discovery(a, io, p);
    const keys = try fetch(a, io, config.jwks, null);
    if (keys != .object) return error.InvalidKey;
    const values = keys.object.get("keys") orelse return error.InvalidKey;
    if (values != .array or values.array.items.len == 0 or values.array.items.len > 64) return error.InvalidKey;
    return config.issuer;
}

test "OIDC policy claims nested paths prefix deduplication and fixed policy precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const claims = (try std.json.parseFromSlice(Value, a,
        \\{"realm":{"roles":["zig:readonly","zig:readonly","other"]},"groups":["zig:readwrite"]}
    , .{})).value;
    var p: store.Provider = .{ .provider_id = "test", .configuration_url = "https://id.example/.well-known/openid-configuration", .client_id = "console", .claim_name = "realm.roles", .claim_prefix = "zig:" };
    const names = try policyNames(a, p, claims);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("readonly", names[0]);
    try std.testing.expectEqualStrings("readwrite", names[1]);
    p.role_policy = "writeonly";
    const fixed = try policyNames(a, p, claims);
    try std.testing.expectEqual(@as(usize, 1), fixed.len);
    try std.testing.expectEqualStrings("writeonly", fixed[0]);
    p.role_policy = "";
    p.claim_prefix = "unmatched:";
    try std.testing.expectError(error.NoPolicies, policyNames(a, p, claims));
}

test "OIDC endpoints reject insecure remote URLs and embedded credentials" {
    try secureUrl("https://id.example/token");
    try secureUrl("http://127.0.0.1:8080/token");
    try std.testing.expectError(error.InsecureEndpoint, secureUrl("http://id.example/token"));
    try std.testing.expectError(error.InvalidEndpoint, secureUrl("https://user:password@id.example/token"));
    try std.testing.expectError(error.InvalidEndpoint, secureUrl("https://id.example/token#fragment"));
}

test "OIDC provider revision changes invalidate configuration fingerprint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p: store.Provider = .{ .provider_id = "test", .configuration_url = "https://id.example/.well-known/openid-configuration", .client_id = "console", .revision = "first" };
    const first = try fingerprint(a, p);
    p.revision = "second";
    try std.testing.expect(!std.mem.eql(u8, first, try fingerprint(a, p)));
}

fn tokenRequest(a: std.mem.Allocator, io: std.Io, p: store.Provider, config: Discovery, base_body: []const u8) !Value {
    var authorization: ?[]const u8 = null;
    const body = if (config.secret_post) try std.fmt.allocPrint(a, "{s}&client_secret={s}", .{ base_body, try escape(a, p.client_secret) }) else blk: {
        const credentials = try std.fmt.allocPrint(a, "{s}:{s}", .{ try escape(a, p.client_id), try escape(a, p.client_secret) });
        const encoder = std.base64.standard.Encoder;
        const encoded = try a.alloc(u8, encoder.calcSize(credentials.len));
        authorization = try std.fmt.allocPrint(a, "Basic {s}", .{encoder.encode(encoded, credentials)});
        break :blk base_body;
    };
    return fetchAuthenticated(a, io, config.token, body, authorization);
}

fn sessionLogin(token: []const u8, session: store.Session) Login {
    return .{ .token = token, .subject_id = session.subject_id, .username = session.username, .display_name = session.display_name, .email = session.email, .expires_at = session.expires_at, .cookie_expires_at = if (session.refresh_token.len > 0) session.hard_expires_at else 0, .refreshable = session.refresh_token.len > 0 };
}

pub fn refresh(a: std.mem.Allocator, app: *Application, token: []const u8) !Login {
    if (token.len != 67 or !std.mem.startsWith(u8, token, "o1.")) return error.InvalidToken;
    const hash = try digest(a, token);
    const root = app.data_root.?;
    const io = app.io.?;
    const key = app.master_key.?.bytes;
    const now = std.Io.Clock.real.now(io).toSeconds();
    var previous: store.Session = undefined;
    var provider: store.Provider = undefined;
    {
        app.policy_mutex.lockUncancelable(io);
        defer app.policy_mutex.unlock(io);
        const loaded = try store.load(root, io, a, key);
        var snapshot = loaded.value;
        const sessions = try a.dupe(store.Session, snapshot.sessions);
        var found = false;
        for (sessions) |*entry| {
            if (!std.mem.eql(u8, entry.token_hash, hash)) continue;
            previous = entry.*;
            provider = try findProvider(snapshot, entry.provider_id);
            if (!std.mem.eql(u8, entry.fingerprint, try fingerprint(a, provider))) return error.ProviderChanged;
            if (entry.expires_at > now + 60 or (entry.refresh_token.len == 0 and entry.expires_at > now)) return sessionLogin(token, entry.*);
            if (entry.refresh_token.len == 0 or entry.hard_expires_at <= now) return error.ExpiredToken;
            // Claim the refresh token once before contacting the IdP. Concurrent requests
            // can use an unexpired session but never exchange the same refresh token twice.
            entry.refresh_token = "";
            found = true;
            break;
        }
        if (!found) return error.InvalidToken;
        snapshot.sessions = sessions;
        try store.save(root, io, a, key, snapshot);
    }
    errdefer logout(a, app, token) catch {};
    const config = try discovery(a, io, provider);
    const body = try std.fmt.allocPrint(a, "grant_type=refresh_token&refresh_token={s}&client_id={s}", .{ try escape(a, previous.refresh_token), try escape(a, provider.client_id) });
    const response = try tokenRequest(a, io, provider, config, body);
    const raw = try string(response, "id_token");
    const claims = try verifyJwt(a, raw, try fetch(a, io, config.jwks, null), config.issuer, provider, null, std.Io.Clock.real.now(io).toSeconds());
    // Refresh never accepts Other Audiences or changes the established external subject.
    if (!audienceHas(claims.object.get("aud").?, provider.client_id) or !std.mem.eql(u8, try string(claims, "sub"), previous.external_subject)) return error.InvalidClaims;
    if (claims.object.contains("nonce") and !std.mem.eql(u8, try string(claims, "nonce"), previous.nonce)) return error.InvalidNonce;
    const names = try policyNames(a, provider, claims);
    var renewed = previous;
    renewed.policies = names;
    renewed.display_name = try profile(claims, provider.username_claim);
    renewed.email = try profile(claims, provider.email_claim);
    renewed.id_token = raw;
    renewed.refresh_token = string(response, "refresh_token") catch previous.refresh_token;
    renewed.expires_at = @min(try numeric(claims, "exp"), previous.hard_expires_at);
    app.policy_mutex.lockUncancelable(io);
    defer app.policy_mutex.unlock(io);
    const loaded = try store.load(root, io, a, key);
    if (!std.mem.eql(u8, previous.fingerprint, try fingerprint(a, try findProvider(loaded.value, previous.provider_id)))) return error.ProviderChanged;
    const policies = try @import("policy_store.zig").load(root, io, a);
    for (names) |name| {
        var found = false;
        for (policies.value) |policy| if (std.mem.eql(u8, policy.name, name)) {
            found = true;
        };
        if (!found) return error.NoPolicies;
    }
    var snapshot = loaded.value;
    const sessions = try a.dupe(store.Session, snapshot.sessions);
    var found = false;
    for (sessions) |*entry| if (std.mem.eql(u8, entry.token_hash, hash)) {
        entry.* = renewed;
        found = true;
    };
    // Logout/IdP revocation during network access must not resurrect a session.
    if (!found) return error.InvalidToken;
    snapshot.sessions = sessions;
    try store.save(root, io, a, key, snapshot);
    return sessionLogin(token, renewed);
}

pub fn endSession(a: std.mem.Allocator, app: *Application, token: []const u8) ![]const u8 {
    const io = app.io.?;
    var provider: ?store.Provider = null;
    var id_token: []const u8 = "";
    {
        app.policy_mutex.lockUncancelable(io);
        defer app.policy_mutex.unlock(io);
        const loaded = try store.load(app.data_root.?, io, a, app.master_key.?.bytes);
        const hash = try digest(a, token);
        for (loaded.value.sessions) |entry| if (std.mem.eql(u8, entry.token_hash, hash)) {
            provider = findProvider(loaded.value, entry.provider_id) catch null;
            id_token = entry.id_token;
        };
    }
    try logout(a, app, token);
    const p = provider orelse return "";
    const config = discovery(a, io, p) catch return "";
    if (config.end_session.len == 0 or id_token.len == 0) return "";
    return std.fmt.allocPrint(a, "{s}{s}id_token_hint={s}&client_id={s}", .{ config.end_session, if (std.mem.indexOfScalar(u8, config.end_session, '?') == null) "?" else "&", try escape(a, id_token), try escape(a, p.client_id) });
}

pub fn backchannelLogout(a: std.mem.Allocator, app: *Application, provider_id: []const u8, token: []const u8) !void {
    const root = app.data_root.?;
    const io = app.io.?;
    const key = app.master_key.?.bytes;
    var p: store.Provider = undefined;
    {
        app.policy_mutex.lockUncancelable(io);
        defer app.policy_mutex.unlock(io);
        p = try findProvider((try store.load(root, io, a, key)).value, provider_id);
    }
    const config = try discovery(a, io, p);
    const claims = try signedClaims(a, token, try fetch(a, io, config.jwks, null));
    const now = std.Io.Clock.real.now(io).toSeconds();
    if (!std.mem.eql(u8, try string(claims, "iss"), config.issuer) or !audienceHas(claims.object.get("aud") orelse return error.InvalidClaims, p.client_id)) return error.InvalidClaims;
    const issued = try numeric(claims, "iat");
    if (issued > now + 60 or issued < now - 300 or claims.object.contains("nonce")) return error.InvalidClaims;
    if (claims.object.contains("exp") and try numeric(claims, "exp") <= now) return error.ExpiredToken;
    const events = claims.object.get("events") orelse return error.InvalidClaims;
    if (events != .object) return error.InvalidClaims;
    const event = events.object.get("http://schemas.openid.net/event/backchannel-logout") orelse return error.InvalidClaims;
    if (event != .object) return error.InvalidClaims;
    const sub = string(claims, "sub") catch "";
    const sid = string(claims, "sid") catch "";
    if (sub.len == 0 and sid.len == 0) return error.InvalidClaims;
    const replay = try digest(a, try std.fmt.allocPrint(a, "{s}:{s}", .{ provider_id, try string(claims, "jti") }));
    app.policy_mutex.lockUncancelable(io);
    defer app.policy_mutex.unlock(io);
    const loaded = try store.load(root, io, a, key);
    if (!std.mem.eql(u8, try fingerprint(a, p), try fingerprint(a, try findProvider(loaded.value, provider_id)))) return error.ProviderChanged;
    var snapshot = loaded.value;
    var seen: std.ArrayList(store.LogoutReplay) = .empty;
    for (snapshot.logout_replays) |entry| if (entry.expires_at > now) {
        if (std.mem.eql(u8, entry.digest, replay)) return error.InvalidToken;
        try seen.append(a, entry);
    };
    if (seen.items.len >= 4096) return error.ProviderLimit;
    try seen.append(a, .{ .digest = replay, .expires_at = now + 360 });
    var sessions: std.ArrayList(store.Session) = .empty;
    for (snapshot.sessions) |entry| {
        const matches = std.mem.eql(u8, entry.provider_id, provider_id) and std.mem.eql(u8, entry.issuer, config.issuer) and (sub.len == 0 or std.mem.eql(u8, sub, entry.external_subject)) and (sid.len == 0 or std.mem.eql(u8, sid, entry.sid));
        if (!matches) try sessions.append(a, entry);
    }
    snapshot.sessions = sessions.items;
    snapshot.logout_replays = seen.items;
    try store.save(root, io, a, key, snapshot);
}

test "OIDC display profile is bounded plain text and does not select local identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = (try std.json.parseFromSlice(Value, a,
        \\{"profile":{"username":"张三","email":"user@example.test"},"bad":true,"control":"a\nb"}
    , .{})).value;
    try std.testing.expectEqualStrings("张三", try profile(value, "profile.username"));
    try std.testing.expectEqualStrings("", try profile(value, "absent"));
    try std.testing.expectError(error.InvalidClaims, profile(value, "bad"));
    try std.testing.expectError(error.InvalidClaims, profile(value, "control"));
}
