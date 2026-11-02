const std = @import("std");
const Application = @import("../application/mod.zig").Application;
const session = @import("../auth/management_session.zig");
const identities = @import("../application/identity_store.zig");
const policies = @import("../application/policy_store.zig");
const iam = @import("../auth/iam_policy.zig");

pub const Principal = struct {
    id: []const u8,
    username: []const u8,
    expires_at: i64,
    is_root: bool = false,
    federated: bool = false,
    display_name: []const u8 = "",
    email: []const u8 = "",
    refreshable: bool = false,
    documents: []const []const u8 = &.{},
    pub fn allows(self: Principal, a: std.mem.Allocator, action: []const u8, resource: []const u8, context: iam.Context) bool {
        return self.is_root or iam.allowsWithContext(a, self.documents, action, resource, context);
    }
};

// Uses a request arena. Both identity and policy reads share the application's
// single-machine lock, so each request sees a coherent authorization snapshot.
pub fn resolve(a: std.mem.Allocator, app: *Application, token: []const u8, now: i64) !?Principal {
    if (session.validate(app.config.admin_session_secret, token, now)) |expires| return .{
        .id = "deployment-root",
        .username = app.config.admin_username,
        .expires_at = expires,
        .is_root = true,
    };
    if (std.mem.startsWith(u8, token, "o1.")) {
        if (token.len != 67) return null;
        const io = app.io orelse return error.Unavailable;
        const root = app.data_root orelse return error.Unavailable;
        app.policy_mutex.lockUncancelable(io);
        defer app.policy_mutex.unlock(io);
        const oidc = @import("../application/oidc_auth.zig");
        const identity = (try oidc.resolve(a, root, io, app.master_key.?.bytes, try oidc.digest(a, token), now)) orelse return null;
        return .{ .id = identity.subject_id, .federated = true, .display_name = identity.display_name, .email = identity.email, .refreshable = identity.refresh_token.len > 0, .username = identity.username, .expires_at = identity.expires_at, .documents = try oidc.documents(a, root, io, identity) };
    }
    const claims = session.validateUser(app.config.admin_session_secret, token, now) orelse return null;
    const io = app.io orelse return error.Unavailable;
    const root = app.data_root orelse return error.Unavailable;
    app.policy_mutex.lockUncancelable(io);
    defer app.policy_mutex.unlock(io);
    const snapshot = try identities.load(root, io, a);
    for (snapshot.value.users) |user| {
        if (!std.mem.eql(u8, user.id, &claims.subject)) continue;
        if (!user.enabled or user.auth_version != claims.version) return null;
        const loaded = try policies.load(root, io, a);
        return .{ .id = user.id, .username = user.name, .expires_at = claims.expires_at, .documents = try identities.documentsForUser(a, user, snapshot.value, loaded.value) };
    }
    return null;
}

pub fn authenticateUser(a: std.mem.Allocator, app: *Application, username: []const u8, password: []const u8, now: i64) !?session.UserToken {
    if (password.len > 1024 or !identities.validName(username)) return null;
    const io = app.io orelse return error.Unavailable;
    const root = app.data_root orelse return error.Unavailable;
    app.policy_mutex.lockUncancelable(io);
    defer app.policy_mutex.unlock(io);
    const snapshot = try identities.load(root, io, a);
    const index = identities.find(snapshot.value.users, username) orelse return null;
    const user = snapshot.value.users[index];
    if (!user.enabled) return null;
    std.crypto.pwhash.argon2.strVerify(user.password_hash, password, .{ .allocator = a }, io) catch return null;
    return try session.issueUser(io, app.config.admin_session_secret, user.id, user.auth_version, app.config.admin_session_ttl_seconds, now);
}

