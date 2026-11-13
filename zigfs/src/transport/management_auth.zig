const std = @import("std");
const Application = @import("../application/mod.zig").Application;
const session = @import("../auth/management_session.zig");
const identities = @import("../application/identity_store.zig");
const policies = @import("../application/policy_store.zig");
const iam = @import("../auth/iam_policy.zig");

pub const management_resource = "arn:aws:s3:::*";
pub const kms_resource = "arn:aws:kms:::*";
pub const role_resource = "arn:aws:iam::000000000000:role/capability-check";

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
    policy_names: []const []const u8 = &.{},
    pub fn allows(self: Principal, a: std.mem.Allocator, action: []const u8, resource: []const u8, context: iam.Context) bool {
        return self.is_root or iam.allowsWithContext(a, self.documents, action, resource, context);
    }

    pub fn capabilities(self: Principal, a: std.mem.Allocator) struct { admin: bool, kms: bool, s3: bool, sts: bool, server_info: bool, console_log: bool, kms_list: bool, kms_describe: bool, s3_console: bool } {
        if (self.is_root) return .{ .admin = true, .kms = true, .s3 = true, .sts = true, .server_info = true, .console_log = true, .kms_list = true, .kms_describe = true, .s3_console = true };
        const context: iam.Context = .{};
        return .{
            .admin = allowsAnyResource(self, a, &.{ "admin:ListUsers", "admin:ListGroups", "admin:ListUserPolicies", "admin:ListAccessKeys" }, &.{management_resource}, context),
            .kms = allowsScoped(self, a, &.{ "kms:ListKeys", "kms:DescribeKey", "kms:GenerateDataKey", "kms:Encrypt", "kms:Decrypt", "kms:PutKeyPolicy", "kms:CreateKey", "kms:RotateKey", "kms:DeleteKey", "kms:EnableKey", "kms:DisableKey" }, &.{kms_resource}, context),
            .kms_list = self.allows(a, "kms:ListKeys", kms_resource, context),
            .kms_describe = allowsScoped(self, a, &.{"kms:DescribeKey"}, &.{kms_resource}, context),
            .s3_console = self.allows(a, "s3:ListAllMyBuckets", management_resource, context),
            .s3 = allowsScoped(self, a, &.{ "s3:ListAllMyBuckets", "s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:CreateBucket" }, &.{ "arn:aws:s3:::*", "arn:aws:s3:::*/capability-check" }, context),
            .server_info = self.allows(a, "admin:ServerInfo", management_resource, context),
            .console_log = self.allows(a, "admin:ConsoleLog", management_resource, context),
            .sts = allowsScoped(self, a, &.{"sts:AssumeRole"}, &.{role_resource}, context),
        };
    }

    // Navigation/login hints must consider scoped resources, not just a global
    // wildcard literal. Every candidate is evaluated against ALL documents so
    // explicit Deny remains authoritative. Request authorization never uses this.
    fn allowsScoped(self: Principal, a: std.mem.Allocator, actions: []const []const u8, defaults: []const []const u8, context: iam.Context) bool {
        if (allowsAnyResource(self, a, actions, defaults, context)) return true;
        for (self.documents) |document| {
            const parsed = std.json.parseFromSlice(std.json.Value, a, document, .{}) catch return false;
            defer parsed.deinit();
            if (parsed.value != .object) return false;
            const statements = parsed.value.object.get("Statement") orelse continue;
            if (statements == .array) {
                for (statements.array.items) |statement| if (allowsStatementResources(self, a, actions, statement, context)) return true;
            } else if (allowsStatementResources(self, a, actions, statements, context)) return true;
        }
        return false;
    }

    fn allowsStatementResources(self: Principal, a: std.mem.Allocator, actions: []const []const u8, statement: std.json.Value, context: iam.Context) bool {
        if (statement != .object) return false;
        const resources = statement.object.get("Resource") orelse return false;
        if (resources == .string) return allowsResourceCandidate(self, a, actions, resources.string, context);
        if (resources == .array) for (resources.array.items) |resource| {
            if (resource == .string and allowsResourceCandidate(self, a, actions, resource.string, context)) return true;
        };
        return false;
    }

    fn allowsResourceCandidate(self: Principal, a: std.mem.Allocator, actions: []const []const u8, pattern: []const u8, context: iam.Context) bool {
        // Build a concrete witness for resource globs; do not reverse wildcard
        // matching or interpret a wildcard as permission on every resource.
        var candidate: std.ArrayList(u8) = .empty;
        defer candidate.deinit(a);
        for (pattern) |char| {
            if (char == '*') candidate.appendSlice(a, "capability-check") catch return false else candidate.append(a, if (char == '?') 'x' else char) catch return false;
        }
        return allowsAnyResource(self, a, actions, &.{candidate.items}, context);
    }

    fn allowsAnyResource(self: Principal, a: std.mem.Allocator, actions: []const []const u8, resources: []const []const u8, context: iam.Context) bool {
        for (actions) |action| for (resources) |resource| if (self.allows(a, action, resource, context)) return true;
        return false;
    }

    pub fn hasConsoleAccess(self: Principal, a: std.mem.Allocator) bool {
        const value = self.capabilities(a);
        return value.admin or value.kms_list or value.kms_describe or value.s3_console or value.server_info or value.console_log;
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
    if (session.validateCredential(app.config.admin_session_secret, token, now)) |claims| {
        const credentials = app.credentialService() orelse return error.Unavailable;
        var material = credentials.resolveForAuth(claims.access_key) catch return null;
        defer material.deinit(app.allocator);
        var documents = std.ArrayList([]const u8).empty;
        if (material.key_document) |document| try documents.append(a, try a.dupe(u8, document));
        if (material.inherited_documents) |inherited| for (inherited) |document| try documents.append(a, try a.dupe(u8, document));
        const owner = try a.dupe(u8, material.owner);
        const username = if (std.mem.startsWith(u8, owner, "user:")) owner[5..] else owner;
        const id = try a.dupe(u8, material.subject_id orelse owner);
        return .{ .id = id, .username = username, .expires_at = claims.expires_at, .policy_names = try credentialPolicyNames(a, app, owner, now), .documents = try documents.toOwnedSlice(a) };
    }
    if (std.mem.startsWith(u8, token, "o1.")) {
        if (token.len != 67) return null;
        const io = app.io orelse return error.Unavailable;
        const root = app.data_root orelse return error.Unavailable;
        app.policy_mutex.lockUncancelable(io);
        defer app.policy_mutex.unlock(io);
        const oidc = @import("../application/oidc_auth.zig");
        const identity = (try oidc.resolve(a, root, io, app.master_key.?.bytes, try oidc.digest(a, token), now)) orelse return null;
        return .{ .id = identity.subject_id, .federated = true, .display_name = identity.display_name, .email = identity.email, .refreshable = identity.refresh_token.len > 0, .username = identity.username, .expires_at = identity.expires_at, .policy_names = identity.policies, .documents = try oidc.documents(a, root, io, identity) };
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
        return .{ .id = user.id, .username = user.name, .expires_at = claims.expires_at, .policy_names = try identities.policyNamesForUser(a, user, snapshot.value), .documents = try identities.documentsForUser(a, user, snapshot.value, loaded.value) };
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
    if (std.mem.startsWith(u8, path, "/_admin/v1/buckets/") and std.mem.endsWith(u8, path, "/event-subscriptions")) return "admin:*";
    if (method != .GET) {
        if (std.mem.endsWith(u8, path, "/directories/cleanup") or (method == .DELETE and std.mem.endsWith(u8, path, "/directories"))) return "admin:*";
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
    if (std.mem.eql(u8, path, "/_admin/v1/settings/logs") or std.mem.eql(u8, path, "/_admin/v1/settings/logs/query") or std.mem.eql(u8, path, "/_admin/v1/settings/logs/download")) return "admin:ConsoleLog";
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

test "S3 capability probes bucket resources used by console policies" {
    const document = "{\"Version\":\"2012-10-17\",\"Statement\":{\"Effect\":\"Allow\",\"Action\":\"s3:*\",\"Resource\":\"arn:aws:s3:::*\"}}";
    const principal: Principal = .{ .id = "user-id", .username = "alice", .expires_at = 0, .documents = &.{document} };
    try std.testing.expect(principal.capabilities(std.testing.allocator).s3);
}

test "recursive folder deletion requires management authority" {
    try std.testing.expectEqualStrings("admin:*", routeAction(.DELETE, "/_admin/v1/buckets/photos/directories"));
    try std.testing.expectEqualStrings("admin:*", routeAction(.POST, "/_admin/v1/buckets/photos/directories/cleanup"));
}

test "event subscription configuration requires management authority" {
    try std.testing.expectEqualStrings("admin:*", routeAction(.GET, "/_admin/v1/buckets/photos/event-subscriptions"));
    try std.testing.expectEqualStrings("admin:*", routeAction(.PUT, "/_admin/v1/buckets/photos/event-subscriptions"));
}

test "event destination configuration requires management authority" {
    try std.testing.expectEqualStrings("admin:*", routeAction(.GET, "/_admin/v1/event-destinations"));
    try std.testing.expectEqualStrings("admin:*", routeAction(.POST, "/_admin/v1/event-destinations"));
    try std.testing.expectEqualStrings("admin:*", routeAction(.PUT, "/_admin/v1/event-destinations/TEST"));
    try std.testing.expectEqualStrings("admin:*", routeAction(.DELETE, "/_admin/v1/event-destinations/TEST"));
}

test "diagnostics capabilities match resource and do not grant administration" {
    const document = @embedFile("../application/policies/diagnostics.json");
    const principal: Principal = .{ .id = "diagnostic", .username = "diagnostic", .expires_at = 0, .documents = &.{document} };
    const caps = principal.capabilities(std.testing.allocator);
    try std.testing.expect(caps.server_info and caps.console_log and caps.sts);
    try std.testing.expect(!caps.admin and !caps.s3 and !caps.kms);
    try std.testing.expectEqualStrings("admin:ConsoleLog", routeAction(.GET, "/_admin/v1/settings/logs/query"));
    try std.testing.expectEqualStrings("admin:*", routeAction(.PUT, "/_admin/v1/settings/logs"));
    const deny = "{\"Statement\":[{\"Effect\":\"Deny\",\"Action\":\"admin:ConsoleLog\",\"Resource\":\"*\"}]}";
    const denied: Principal = .{ .id = "diagnostic", .username = "diagnostic", .expires_at = 0, .documents = &.{ document, deny } };
    try std.testing.expect(!denied.capabilities(std.testing.allocator).console_log);
    try std.testing.expect(denied.capabilities(std.testing.allocator).server_info);
}

pub fn routeResource(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.mem.eql(u8, path, "/_admin/v1/system") or std.mem.eql(u8, path, "/_admin/v1/health") or std.mem.eql(u8, path, "/_admin/v1/metrics") or std.mem.eql(u8, path, "/_admin/v1/settings/logs") or std.mem.eql(u8, path, "/_admin/v1/settings/logs/query") or std.mem.eql(u8, path, "/_admin/v1/settings/logs/download")) return "arn:aws:s3:::*";
    const prefix = "/_admin/v1/buckets/";
    if (std.mem.startsWith(u8, path, prefix)) {
        const rest = path[prefix.len..];
        const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        return std.fmt.allocPrint(a, "arn:aws:s3:::{s}", .{rest[0..end]});
    }
    if (std.mem.startsWith(u8, path, "/_admin/v1/users/")) {
        const rest = path["/_admin/v1/users/".len..];
        const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        return std.fmt.allocPrint(a, "arn:aws:iam::000000000000:user/{s}", .{rest[0..end]});
    }
    if (std.mem.startsWith(u8, path, "/_admin/v1/roles/")) {
        const rest = path["/_admin/v1/roles/".len..];
        const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        return std.fmt.allocPrint(a, "arn:aws:iam::000000000000:role/{s}", .{rest[0..end]});
    }
    return "arn:aws:s3:::*";
}

test "capability resources agree with routes and preserve scoped policy denies" {
    const a = std.testing.allocator;
    const cases = .{
        .{ "admin:ListUsers", "arn:aws:s3:::*", "admin" },
        .{ "s3:ListBucket", "arn:aws:s3:::photos", "s3" },
        .{ "s3:GetObject", "arn:aws:s3:::photos/public/*", "s3" },
        .{ "kms:DescribeKey", "arn:aws:kms:::key/customer-key", "kms_describe" },
        .{ "kms:Decrypt", "arn:aws:kms:::key/team-*", "kms" },
        .{ "sts:AssumeRole", "arn:aws:iam::000000000000:role/reader", "sts" },
    };
    inline for (cases) |case| {
        const allow = try std.fmt.allocPrint(a, "{{\"Statement\":{{\"Effect\":\"Allow\",\"Action\":\"{s}\",\"Resource\":\"{s}\"}}}}", .{ case[0], case[1] });
        defer a.free(allow);
        const principal: Principal = .{ .id = "test", .username = "test", .expires_at = 0, .documents = &.{allow} };
        try std.testing.expect(@field(principal.capabilities(a), case[2]));
        const deny = try std.fmt.allocPrint(a, "{{\"Statement\":{{\"Effect\":\"Deny\",\"Action\":\"{s}\",\"Resource\":\"{s}\"}}}}", .{ case[0], case[1] });
        defer a.free(deny);
        const blocked: Principal = .{ .id = "test", .username = "test", .expires_at = 0, .documents = &.{ allow, deny } };
        try std.testing.expect(!@field(blocked.capabilities(a), case[2]));
    }
    const resource = try routeResource(a, "/_admin/v1/users");
    try std.testing.expectEqualStrings(management_resource, resource);
}

fn credentialPolicyNames(a: std.mem.Allocator, app: *Application, owner: []const u8, now: i64) ![]const []const u8 {
    const root = app.data_root orelse return &.{};
    const io = app.io orelse return &.{};
    app.policy_mutex.lockUncancelable(io);
    defer app.policy_mutex.unlock(io);
    if (std.mem.startsWith(u8, owner, "user:")) {
        const snapshot = try identities.load(root, io, a);
        const index = identities.find(snapshot.value.users, owner[5..]) orelse return &.{};
        return identities.policyNamesForUser(a, snapshot.value.users[index], snapshot.value);
    }
    if (std.mem.startsWith(u8, owner, "role:")) {
        const store = @import("../application/role_store.zig");
        const suffix = owner[5..];
        const end = std.mem.indexOfScalar(u8, suffix, ':') orelse return &.{};
        const snapshot = try store.load(root, io, a);
        const role = store.findRole(snapshot.value, suffix[0..end]) orelse return &.{};
        return role.policies;
    }
    if (std.mem.startsWith(u8, owner, "oidc:")) {
        const identity = (try @import("../application/oidc_auth.zig").resolve(a, root, io, app.master_key.?.bytes, owner[5..], now)) orelse return &.{};
        return identity.policies;
    }
    return &.{};
}
