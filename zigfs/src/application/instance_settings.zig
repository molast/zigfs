const SystemStore = @import("../metadata/system_store.zig").SystemStore;
const std = @import("std");
pub const Settings = struct {
    service_name: []const u8 = "ZigFS",
    description: []const u8 = "",
};
const path = "config/instance.json";
pub fn validate(value: Settings) !void {
    if (std.mem.trim(u8, value.service_name, " \t\r\n").len == 0 or value.service_name.len > 128 or !std.unicode.utf8ValidateSlice(value.service_name)) return error.InvalidServiceName;
    for (value.service_name) |c| if (c < 0x20 or c == 0x7f) return error.InvalidServiceName;
    if (value.description.len > 4096 or !std.unicode.utf8ValidateSlice(value.description)) return error.InvalidInstanceDescription;
    for (value.description) |c| if ((c < 0x20 and c != '\n' and c != '\r' and c != '\t') or c == 0x7f) return error.InvalidInstanceDescription;
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
test "instance settings persist UTF8 and reject invalid updates without replacing saved values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repository = try @import("../metadata/engine_repository.zig").EngineRepository.open(std.testing.allocator, tmp.dir, std.testing.io);
    defer repository.deinit();
    const metadata = SystemStore{ .repository = repository.interface() };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("ZigFS", (try load(a, metadata, std.testing.io)).service_name);
    const value: Settings = .{ .service_name = "研发存储", .description = "Primary\n第二行" };
    try save(a, metadata, std.testing.io, value);
    try std.testing.expectEqualStrings(value.description, (try load(a, metadata, std.testing.io)).description);
    try std.testing.expectError(error.InvalidServiceName, save(a, metadata, std.testing.io, .{ .service_name = "  " }));
    try std.testing.expectError(error.InvalidInstanceDescription, save(a, metadata, std.testing.io, .{ .description = "\x00" }));
    try std.testing.expectEqualStrings(value.service_name, (try load(a, metadata, std.testing.io)).service_name);
}