// Until a route has a narrower body/resource-aware guard it requires full
// management authority. Unknown/new endpoints never default to read access.
pub fn routeAction(method: std.http.Method, path: []const u8) []const u8 {
    if (method != .GET) {
        if (std.mem.eql(u8, path, "/_admin/v1/buckets")) return if (method == .POST) "s3:CreateBucket" else "s3:ListAllMyBuckets";
        if (std.mem.eql(u8, path, "/_admin/v1/sts/assume-role")) return "sts:AssumeRole";
        if (std.mem.startsWith(u8, path, "/_admin/v1/objects/presign")) return "s3:GetObject";
        if (std.mem.startsWith(u8, path, "/_admin/v1/buckets/")) {
            if (!std.mem.endsWith(u8, path, "/policy") and !std.mem.endsWith(u8, path, "/tags") and !std.mem.endsWith(u8, path, "/configuration") and !std.mem.endsWith(u8, path, "/directories")) return "s3:DeleteBucket";
            if (std.mem.endsWith(u8, path, "/policy")) return "s3:PutBucketPolicy";
            if (std.mem.endsWith(u8, path, "/tags")) return "s3:PutBucketTagging";
            if (std.mem.endsWith(u8, path, "/configuration")) return "s3:PutBucketVersioning";
            if (std.mem.endsWith(u8, path, "/directories")) return "s3:PutObject";
        }
        if (std.mem.startsWith(u8, path, "/_admin/v1/multipart-uploads")) return "s3:PutObject";
        return "admin:*";
    }
    if (std.mem.eql(u8, path, "/_admin/v1/system")) return "admin:ServerInfo";
    if (std.mem.eql(u8, path, "/_admin/v1/metrics")) return "admin:Prometheus";
    if (std.mem.eql(u8, path, "/_admin/v1/health")) return "admin:ServerInfo";
    if (std.mem.eql(u8, path, "/_admin/v1/buckets")) return "s3:ListAllMyBuckets";
    if (std.mem.eql(u8, path, "/_admin/v1/users")) return "admin:ListUsers";
    if (std.mem.eql(u8, path, "/_admin/v1/groups")) return "admin:ListGroups";
    if (std.mem.eql(u8, path, "/_admin/v1/organizations")) return "admin:ListOrganizations";
    if (std.mem.eql(u8, path, "/_admin/v1/roles")) return "admin:ListRoles";
    if (std.mem.eql(u8, path, "/_admin/v1/role-sessions")) return "admin:ListRoleSessions";
    if (std.mem.eql(u8, path, "/_admin/v1/access-keys")) return "admin:ListAccessKeys";
    if (std.mem.eql(u8, path, "/_admin/v1/policies")) return "admin:ListUserPolicies";
    if (std.mem.startsWith(u8, path, "/_admin/v1/policies/")) return "admin:GetPolicy";
    if (std.mem.startsWith(u8, path, "/_admin/v1/groups/")) return "admin:GetGroup";
    if (std.mem.startsWith(u8, path, "/_admin/v1/organizations/")) return "admin:GetOrganization";
    if (std.mem.startsWith(u8, path, "/_admin/v1/roles/")) return "admin:GetRole";
    if (std.mem.startsWith(u8, path, "/_admin/v1/role-sessions/")) return "admin:GetRoleSession";
    if (std.mem.startsWith(u8, path, "/_admin/v1/access-keys/")) return "admin:GetAccessKey";
    if (std.mem.startsWith(u8, path, "/_admin/v1/users/") and std.mem.indexOf(u8, path, "/access-keys") == null) return "admin:GetUser";
    if (std.mem.endsWith(u8, path, "/objects")) return "s3:ListBucket";
    if (std.mem.endsWith(u8, path, "/versions")) return "s3:ListBucketVersions";
    if (std.mem.endsWith(u8, path, "/multipart-uploads")) return "s3:ListBucketMultipartUploads";
    return "admin:*";
}

test "management route actions never default ordinary reads to root" {
    try std.testing.expectEqualStrings("admin:ListUsers", routeAction(.GET, "/_admin/v1/users"));
    try std.testing.expectEqualStrings("admin:*", routeAction(.POST, "/_admin/v1/users"));
    try std.testing.expectEqualStrings("admin:*", routeAction(.GET, "/_admin/v1/storage"));
    try std.testing.expectEqualStrings("sts:AssumeRole", routeAction(.POST, "/_admin/v1/sts/assume-role"));
    try std.testing.expectEqualStrings("admin:ListRoles", routeAction(.GET, "/_admin/v1/roles"));
    try std.testing.expectEqualStrings("s3:ListBucket", routeAction(.GET, "/_admin/v1/buckets/photos/objects"));
    try std.testing.expectEqualStrings("s3:PutObject", routeAction(.POST, "/_admin/v1/multipart-uploads"));
}
