const std = @import("std");
const durable = @import("../metadata/durable.zig");
const policy_store = @import("policy_store.zig");

pub const User = struct {
    id: []const u8 = "",
    auth_version: u64 = 1,
    name: []const u8,
    description: []const u8 = "",
    enabled: bool = true,
    policies: []const []const u8 = &.{},
    tags_json: ?[]const u8 = null,
    updated_at: i64 = 0,
    password_hash: []const u8 = "",
};
pub const Group = struct {
    id: []const u8 = "",
    name: []const u8,
    description: []const u8 = "",
    enabled: bool = true,
    policies: []const []const u8 = &.{},
    tags_json: ?[]const u8 = null,
    members: []const []const u8 = &.{},
    updated_at: i64 = 0,
};
pub const UserInput = struct {
    id: []const u8 = "", // Read-only public fields are accepted, never trusted.
    auth_version: u64 = 0,
    updated_at: i64 = 0,
    name: []const u8,
    description: []const u8 = "",
    enabled: bool = true,
    policies: []const []const u8 = &.{},
    password: ?[]const u8 = null,
    groups: ?[]const []const u8 = null,
    tags_json: ?[]const u8 = null,
};
pub const UserPatch = struct {
    expected_updated_at: ?i64 = null,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    enabled: ?bool = null,
    policies: ?[]const []const u8 = null,
    password: ?[]const u8 = null,
    groups: ?[]const []const u8 = null,
    tags_json: ?[]const u8 = null,
};
pub const GroupPatch = struct {
    expected_updated_at: ?i64 = null,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    enabled: ?bool = null,
    policies: ?[]const []const u8 = null,
    members: ?[]const []const u8 = null,
    tags_json: ?[]const u8 = null,
};
pub const Revision = struct { updated_at: i64 };
pub const PublicUser = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    enabled: bool,
    policies: []const []const u8,
    groups: []const []const u8,
    tags_json: ?[]const u8,
    updated_at: i64,
};
pub fn publicUser(a: std.mem.Allocator, user: User, groups: []const Group) !PublicUser {
    var names: std.ArrayList([]const u8) = .empty;
    for (groups) |group| if (contains(group.members, user.name)) try names.append(a, group.name);
    return .{ .id = user.id, .name = user.name, .description = user.description, .enabled = user.enabled, .policies = user.policies, .groups = try names.toOwnedSlice(a), .tags_json = user.tags_json, .updated_at = user.updated_at };
}
pub fn prepareUser(a: std.mem.Allocator, io: std.Io, value: UserInput, old: ?User, now: i64) !User {
    if (old == null and value.password == null) return error.InvalidPassword;
    var hash: []const u8 = if (old) |user| user.password_hash else "";
    if (value.password) |password| {
        if (password.len < 8 or password.len > 1024) return error.InvalidPassword;
        var buffer: [256]u8 = undefined;
        const encoded = try std.crypto.pwhash.argon2.strHash(password, .{ .allocator = a, .params = .interactive_2id }, &buffer, io);
        hash = try a.dupe(u8, encoded);
    }
    return .{ .id = if (old) |user| user.id else try newId(a, io), .auth_version = if (old) |user| user.auth_version + @as(u64, if (value.password != null or value.enabled != user.enabled) 1 else 0) else 1, .name = value.name, .description = value.description, .enabled = value.enabled, .policies = value.policies, .tags_json = value.tags_json orelse if (old) |user| user.tags_json else null, .updated_at = now, .password_hash = hash };
}
pub fn assignGroups(a: std.mem.Allocator, snapshot: *Snapshot, name: []const u8, names: []const []const u8, now: i64) !void {
    try validateNames(names);
    for (names) |group| if (find(snapshot.groups, group) == null) return error.GroupNotFound;
    const groups = try a.dupe(Group, snapshot.groups);
    for (groups) |*group| {
        const was_member = contains(group.members, name);
        const is_member = contains(names, group.name);
        if (was_member == is_member) continue;
        var members: std.ArrayList([]const u8) = .empty;
        for (group.members) |member| if (!std.mem.eql(u8, member, name)) try members.append(a, member);
        if (is_member) try members.append(a, name);
        if (members.items.len > 1024) return error.InvalidIdentity;
        group.members = try members.toOwnedSlice(a);
        group.updated_at = now;
    }
    snapshot.groups = groups;
}
pub const Snapshot = struct {
    schema_version: u32 = 1,
    users: []const User = &.{},
    groups: []const Group = &.{},
};
pub const path = ".zigfs/system/identities.json";

pub fn newId(a: std.mem.Allocator, io: std.Io) ![]const u8 {
    const uuid = try @import("../common/id.zig").randomV4(io);
    return a.dupe(u8, &std.fmt.bytesToHex(uuid, .lower));
}

