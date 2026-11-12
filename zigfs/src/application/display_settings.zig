const std = @import("std");
pub const Settings = struct {
    timezone: []const u8 = "browser",
    date_format: []const u8 = "locale",
};
pub const timezones = @embedFile("display_timezones.txt");
const path = ".zigfs/config/display.json";
pub fn validate(value: Settings) !void {
    var zones = std.mem.tokenizeScalar(u8, timezones, '\n');
    var valid = false;
    while (zones.next()) |zone| {
        if (std.mem.eql(u8, zone, value.timezone)) {
            valid = true;
            break;
        }
    }
    if (!valid) return error.InvalidDisplayTimezone;
    for ([_][]const u8{ "locale", "ymd", "dmy", "mdy" }) |format| {
        if (std.mem.eql(u8, format, value.date_format)) return;
    }
    return error.InvalidDisplayDateFormat;
}
// Caller holds policy_mutex and supplies a request arena.
pub fn load(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io) !Settings {
    const bytes = root.readFileAlloc(io, path, a, .limited(32768)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    const value = try std.json.parseFromSlice(Settings, a, bytes, .{ .allocate = .alloc_always });
    try validate(value.value);
    return value.value;
}
pub fn save(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, value: Settings) !void {
    try validate(value);
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    try root.createDirPath(io, ".zigfs/config");
    var file = try root.createFileAtomic(io, path, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, bytes);
    try file.file.sync(io);
    try file.replace(io);
    try @import("../metadata/durable.zig").syncParent(root, io, path);
}
test "display settings validate timezone and format and preserve saved values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("browser", (try load(a, tmp.dir, std.testing.io)).timezone);
    const value: Settings = .{ .timezone = "America/New_York", .date_format = "ymd" };
    try save(a, tmp.dir, std.testing.io, value);
    try std.testing.expectError(error.InvalidDisplayTimezone, save(a, tmp.dir, std.testing.io, .{ .timezone = "../UTC" }));
    try std.testing.expectError(error.InvalidDisplayDateFormat, save(a, tmp.dir, std.testing.io, .{ .date_format = "bad" }));
    try std.testing.expectEqualStrings(value.timezone, (try load(a, tmp.dir, std.testing.io)).timezone);
    try std.testing.expectEqualStrings(value.date_format, (try load(a, tmp.dir, std.testing.io)).date_format);
}
