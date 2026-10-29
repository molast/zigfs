const std = @import("std");
const durable = @import("../metadata/durable.zig");
pub const Policy = struct { name: []const u8, document: []const u8 };
pub const path = ".zigfs/system/policies.json";
pub const defaults = [_]Policy{ .{ .name = "consoleAdmin", .document = @embedFile("policies/consoleAdmin.json") }, .{ .name = "diagnostics", .document = @embedFile("policies/diagnostics.json") }, .{ .name = "KMSAuditor", .document = @embedFile("policies/KMSAuditor.json") }, .{ .name = "KMSKeyAdministrator", .document = @embedFile("policies/KMSKeyAdministrator.json") }, .{ .name = "KMSKeyUser", .document = @embedFile("policies/KMSKeyUser.json") }, .{ .name = "readonly", .document = @embedFile("policies/readonly.json") }, .{ .name = "readwrite", .document = @embedFile("policies/readwrite.json") }, .{ .name = "writeonly", .document = @embedFile("policies/writeonly.json") } };

pub fn validate(allocator: std.mem.Allocator, policy: Policy) !void {
    if (policy.name.len == 0 or policy.name.len > 128) return error.InvalidPolicy;
    for (policy.name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return error.InvalidPolicy;
    }
    if (policy.document.len > 256 * 1024) return error.InvalidPolicy;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, policy.document, .{}) catch return error.InvalidPolicy;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPolicy;
    const version = parsed.value.object.get("Version") orelse return error.InvalidPolicy;
    if (version != .string or !std.mem.eql(u8, version.string, "2012-10-17")) return error.InvalidPolicy;
    const statements = parsed.value.object.get("Statement") orelse return error.InvalidPolicy;
    if (statements == .array) {
        for (statements.array.items) |statement| try @import("../auth/iam_policy.zig").validateStatement(statement);
    } else if (statements == .object) {
        try @import("../auth/iam_policy.zig").validateStatement(statements);
    } else return error.InvalidPolicy;
}

pub fn save(root: std.Io.Dir, io: std.Io, allocator: std.mem.Allocator, policies: []const Policy) !void {
    const bytes = try std.json.Stringify.valueAlloc(allocator, policies, .{});
    defer allocator.free(bytes);
    if (bytes.len > 16 * 1024 * 1024) return error.PolicyLimit;
    try root.createDirPath(io, ".zigfs/system");
    var atomic = try root.createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
    try durable.syncParent(root, io, path);
}
pub fn load(root: std.Io.Dir, io: std.Io, allocator: std.mem.Allocator) !std.json.Parsed([]Policy) {
    const bytes = root.readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            try save(root, io, allocator, &defaults);
            return load(root, io, allocator);
        },
        else => return err,
    };
    defer allocator.free(bytes);
    return std.json.parseFromSlice([]Policy, allocator, bytes, .{ .allocate = .alloc_always });
}
test "default policies persist edits and deletions across reloads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const initial = try load(tmp.dir, io, a);
    defer initial.deinit();
    try std.testing.expectEqual(@as(usize, 8), initial.value.len);
    for (initial.value) |policy| try validate(a, policy);
    const changed = Policy{ .name = "consoleAdmin", .document = defaults[7].document };
    try save(tmp.dir, io, a, &.{changed});
    const reloaded = try load(tmp.dir, io, a);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), reloaded.value.len);
    try std.testing.expectEqualStrings("consoleAdmin", reloaded.value[0].name);
    try std.testing.expectEqualStrings(defaults[7].document, reloaded.value[0].document);
    try save(tmp.dir, io, a, &.{});
    const empty = try load(tmp.dir, io, a);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.value.len);
    try std.testing.expectError(error.InvalidPolicy, validate(a, .{ .name = "../bad", .document = "{}" }));
    try std.testing.expectError(error.InvalidPolicy, validate(a, .{ .name = "bad", .document = "null" }));
}

test "corrupt collection is not replaced by defaults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".zigfs/system");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = "not json" });
    if (load(tmp.dir, std.testing.io, std.testing.allocator)) |loaded| {
        loaded.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(100));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("not json", bytes);
}
