const std = @import("std");
const Config = @import("../config.zig").Config;
pub const Settings = struct { s3_region: []const u8 };
const path = ".zigfs/config/region.json";
pub fn validate(region: []const u8) !void {
    if (!Config.isValidS3Region(region)) return error.InvalidRegion;
}
// Caller provides an arena; writes are serialized with policy_mutex.
pub fn load(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, fallback: []const u8) ![]const u8 {
    const bytes = root.readFileAlloc(io, path, a, .limited(1024)) catch |err| switch (err) {
        error.FileNotFound => return fallback,
        else => return err,
    };
    const parsed = try std.json.parseFromSlice(Settings, a, bytes, .{ .allocate = .alloc_always });
    try validate(parsed.value.s3_region);
    return parsed.value.s3_region;
}
pub fn save(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, region: []const u8) !void {
    try validate(region);
    const bytes = try std.json.Stringify.valueAlloc(a, Settings{ .s3_region = region }, .{});
    try root.createDirPath(io, ".zigfs/config");
    var file = try root.createFileAtomic(io, path, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, bytes);
    try file.file.sync(io);
    try file.replace(io);
    try @import("../metadata/durable.zig").syncParent(root, io, path);
}
test "region uses startup validation and preserves last valid save" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("us-east-1", try load(a, tmp.dir, std.testing.io, "us-east-1"));
    try save(a, tmp.dir, std.testing.io, "eu-central-1");
    const oversized: [64]u8 = @splat('x');
    for ([_][]const u8{ "", "US-east-1", "-zone", "zone-", "a/b", "zone 1", "区", &oversized }) |bad| {
        try std.testing.expectError(error.InvalidRegion, save(a, tmp.dir, std.testing.io, bad));
    }
    try std.testing.expectEqualStrings("eu-central-1", try load(a, tmp.dir, std.testing.io, "us-east-1"));
    try save(a, tmp.dir, std.testing.io, "local-1");
    try std.testing.expectEqualStrings("local-1", try load(a, tmp.dir, std.testing.io, "us-east-1"));
}
