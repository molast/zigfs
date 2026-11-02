const std = @import("std");
const box = @import("../auth/secret_box.zig");
const durable = @import("../metadata/durable.zig");

pub const Provider = struct {
    provider_id: []const u8,
    revision: []const u8 = "",
    environment_managed: bool = false,
    display_name: []const u8 = "",
    enabled: bool = true,
    configuration_url: []const u8,
    client_id: []const u8,
    client_secret: []const u8 = "",
    has_secret: bool = false,
    scopes: []const u8 = "openid,profile,email",
    audiences: []const u8 = "",
    dynamic_redirect: bool = false,
    redirect_uri: []const u8 = "",
    claim_name: []const u8 = "groups",
    claim_prefix: []const u8 = "",
    role_policy: []const u8 = "",
    groups_claim: []const u8 = "groups",
    roles_claim: []const u8 = "roles",
    email_claim: []const u8 = "email",
    username_claim: []const u8 = "preferred_username",

    pub fn redacted(self: Provider) Provider {
        var result = self;
        result.has_secret = self.client_secret.len > 0;
        result.client_secret = "";
        result.revision = "";
        return result;
    }
};
pub const Flow = struct {
    state: []const u8,
    provider_id: []const u8,
    fingerprint: []const u8,
    nonce: []const u8,
    verifier: []const u8,
    redirect_uri: []const u8,
    expires_at: i64,
};
pub const Session = struct {
    token_hash: []const u8,
    provider_id: []const u8,
    fingerprint: []const u8,
    subject_id: []const u8,
    username: []const u8,
    display_name: []const u8 = "",
    email: []const u8 = "",
    issuer: []const u8 = "",
    external_subject: []const u8 = "",
    sid: []const u8 = "",
    nonce: []const u8 = "",
    id_token: []const u8 = "",
    refresh_token: []const u8 = "",
    hard_expires_at: i64 = 0,
    policies: []const []const u8,
    expires_at: i64,
};
pub const LogoutReplay = struct { digest: []const u8, expires_at: i64 };
pub const Snapshot = struct {
    logout_replays: []const LogoutReplay = &.{},
    version: u32 = 1,
    items: []const Provider = &.{},
    flows: []const Flow = &.{},
    sessions: []const Session = &.{},
};
pub const path = ".zigfs/system/oidc-providers.enc";

pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    return true;
}
fn validUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) return false;
    return uri.host != null and uri.user == null and uri.password == null and uri.fragment == null;
}
pub fn validate(p: Provider) !void {
    if (!validId(p.provider_id) or p.client_id.len == 0 or p.client_secret.len == 0) return error.InvalidProvider;
    for ([_][]const u8{ p.provider_id, p.display_name, p.configuration_url, p.client_id, p.client_secret, p.scopes, p.audiences, p.redirect_uri, p.claim_name, p.claim_prefix, p.role_policy, p.groups_claim, p.roles_claim, p.email_claim, p.username_claim }) |value| {
        if (value.len > 8192 or !std.unicode.utf8ValidateSlice(value)) return error.InvalidProvider;
    }
    if (!validUrl(p.configuration_url) or !validUrl(p.redirect_uri)) return error.InvalidProviderUrl;
    var scopes = std.mem.splitScalar(u8, p.scopes, ',');
    while (scopes.next()) |scope| if (std.mem.eql(u8, std.mem.trim(u8, scope, " \t"), "openid")) return;
    return error.MissingOpenIdScope;
}
pub fn load(root: std.Io.Dir, io: std.Io, a: std.mem.Allocator, key: box.Key) !std.json.Parsed(Snapshot) {
    const data = root.readFileAlloc(io, path, a, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return std.json.parseFromSlice(Snapshot, a, "{}", .{}),
        else => return err,
    };
    defer a.free(data);
    if (data.len < 28) return error.InvalidOidcStorage;
    const plain = try box.open(a, key, path, data[0..12].*, data[12..28].*, data[28..]);
    defer {
        std.crypto.secureZero(u8, plain);
        a.free(plain);
    }
    const parsed = try std.json.parseFromSlice(Snapshot, a, plain, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (parsed.value.version != 1 or parsed.value.items.len > 128) return error.InvalidOidcStorage;
    for (parsed.value.items, 0..) |p, i| {
        try validate(p);
        for (parsed.value.items[i + 1 ..]) |other| if (std.mem.eql(u8, p.provider_id, other.provider_id)) return error.DuplicateProvider;
    }
    return parsed;
}
pub fn save(root: std.Io.Dir, io: std.Io, a: std.mem.Allocator, key: box.Key, snapshot: Snapshot) !void {
    if (snapshot.items.len > 128 or snapshot.flows.len > 256 or snapshot.sessions.len > 4096) return error.ProviderLimit;
    const plain = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer {
        std.crypto.secureZero(u8, plain);
        a.free(plain);
    }
    if (plain.len > 4 * 1024 * 1024 - 28) return error.ProviderLimit;
    const sealed = try box.seal(a, io, key, path, plain);
    defer sealed.deinit(a);
    try root.createDirPath(io, ".zigfs/system");
    var atomic = try root.createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, &sealed.nonce);
    try atomic.file.writeStreamingAll(io, &sealed.tag);
    try atomic.file.writeStreamingAll(io, sealed.ciphertext);
    try atomic.file.sync(io);
    try atomic.replace(io);
    try durable.syncParent(root, io, path);
}