// Caller holds policy_mutex; return owned documents for an immutable request snapshot.
pub fn documentsForUser(a: std.mem.Allocator, user: User, snapshot: Snapshot, policies: []const policy_store.Policy) ![][]u8 {
    if (!user.enabled) return error.UserDisabled;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(a);
    try names.appendSlice(a, user.policies);
    for (snapshot.groups) |group| if (group.enabled and contains(group.members, user.name)) {
        for (group.policies) |name| if (!contains(names.items, name)) try names.append(a, name);
    };
    var docs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (docs.items) |doc| a.free(doc);
        docs.deinit(a);
    }
    for (names.items) |name| {
        const index = find(policies, name) orelse return error.PolicyNotFound;
        const doc = try a.dupe(u8, policies[index].document);
        errdefer a.free(doc);
        try docs.append(a, doc);
    }
    return docs.toOwnedSlice(a);
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    return true;
}
pub fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}
pub fn find(items: anytype, name: []const u8) ?usize {
    for (items, 0..) |item, i| if (std.mem.eql(u8, item.name, name)) return i;
    return null;
}
fn validateNames(names: []const []const u8) !void {
    if (names.len > 1024) return error.InvalidIdentity;
    for (names, 0..) |name, i| {
        if (!validName(name) or contains(names[0..i], name)) return error.InvalidIdentity;
    }
}
pub fn validate(value: anytype, snapshot: Snapshot, policies: []const policy_store.Policy) error{ InvalidIdentity, PolicyNotFound, UserNotFound }!void {
    if (!validName(value.name) or value.description.len > 1024 or !std.unicode.utf8ValidateSlice(value.description)) return error.InvalidIdentity;
    try validateNames(value.policies);
    for (value.policies) |name| if (find(policies, name) == null) return error.PolicyNotFound;
    if (@TypeOf(value) == Group) {
        try validateNames(value.members);
        for (value.members) |name| if (find(snapshot.users, name) == null) return error.UserNotFound;
    }
}
pub fn policyInUse(snapshot: Snapshot, name: []const u8) bool {
    for (snapshot.users) |user| if (contains(user.policies, name)) return true;
    for (snapshot.groups) |group| if (contains(group.policies, name)) return true;
    return false;
}

// The caller holds Application.policy_mutex for both stores, including reference checks.
pub fn save(root: std.Io.Dir, io: std.Io, allocator: std.mem.Allocator, snapshot: Snapshot) !void {
    if (snapshot.users.len > 10000 or snapshot.groups.len > 10000) return error.IdentityLimit;
    const bytes = try std.json.Stringify.valueAlloc(allocator, snapshot, .{});
    defer allocator.free(bytes);
    if (bytes.len > 16 * 1024 * 1024) return error.IdentityLimit;
    try root.createDirPath(io, ".zigfs/system");
    var atomic = try root.createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
    try durable.syncParent(root, io, path);
}
pub fn load(root: std.Io.Dir, io: std.Io, allocator: std.mem.Allocator) !std.json.Parsed(Snapshot) {
    const bytes = root.readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return std.json.parseFromSlice(Snapshot, allocator, "{}", .{ .allocate = .alloc_always }),
        else => return err,
    };
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(Snapshot, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (parsed.value.schema_version != 1) return error.InvalidIdentityVersion;
    const a = parsed.arena.allocator();
    var migrated = false;
    const users = try a.dupe(User, parsed.value.users);
    for (users) |*user| if (user.id.len == 0) {
        user.id = try newId(a, io);
        migrated = true;
    };
    const groups = try a.dupe(Group, parsed.value.groups);
    for (groups) |*group| if (group.id.len == 0) {
        group.id = try newId(a, io);
        migrated = true;
    };
    parsed.value.users = users;
    parsed.value.groups = groups;
    for (parsed.value.users, 0..) |left, i| {
        if (!validName(left.name) or left.id.len == 0) return error.InvalidIdentityReference;
        for (parsed.value.users[i + 1 ..]) |right| if (std.mem.eql(u8, left.id, right.id) or std.mem.eql(u8, left.name, right.name)) return error.DuplicateIdentity;
    }
    for (parsed.value.groups, 0..) |left, i| {
        if (!validName(left.name) or left.id.len == 0) return error.InvalidIdentityReference;
        for (left.members) |member| if (find(parsed.value.users, member) == null) return error.OrphanGroupMember;
        for (parsed.value.groups[i + 1 ..]) |right| if (std.mem.eql(u8, left.id, right.id) or std.mem.eql(u8, left.name, right.name)) return error.DuplicateIdentity;
    }
    if (migrated) try save(root, io, allocator, parsed.value);
    return parsed;
}

