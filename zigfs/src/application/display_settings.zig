const SystemStore = @import("../metadata/system_store.zig").SystemStore;
const std = @import("std");
pub const Settings = struct {
    timezone: []const u8 = "browser",
    date_format: []const u8 = "locale",
};
pub const timezones = @embedFile("display_timezones");
const path = "config/display.json";
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
pub fn load(a: std.mem.Allocator, root: SystemStore, io: std.Io) !Settings {
    _ = io;
    const bytes = root.read(a, path, 32768) catch |err| switch (err) {
        error.NotFound => return .{},
        else => return err,
    };
    const value = try std.json.parseFromSlice(Settings, a, bytes, .{ .allocate = .alloc_always });
    try validate(value.value);
    return value.value;
}
pub fn save(a: std.mem.Allocator, root: SystemStore, io: std.Io, value: Settings) !void {
    _ = io;
    try validate(value);
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    try root.put(a, path, bytes);
}
test "display settings validate timezone and format and preserve saved values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repository = try @import("../metadata/engine_repository.zig").EngineRepository.open(std.testing.allocator, tmp.dir, std.testing.io);
    defer repository.deinit();
    const metadata = SystemStore{ .repository = repository.interface() };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("browser", (try load(a, metadata, std.testing.io)).timezone);
    const value: Settings = .{ .timezone = "America/New_York", .date_format = "ymd" };
    try save(a, metadata, std.testing.io, value);
    try std.testing.expectError(error.InvalidDisplayTimezone, save(a, metadata, std.testing.io, .{ .timezone = "../UTC" }));
    try std.testing.expectError(error.InvalidDisplayDateFormat, save(a, metadata, std.testing.io, .{ .date_format = "bad" }));
    try std.testing.expectEqualStrings(value.timezone, (try load(a, metadata, std.testing.io)).timezone);
    try std.testing.expectEqualStrings(value.date_format, (try load(a, metadata, std.testing.io)).date_format);
}
