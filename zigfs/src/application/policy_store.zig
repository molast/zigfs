const std = @import("std");
const durable = @import("../metadata/durable.zig");
pub const Policy = struct { name: []const u8, document: []const u8 };
pub const path = ".zigfs/system/policies.json";
pub const initialization_marker = ".zigfs/system/policies.initialized";
pub const defaults = [_]Policy{ .{ .name = "consoleAdmin", .document = @embedFile("policies/consoleAdmin.json") }, .{ .name = "diagnostics", .document = @embedFile("policies/diagnostics.json") }, .{ .name = "KMSAuditor", .document = @embedFile("policies/KMSAuditor.json") }, .{ .name = "KMSKeyAdministrator", .document = @embedFile("policies/KMSKeyAdministrator.json") }, .{ .name = "KMSKeyUser", .document = @embedFile("policies/KMSKeyUser.json") }, .{ .name = "readonly", .document = @embedFile("policies/readonly.json") }, .{ .name = "readwrite", .document = @embedFile("policies/readwrite.json") }, .{ .name = "writeonly", .document = @embedFile("policies/writeonly.json") } };

pub fn validate(allocator: std.mem.Allocator, policy: Policy) !void {
    if (policy.name.len == 0 or policy.name.len > 128) return error.InvalidPolicy;
    for (policy.name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return error.InvalidPolicy;
    }
    if (policy.document.len > 256 * 1024) return error.InvalidPolicy;
    try @import("../auth/iam_policy.zig").validateDocument(allocator, policy.document, .identity);
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
            if (root.readFileAlloc(io, initialization_marker, allocator, .limited(64))) |marker| {
                allocator.free(marker);
                return error.PolicyStoreMissing;
            } else |marker_err| switch (marker_err) {
                error.FileNotFound => {},
                else => return marker_err,
            }
            try save(root, io, allocator, &defaults);
            try root.writeFile(io, .{ .sub_path = initialization_marker, .data = "1\n" });
            return load(root, io, allocator);
        },
        else => return err,
    };
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice([]Policy, allocator, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
    for (parsed.value) |policy| try validate(allocator, policy);
    if (root.readFileAlloc(io, initialization_marker, allocator, .limited(64))) |marker| {
        allocator.free(marker);
    } else |marker_err| switch (marker_err) {
        error.FileNotFound => try root.writeFile(io, .{ .sub_path = initialization_marker, .data = "1\n" }),
        else => {
            parsed.deinit();
            return marker_err;
        },
    }
    return parsed;
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
