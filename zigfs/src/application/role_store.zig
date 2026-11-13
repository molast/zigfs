const std = @import("std");
const durable = @import("../metadata/durable.zig");
const iam = @import("../auth/iam_policy.zig");
const identities = @import("identity_store.zig");

pub const Organization = struct {
    id: []const u8,
    name: []const u8,
    enabled: bool = true,
    paths: []const []const u8 = &.{},
    members: []const []const u8 = &.{},
};
pub const Account = struct {
    id: []const u8,
    name: []const u8 = "default",
    enabled: bool = true,
    updated_at: i64 = 0,
};
pub const Role = struct {
    id: []const u8,
    name: []const u8,
    organization_id: []const u8 = "",
    enabled: bool = true,
    max_session_seconds: u64 = 3600,
    trust_policy: []const u8 = "{\"Version\":\"2012-10-17\",\"Statement\":[]}",
    policies: []const []const u8 = &.{},
    permissions_boundary: ?[]const u8 = null,
    tags_json: ?[]const u8 = null,
};
pub const Session = struct {
    access_key: []const u8,
    role_id: []const u8,
    session_name: []const u8,
    subject_id: []const u8,
    expires_at: i64,
    revoked: bool = false,
    source_identity: ?[]const u8 = null,
    external_id: ?[]const u8 = null,
    session_tags_json: ?[]const u8 = null,
    transitive_tag_keys_json: ?[]const u8 = null,
    parent_session_id: ?[]const u8 = null,
    session_policy: ?[]const u8 = null,
};
pub const Snapshot = struct {
    version: u32 = 1,
    accounts: []const Account = &.{},
    organizations: []const Organization = &.{},
    roles: []const Role = &.{},
    sessions: []const Session = &.{},
};
pub const path = ".zigfs/system/roles.json";
pub const default_account_id = "000000000000";

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    return true;
}
pub fn validSessionAttribute(value: []const u8, max_len: usize) bool {
    return value.len <= max_len and std.unicode.utf8ValidateSlice(value);
}
pub fn validTagsJson(value: ?[]const u8) bool {
    const raw = value orelse return true;
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, raw, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| if (entry.value_ptr.* != .string or entry.key_ptr.*.len == 0 or entry.key_ptr.*.len > 128 or entry.value_ptr.*.string.len > 256) return false;
    return true;
}
pub fn findRole(snapshot: Snapshot, id: []const u8) ?Role {
    for (snapshot.roles) |role| if (std.mem.eql(u8, role.id, id)) return role;
    return null;
}
pub fn findOrganization(snapshot: Snapshot, id: []const u8) ?Organization {
    for (snapshot.organizations) |org| if (std.mem.eql(u8, org.id, id)) return org;
    return null;
}
pub fn findSession(snapshot: Snapshot, access_key: []const u8) ?Session {
    for (snapshot.sessions) |item| if (std.mem.eql(u8, item.access_key, access_key)) return item;
    return null;
}
pub fn hasActiveSession(snapshot: Snapshot, role_id: []const u8, now: i64) bool {
    for (snapshot.sessions) |item| if (std.mem.eql(u8, item.role_id, role_id) and !item.revoked and item.expires_at > now) return true;
    return false;
}
pub fn organizationInUse(snapshot: Snapshot, id: []const u8) bool {
    for (snapshot.roles) |role| if (std.mem.eql(u8, role.organization_id, id)) return true;
    return false;
}
pub fn policyInUse(snapshot: Snapshot, name: []const u8) bool {
    for (snapshot.roles) |role| {
        for (role.policies) |policy| if (std.mem.eql(u8, policy, name)) return true;
        if (role.permissions_boundary) |boundary| if (std.mem.eql(u8, boundary, name)) return true;
    }
    return false;
}
pub fn validate(a: std.mem.Allocator, role: Role, snapshot: Snapshot, policies: []const @import("policy_store.zig").Policy) !void {
    if (!validName(role.name) or role.max_session_seconds < 900 or role.max_session_seconds > 43200 or !validTagsJson(role.tags_json)) return error.InvalidRole;
    if (role.organization_id.len > 0) {
        var found = false;
        for (snapshot.organizations) |org| {
            if (std.mem.eql(u8, org.id, role.organization_id)) found = true;
        }
        if (!found) return error.OrganizationNotFound;
    }
    iam.validateDocument(a, role.trust_policy, .trust) catch return error.InvalidTrustPolicy;
    for (role.policies) |name| {
        var found = false;
        for (policies) |policy| {
            if (std.mem.eql(u8, policy.name, name)) found = true;
        }
        if (!found) return error.PolicyNotFound;
    }
    if (role.permissions_boundary) |boundary| {
        var found = false;
        for (policies) |policy| {
            if (std.mem.eql(u8, policy.name, boundary)) found = true;
        }
        if (!found) return error.PolicyNotFound;
    }
}
pub fn load(root: std.Io.Dir, io: std.Io, a: std.mem.Allocator) !std.json.Parsed(Snapshot) {
    const bytes = root.readFileAlloc(io, path, a, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return std.json.parseFromSlice(Snapshot, a, "{\"accounts\":[{\"id\":\"000000000000\",\"name\":\"default\",\"enabled\":true,\"updated_at\":0}]}", .{ .allocate = .alloc_always }),
        else => return err,
    };
    defer a.free(bytes);
    var parsed = try std.json.parseFromSlice(Snapshot, a, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (parsed.value.version != 1) return error.InvalidRoleVersion;
    const arena = parsed.arena.allocator();
    var migrated = false;
    if (parsed.value.accounts.len == 0) {
        parsed.value.accounts = &.{.{ .id = default_account_id }};
        migrated = true;
    }
    const organizations = try arena.dupe(Organization, parsed.value.organizations);
    for (organizations) |*organization| if (organization.id.len == 0) {
        organization.id = try identities.newId(arena, io);
        migrated = true;
    };
    const roles = try arena.dupe(Role, parsed.value.roles);
    for (roles) |*role| if (role.id.len == 0) {
        role.id = try identities.newId(arena, io);
        migrated = true;
    };
    parsed.value.organizations = organizations;
    parsed.value.roles = roles;
    for (parsed.value.organizations, 0..) |left, i| {
        if (!validName(left.name)) return error.InvalidRoleReference;
        for (parsed.value.organizations[i + 1 ..]) |right| if (std.mem.eql(u8, left.id, right.id) or std.mem.eql(u8, left.name, right.name)) return error.DuplicateRoleReference;
    }
    for (parsed.value.accounts, 0..) |left, i| {
        if (!validName(left.id) or left.id.len != 12) return error.InvalidRoleReference;
        for (parsed.value.accounts[i + 1 ..]) |right| if (std.mem.eql(u8, left.id, right.id)) return error.DuplicateRoleReference;
    }
    for (parsed.value.roles, 0..) |left, i| {
        if (!validName(left.name)) return error.InvalidRoleReference;
        if (left.organization_id.len > 0 and findOrganization(parsed.value, left.organization_id) == null) return error.InvalidRoleReference;
        for (parsed.value.roles[i + 1 ..]) |right| if (std.mem.eql(u8, left.id, right.id) or std.mem.eql(u8, left.name, right.name)) return error.DuplicateRoleReference;
    }
    for (parsed.value.sessions, 0..) |left, i| {
        // Older role deletion left revoked sessions behind. Keep those records
        // readable for cleanup; an unrevoked session must still reference a role.
        if ((findRole(parsed.value, left.role_id) == null and !left.revoked) or !validName(left.session_name) or left.session_name.len > 64) return error.InvalidRoleReference;
        if (left.access_key.len == 0 or left.subject_id.len == 0) return error.InvalidRoleReference;
        for (parsed.value.sessions[i + 1 ..]) |right| if (std.mem.eql(u8, left.access_key, right.access_key)) return error.DuplicateRoleReference;
    }
    if (migrated) try save(root, io, a, parsed.value);
    return parsed;
}
pub fn save(root: std.Io.Dir, io: std.Io, a: std.mem.Allocator, snapshot: Snapshot) !void {
    if (snapshot.accounts.len > 16 or snapshot.organizations.len > 10000 or snapshot.roles.len > 10000 or snapshot.sessions.len > 100000) return error.RoleLimit;
    const bytes = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer a.free(bytes);
    try root.createDirPath(io, ".zigfs/system");
    var atomic = try root.createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
    try durable.syncParent(root, io, path);
}
pub fn canAssume(a: std.mem.Allocator, role: Role, principal: iam.Context, action: []const u8, resource: []const u8) !bool {
    _ = try std.json.parseFromSlice(std.json.Value, a, role.trust_policy, .{});
    return iam.allowsWithContext(a, &[_][]const u8{role.trust_policy}, action, resource, .{ .entries = principal.entries, .kind = .trust, .principal_bindings = principal.principal_bindings });
}

test "role validation binds trust, organization, policies and session limits" {
    const a = std.testing.allocator;
    const org = Organization{ .id = "org-1", .name = "Main" };
    const policy = @import("policy_store.zig").defaults[5];
    const role = Role{ .id = "role-1", .name = "reader", .organization_id = "org-1", .policies = &.{policy.name}, .trust_policy = "{\"Version\":\"2012-10-17\",\"Statement\":{\"Effect\":\"Allow\",\"Principal\":\"*\",\"Action\":\"sts:AssumeRole\",\"Resource\":\"*\"}}" };
    try validate(a, role, .{ .organizations = &.{org} }, &.{policy});
    try std.testing.expectError(error.OrganizationNotFound, validate(a, role, .{}, &.{policy}));
}

test "role sessions report active state and references" {
    const snapshot = Snapshot{
        .organizations = &.{.{ .id = "org-1", .name = "main" }},
        .roles = &.{.{ .id = "role-1", .name = "reader", .organization_id = "org-1" }},
        .sessions = &.{.{ .access_key = "AKIA1234567890123456", .role_id = "role-1", .session_name = "test", .subject_id = "role-1:test", .expires_at = 100 }},
    };
    try std.testing.expect(findRole(snapshot, "role-1") != null);
    try std.testing.expect(findSession(snapshot, "AKIA1234567890123456") != null);
    try std.testing.expect(hasActiveSession(snapshot, "role-1", 99));
    try std.testing.expect(organizationInUse(snapshot, "org-1"));
}

test "role store rejects duplicate IDs, orphan sessions, and corrupt JSON" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, ".zigfs/system");
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "{\"accounts\":[{\"id\":\"000000000000\"},{\"id\":\"000000000000\"}]}" });
    try std.testing.expectError(error.DuplicateRoleReference, load(tmp.dir, io, a));
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "{\"accounts\":[{\"id\":\"000000000000\"}],\"roles\":[],\"sessions\":[{\"access_key\":\"AKIA\",\"role_id\":\"missing\",\"session_name\":\"s\",\"subject_id\":\"x\",\"expires_at\":1}]}" });
    try std.testing.expectError(error.InvalidRoleReference, load(tmp.dir, io, a));
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "not json" });
    try std.testing.expectError(error.SyntaxError, load(tmp.dir, io, a));
}

test "revoked legacy sessions remain readable after their role was deleted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, ".zigfs/system");
    try save(tmp.dir, io, a, .{ .sessions = &.{.{ .access_key = "AKIA1234567890123456", .role_id = "deleted-role", .session_name = "console", .subject_id = "deleted-role:console", .expires_at = 1, .revoked = true }} });
    const loaded = try load(tmp.dir, io, a);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.value.sessions.len);
    try std.testing.expect(loaded.value.sessions[0].revoked);
    try std.testing.expect(findRole(loaded.value, "deleted-role") == null);
}
