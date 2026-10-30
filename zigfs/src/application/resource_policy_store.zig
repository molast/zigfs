const std = @import("std");
const durable = @import("../metadata/durable.zig");
const identities = @import("identity_store.zig");
const roles = @import("role_store.zig");
const iam = @import("../auth/iam_policy.zig");
pub const account_id = "000000000000";
pub const Record = struct {
    version: u32 = 1,
    deleted: bool = false,
    document: []const u8,
    bindings: []const iam.PrincipalBinding = &.{},
};

// Files are keyed by immutable bucket IDs, never reusable bucket names.
fn path(a: std.mem.Allocator, bucket_id: [16]u8) ![]u8 {
    return std.fmt.allocPrint(a, ".zigfs/system/bucket-policies/{s}.json", .{std.fmt.bytesToHex(bucket_id, .lower)});
}
pub fn load(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, bucket_id: [16]u8) !?std.json.Parsed(Record) {
    const filename = try path(a, bucket_id);
    defer a.free(filename);
    const bytes = root.readFileAlloc(io, filename, a, .limited(512 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer a.free(bytes);
    var parsed = try std.json.parseFromSlice(Record, a, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (parsed.value.version != 1) return error.InvalidPolicyVersion;
    return parsed;
}
pub fn save(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, bucket_id: [16]u8, record: Record) !void {
    const filename = try path(a, bucket_id);
    defer a.free(filename);
    const bytes = try std.json.Stringify.valueAlloc(a, record, .{});
    defer a.free(bytes);
    try root.createDirPath(io, ".zigfs/system/bucket-policies");
    var atomic = try root.createFileAtomic(io, filename, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
    try durable.syncParent(root, io, filename);
}
pub fn remove(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, bucket_id: [16]u8) !void {
    // An empty statement set is an atomic, durable tombstone. It cannot race a
    // concurrent replace into resurrecting the previous grant.
    try save(a, root, io, bucket_id, .{ .deleted = true, .document = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" });
}

// Uses the caller's arena and policy_mutex, including principal resolution.
pub fn prepare(a: std.mem.Allocator, document: []const u8, bucket_name: []const u8, snapshot: identities.Snapshot) !Record {
    return prepareWithRoles(a, document, bucket_name, snapshot, .{});
}
pub fn prepareWithRoles(a: std.mem.Allocator, document: []const u8, bucket_name: []const u8, snapshot: identities.Snapshot, role_snapshot: roles.Snapshot) !Record {
    try iam.validateDocument(a, document, .resource);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, document, .{ .duplicate_field_behavior = .@"error" });
    defer parsed.deinit();
    const statements = parsed.value.object.get("Statement") orelse return error.InvalidPolicy;
    var bindings: std.ArrayList(iam.PrincipalBinding) = .empty;
    if (statements == .array) {
        for (statements.array.items) |statement| try validate(a, statement, bucket_name, snapshot, role_snapshot, &bindings);
    } else try validate(a, statements, bucket_name, snapshot, role_snapshot, &bindings);
    return .{ .document = try a.dupe(u8, document), .bindings = try bindings.toOwnedSlice(a) };
}
fn validate(a: std.mem.Allocator, statement: std.json.Value, bucket_name: []const u8, snapshot: identities.Snapshot, role_snapshot: roles.Snapshot, bindings: *std.ArrayList(iam.PrincipalBinding)) !void {
    try iam.validateStatementKind(statement, .resource);
    const resource = statement.object.get("Resource") orelse statement.object.get("NotResource") orelse return error.InvalidPolicy;
    const prefix = try std.fmt.allocPrint(a, "arn:aws:s3:::{s}", .{bucket_name});
    try validateResource(resource, prefix);
    const principal = statement.object.get("Principal") orelse statement.object.get("NotPrincipal").?;
    if (principal == .object) try bind(a, principal.object.get("AWS").?, snapshot, role_snapshot, bindings);
}
fn validateResource(value: std.json.Value, prefix: []const u8) !void {
    if (value == .array) {
        for (value.array.items) |item| try validateResource(item, prefix);
        return;
    }
    if (value != .string) return error.InvalidPolicy;
    if (std.mem.eql(u8, value.string, prefix)) return;
    if (std.mem.startsWith(u8, value.string, prefix) and value.string.len > prefix.len and value.string[prefix.len] == '/') return;
    return error.InvalidPolicy;
}
fn bind(a: std.mem.Allocator, value: std.json.Value, snapshot: identities.Snapshot, role_snapshot: roles.Snapshot, bindings: *std.ArrayList(iam.PrincipalBinding)) !void {
    if (value == .array) {
        for (value.array.items) |item| try bind(a, item, snapshot, role_snapshot, bindings);
        return;
    }
    const arn = value.string;
    if (std.mem.eql(u8, arn, "*") or std.mem.eql(u8, arn, account_id) or std.mem.eql(u8, arn, "arn:aws:iam::" ++ account_id ++ ":root")) return;
    const prefix = "arn:aws:iam::" ++ account_id ++ ":user/";
    if (std.mem.startsWith(u8, arn, prefix)) {
        const index = identities.find(snapshot.users, arn[prefix.len..]) orelse return error.InvalidPrincipal;
        return bindings.append(a, .{ .arn = try a.dupe(u8, arn), .subject_id = try a.dupe(u8, snapshot.users[index].id) });
    }
    const role_prefix = "arn:aws:iam::" ++ account_id ++ ":role/";
    if (std.mem.startsWith(u8, arn, role_prefix)) {
        const role_id = arn[role_prefix.len..];
        const role = roles.findRole(role_snapshot, role_id) orelse return error.InvalidPrincipal;
        return bindings.append(a, .{ .arn = try a.dupe(u8, arn), .subject_id = try a.dupe(u8, role.id) });
    }
    return error.InvalidPrincipal;
}

test "resource policy validates bucket resources and local principals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const user = identities.User{ .id = "0123456789abcdef0123456789abcdef", .name = "alice" };
    const snapshot = identities.Snapshot{ .users = &.{user} };
    const document = "{\"Version\":\"2012-10-17\",\"Statement\":{\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws:iam::000000000000:user/alice\"},\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::bucket/*\"}}";
    const record = try prepare(a, document, "bucket", snapshot);
    try std.testing.expectEqual(@as(usize, 1), record.bindings.len);
    try std.testing.expectError(error.InvalidPolicy, prepare(a, document, "other", snapshot));
    const wildcard = "{\"Version\":\"2012-10-17\",\"Statement\":{\"Effect\":\"Allow\",\"Principal\":\"*\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::bucket/*\"}}";
    _ = try prepare(a, wildcard, "bucket", snapshot);
}