// Uses the request arena; membership removal and user deletion are one atomic snapshot.
pub fn withoutUser(allocator: std.mem.Allocator, snapshot: Snapshot, name: []const u8) !Snapshot {
    var users: std.ArrayList(User) = .empty;
    for (snapshot.users) |user| if (!std.mem.eql(u8, user.name, name)) try users.append(allocator, user);
    const groups = try allocator.dupe(Group, snapshot.groups);
    for (groups) |*group| {
        var members: std.ArrayList([]const u8) = .empty;
        for (group.members) |member| if (!std.mem.eql(u8, member, name)) try members.append(allocator, member);
        group.members = try members.toOwnedSlice(allocator);
    }
    return .{ .schema_version = snapshot.schema_version, .users = try users.toOwnedSlice(allocator), .groups = groups };
}

test "identities persist membership and policy references with atomic user cleanup" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const empty = try load(tmp.dir, std.testing.io, a);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.value.users.len);
    const user = User{ .name = "alice", .policies = &.{"readonly"} };
    const group = Group{ .name = "team", .members = &.{"alice"}, .policies = &.{"readwrite"} };
    const snapshot = Snapshot{ .users = &.{user}, .groups = &.{group} };
    try validate(user, snapshot, &policy_store.defaults);
    try validate(group, snapshot, &policy_store.defaults);
    try save(tmp.dir, std.testing.io, a, snapshot);
    const loaded = try load(tmp.dir, std.testing.io, a);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("alice", loaded.value.groups[0].members[0]);
    try std.testing.expect(policyInUse(loaded.value, "readonly"));
    try std.testing.expect(policyInUse(loaded.value, "readwrite"));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const deleted = try withoutUser(arena.allocator(), loaded.value, "alice");
    try save(tmp.dir, std.testing.io, a, deleted);
    const reloaded = try load(tmp.dir, std.testing.io, a);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), reloaded.value.users.len);
    try std.testing.expectEqual(@as(usize, 0), reloaded.value.groups[0].members.len);
    try std.testing.expect(!policyInUse(reloaded.value, "readonly"));
    try std.testing.expectError(error.InvalidIdentity, validate(User{ .name = "../bad" }, snapshot, &policy_store.defaults));
    try std.testing.expectError(error.InvalidIdentity, validate(User{ .name = "a", .policies = &.{ "readonly", "readonly" } }, snapshot, &policy_store.defaults));
    try std.testing.expectError(error.PolicyNotFound, validate(User{ .name = "a", .policies = &.{"missing"} }, snapshot, &policy_store.defaults));
    try std.testing.expectError(error.UserNotFound, validate(Group{ .name = "g", .members = &.{"missing"} }, snapshot, &policy_store.defaults));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = "broken" });
    try std.testing.expectError(error.SyntaxError, load(tmp.dir, std.testing.io, a));
}

test "user passwords stay hashed and user groups commit together" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try std.testing.expectError(error.InvalidPassword, prepareUser(a, io, .{ .name = "alice" }, null, 123));
    try std.testing.expectError(error.InvalidPassword, prepareUser(a, io, .{ .name = "alice", .password = "short" }, null, 123));
    const user = try prepareUser(a, io, .{ .name = "alice", .password = "test-password-only" }, null, 123);
    try std.testing.expect(std.mem.startsWith(u8, user.password_hash, "$argon2id$"));
    try std.crypto.pwhash.argon2.strVerify(user.password_hash, "test-password-only", .{ .allocator = a }, io);
    const updated = try prepareUser(a, io, .{ .name = "alice", .enabled = false }, user, 456);
    try std.testing.expectEqualStrings(user.password_hash, updated.password_hash);
    try std.testing.expectEqual(@as(i64, 456), updated.updated_at);
    var snapshot = Snapshot{ .users = &.{updated}, .groups = &.{.{ .name = "team" }} };
    try assignGroups(a, &snapshot, "alice", &.{"team"}, 456);
    try std.testing.expectEqualStrings("alice", snapshot.groups[0].members[0]);
    try std.testing.expectEqual(@as(i64, 456), snapshot.groups[0].updated_at);
    const public = try publicUser(a, updated, snapshot.groups);
    const encoded = try std.json.Stringify.valueAlloc(a, public, .{});
    try std.testing.expect(std.mem.indexOf(u8, encoded, "password") == null);
    try std.testing.expectEqualStrings("team", public.groups[0]);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try save(tmp.dir, io, a, snapshot);
    const bytes = try tmp.dir.readFileAlloc(io, path, a, .limited(10000));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "test-password-only") == null);
    const loaded = try load(tmp.dir, io, a);
    try std.testing.expectEqualStrings(user.password_hash, loaded.value.users[0].password_hash);
    try std.testing.expectError(error.GroupNotFound, assignGroups(a, &snapshot, "alice", &.{"missing"}, 789));
    try std.testing.expectEqualStrings("alice", snapshot.groups[0].members[0]);
    try assignGroups(a, &snapshot, "alice", &.{}, 789);
    try std.testing.expectEqual(@as(usize, 0), snapshot.groups[0].members.len);
}
