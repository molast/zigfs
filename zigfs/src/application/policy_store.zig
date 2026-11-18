const SystemStore = @import("../metadata/system_store.zig").SystemStore;
const std = @import("std");
pub const Policy = struct { name: []const u8, document: []const u8 };
pub const path = "system/policies.json";
pub const defaults = [_]Policy{
    .{ .name = "consoleAdmin", .document = @embedFile("builtin_policy_consoleAdmin") },
    .{ .name = "diagnostics", .document = @embedFile("builtin_policy_diagnostics") },
    .{ .name = "KMSAuditor", .document = @embedFile("builtin_policy_KMSAuditor") },
    .{ .name = "KMSKeyAdministrator", .document = @embedFile("builtin_policy_KMSKeyAdministrator") },
    .{ .name = "KMSKeyUser", .document = @embedFile("builtin_policy_KMSKeyUser") },
    .{ .name = "readonly", .document = @embedFile("builtin_policy_readonly") },
    .{ .name = "readwrite", .document = @embedFile("builtin_policy_readwrite") },
    .{ .name = "writeonly", .document = @embedFile("builtin_policy_writeonly") },
};

pub fn validate(allocator: std.mem.Allocator, policy: Policy) !void {
    if (policy.name.len == 0 or policy.name.len > 128) return error.InvalidPolicy;
    for (policy.name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return error.InvalidPolicy;
    }
    if (policy.document.len > 256 * 1024) return error.InvalidPolicy;
    try @import("../auth/iam_policy.zig").validateDocument(allocator, policy.document, .identity);
}

pub fn save(root: SystemStore, io: std.Io, allocator: std.mem.Allocator, policies: []const Policy) !void {
    _ = io;
    const bytes = try std.json.Stringify.valueAlloc(allocator, policies, .{});
    defer allocator.free(bytes);
    if (bytes.len > 16 * 1024 * 1024) return error.PolicyLimit;
    try root.put(allocator, path, bytes);
}
pub fn load(root: SystemStore, io: std.Io, allocator: std.mem.Allocator) !std.json.Parsed([]Policy) {
    const bytes = root.read(allocator, path, 16 * 1024 * 1024) catch |err| switch (err) {
        error.NotFound => {
            try save(root, io, allocator, &defaults);
            return load(root, io, allocator);
        },
        else => return err,
    };
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice([]Policy, allocator, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
    errdefer parsed.deinit();
    for (parsed.value) |policy| try validate(allocator, policy);
    return parsed;
}
test "default policies persist edits and deletions across reloads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repository = try @import("../metadata/engine_repository.zig").EngineRepository.open(std.testing.allocator, tmp.dir, std.testing.io);
    defer repository.deinit();
    const metadata = SystemStore{ .repository = repository.interface() };
    const a = std.testing.allocator;
    const io = std.testing.io;
    const initial = try load(metadata, io, a);
    defer initial.deinit();
    try std.testing.expectEqual(@as(usize, 8), initial.value.len);
    for (initial.value) |policy| try validate(a, policy);
    const changed = Policy{ .name = "consoleAdmin", .document = defaults[7].document };
    try save(metadata, io, a, &.{changed});
    const reloaded = try load(metadata, io, a);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), reloaded.value.len);
    try std.testing.expectEqualStrings("consoleAdmin", reloaded.value[0].name);
    try std.testing.expectEqualStrings(defaults[7].document, reloaded.value[0].document);
    try save(metadata, io, a, &.{});
    const empty = try load(metadata, io, a);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.value.len);
    try std.testing.expectError(error.InvalidPolicy, validate(a, .{ .name = "../bad", .document = "{}" }));
    try std.testing.expectError(error.InvalidPolicy, validate(a, .{ .name = "bad", .document = "null" }));
}

test "corrupt collection is not replaced by defaults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repository = try @import("../metadata/engine_repository.zig").EngineRepository.open(std.testing.allocator, tmp.dir, std.testing.io);
    defer repository.deinit();
    const metadata = SystemStore{ .repository = repository.interface() };
    try metadata.put(std.testing.allocator, path, "not json");
    if (load(metadata, std.testing.io, std.testing.allocator)) |loaded| {
        loaded.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
    const bytes = try metadata.read(std.testing.allocator, path, 100);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("not json", bytes);
}

test "default KMS policies authorize only their declared actions" {
    const iam = @import("../auth/iam_policy.zig");
    const cases = [_]struct { name: []const u8, allowed: []const []const u8, denied: []const []const u8 }{
        .{ .name = "KMSAuditor", .allowed = &.{ "kms:DescribeKey", "kms:ListKeys" }, .denied = &.{ "kms:DeleteKey", "kms:Decrypt" } },
        .{ .name = "KMSKeyAdministrator", .allowed = &.{ "kms:EnableKey", "kms:DisableKey", "kms:RotateKey", "kms:DeleteKey" }, .denied = &.{ "kms:Decrypt", "kms:GenerateDataKey" } },
        .{ .name = "KMSKeyUser", .allowed = &.{ "kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey" }, .denied = &.{ "kms:DeleteKey", "kms:EnableKey" } },
    };
    for (cases) |case| {
        const document = for (defaults) |policy| {
            if (std.mem.eql(u8, policy.name, case.name)) break policy.document;
        } else return error.TestUnexpectedResult;
        for (case.allowed) |action| try std.testing.expect(iam.allowsWithContext(std.testing.allocator, &[_][]const u8{document}, action, "arn:aws:kms:::key/test", .{}));
        for (case.denied) |action| try std.testing.expect(!iam.allowsWithContext(std.testing.allocator, &[_][]const u8{document}, action, "arn:aws:kms:::key/test", .{}));
    }
}