test "OIDC configuration encrypts secrets and survives reload; corruption fails closed" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const key: box.Key = @splat(42);
    const p: Provider = .{ .provider_id = "test", .client_id = "console", .client_secret = "test-secret-never-return", .configuration_url = "https://idp.example/.well-known/openid-configuration", .redirect_uri = "https://console.example/callback" };
    try validate(p);
    try save(tmp.dir, io, a, key, .{ .items = &.{p} });
    const bytes = try tmp.dir.readFileAlloc(io, path, a, .limited(100000));
    defer a.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, p.client_secret) == null);
    const loaded = try load(tmp.dir, io, a, key);
    defer loaded.deinit();
    try std.testing.expectEqualStrings(p.client_secret, loaded.value.items[0].client_secret);
    try std.testing.expectEqualStrings("", loaded.value.items[0].redacted().client_secret);
    try std.testing.expect(loaded.value.items[0].redacted().has_secret);
    try std.testing.expectError(error.AuthenticationFailed, load(tmp.dir, io, a, @splat(43)));
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "broken" });
    try std.testing.expectError(error.InvalidOidcStorage, load(tmp.dir, io, a, key));
}
test "OIDC validation rejects invalid names, URLs and scopes" {
    var p: Provider = .{ .provider_id = "../test", .client_id = "client", .client_secret = "secret", .configuration_url = "https://idp.example/config", .dynamic_redirect = true, .redirect_uri = "https://console.example" };
    try std.testing.expectError(error.InvalidProvider, validate(p));
    p.provider_id = "test";
    p.configuration_url = "file:///tmp/config";
    try std.testing.expectError(error.InvalidProviderUrl, validate(p));
    p.configuration_url = "https://idp.example/config";
    p.scopes = "profile,email";
    try std.testing.expectError(error.MissingOpenIdScope, validate(p));
}

test "OIDC recovery rejects duplicate IDs and failed save preserves last snapshot" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const key: box.Key = @splat(42);
    const p: Provider = .{ .provider_id = "provider", .client_id = "client", .client_secret = "secret", .configuration_url = "https://idp.example/config", .dynamic_redirect = true, .redirect_uri = "https://console.example" };
    try save(tmp.dir, io, a, key, .{ .items = &.{ p, p } });
    try std.testing.expectError(error.DuplicateProvider, load(tmp.dir, io, a, key));
    try save(tmp.dir, io, a, key, .{ .items = &.{p} });
    const too_many = try a.alloc(Provider, 129);
    defer a.free(too_many);
    @memset(too_many, p);
    try std.testing.expectError(error.ProviderLimit, save(tmp.dir, io, a, key, .{ .items = too_many }));
    const snapshot = try load(tmp.dir, io, a, key);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 1), snapshot.value.items.len);
}

/// Startup reconciliation. Environment-owned entries are read-only through the API;
/// removing them from the environment revokes their sessions by removing the provider.
pub fn importEnvironment(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, key: box.Key, raw: []const u8) !void {
    if (raw.len > 1024 * 1024) return error.InvalidProvider;
    const incoming = try std.json.parseFromSlice([]Provider, a, raw, .{});
    defer incoming.deinit();
    if (incoming.value.len > 128) return error.ProviderLimit;
    const loaded = try load(root, io, a, key);
    defer loaded.deinit();
    var items: std.ArrayList(Provider) = .empty;
    defer items.deinit(a);
    for (loaded.value.items) |p| if (!p.environment_managed) {
        try items.append(a, p);
    };
    const policies = try @import("policy_store.zig").load(root, io, a);
    defer policies.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    for (incoming.value) |input| {
        var p = input;
        p.environment_managed = true;
        p.has_secret = false;
        p.revision = "";
        try validate(p);
        for (items.items) |existing| if (std.mem.eql(u8, existing.provider_id, p.provider_id)) return error.DuplicateProvider;
        var names = std.mem.splitScalar(u8, p.role_policy, ',');
        while (names.next()) |raw_name| {
            const name = std.mem.trim(u8, raw_name, " \t");
            if (name.len == 0) continue;
            var found = false;
            for (policies.value) |policy| if (std.mem.eql(u8, policy.name, name)) {
                found = true;
            };
            if (!found) return error.UnknownPolicy;
        }
        const canonical = try std.json.Stringify.valueAlloc(temp, p, .{});
        for (loaded.value.items) |existing| {
            if (!existing.environment_managed or !std.mem.eql(u8, existing.provider_id, p.provider_id)) continue;
            var old = existing;
            old.revision = "";
            if (std.mem.eql(u8, canonical, try std.json.Stringify.valueAlloc(temp, old, .{}))) p.revision = existing.revision;
        }
        if (p.revision.len == 0) p.revision = try @import("identity_store.zig").newId(temp, io);
        try items.append(a, p);
    }
    var snapshot = loaded.value;
    snapshot.items = items.items;
    try save(root, io, a, key, snapshot);
}

test "OIDC environment import preserves revisions and rejects conflicting source ownership" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const key: box.Key = @splat(42);
    const raw =
        \\[{"provider_id":"env","client_id":"console","client_secret":"secret","configuration_url":"https://id.example/.well-known/openid-configuration","redirect_uri":"https://console.example/callback"}]
    ;
    try importEnvironment(a, tmp.dir, io, key, raw);
    const first = try load(tmp.dir, io, a, key);
    defer first.deinit();
    try std.testing.expect(first.value.items[0].environment_managed);
    try importEnvironment(a, tmp.dir, io, key, raw);
    const second = try load(tmp.dir, io, a, key);
    defer second.deinit();
    try std.testing.expectEqualStrings(first.value.items[0].revision, second.value.items[0].revision);
    try importEnvironment(a, tmp.dir, io, key, "[]");
    const removed = try load(tmp.dir, io, a, key);
    defer removed.deinit();
    try std.testing.expectEqual(@as(usize, 0), removed.value.items.len);
    var local = first.value.items[0];
    local.environment_managed = false;
    try save(tmp.dir, io, a, key, .{ .items = &.{local} });
    try std.testing.expectError(error.DuplicateProvider, importEnvironment(a, tmp.dir, io, key, raw));
    const preserved = try load(tmp.dir, io, a, key);
    defer preserved.deinit();
    try std.testing.expect(!preserved.value.items[0].environment_managed);
}
