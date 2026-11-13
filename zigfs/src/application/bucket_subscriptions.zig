const std = @import("std");
pub const Subscription = struct {
    id: []const u8,
    destination: []const u8 = "",
    prefix: []const u8 = "",
    suffix: []const u8 = "",
    events: []const []const u8,
};
pub const Settings = struct { items: []const Subscription = &.{} };
pub fn validate(settings: Settings) !void {
    return validateStored(settings, false);
}
fn validateStored(settings: Settings, legacy: bool) !void {
    if (settings.items.len > 100) return error.InvalidEventSubscription;
    for (settings.items, 0..) |item, i| {
        if (item.destination.len > 0 and !@import("event_destinations.zig").validName(item.destination)) return error.InvalidEventSubscription;
        if (item.id.len == 0 or item.id.len > 64 or item.events.len == 0 or item.events.len > @as(usize, if (legacy) 6 else 5)) return error.InvalidEventSubscription;
        for (item.id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return error.InvalidEventSubscription;
        for (settings.items[0..i]) |previous| if (std.mem.eql(u8, previous.id, item.id)) return error.InvalidEventSubscription;
        for ([_][]const u8{ item.prefix, item.suffix }) |filter| {
            if (filter.len > 1024 or !std.unicode.utf8ValidateSlice(filter) or std.mem.indexOfScalar(u8, filter, 0) != null) return error.InvalidEventSubscription;
        }
        for (item.events, 0..) |event, n| {
            var valid = false;
            for ([_][]const u8{ "PUT", "GET", "DELETE", "REPLICA", "ILM", "SCANNER" }) |allowed| if (std.mem.eql(u8, allowed, event)) {
                valid = true;
            };
            if (!valid or (!legacy and std.mem.eql(u8, event, "REPLICA"))) return error.InvalidEventSubscription;
            for (item.events[0..n]) |previous| if (std.mem.eql(u8, previous, event)) return error.InvalidEventSubscription;
        }
    }
}
fn path(a: std.mem.Allocator, bucket_id: [16]u8) ![]const u8 {
    return std.fmt.allocPrint(a, ".zigfs/config/bucket-subscriptions/{s}.json", .{std.fmt.bytesToHex(bucket_id, .lower)});
}
// Caller holds policy_mutex and supplies an arena. Bucket UUID prevents name reuse from inheriting rules.
pub fn load(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, bucket_id: [16]u8) !Settings {
    const bytes = root.readFileAlloc(io, try path(a, bucket_id), a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    const parsed = try std.json.parseFromSlice(Settings, a, bytes, .{ .allocate = .alloc_always });
    try validateStored(parsed.value, true);
    // Legacy REPLICA rules never had producers. Remove only that category;
    // retain all active filters and targets, and drop rules with no events left.
    var items: std.ArrayList(Subscription) = .empty;
    for (parsed.value.items) |item| {
        var events: std.ArrayList([]const u8) = .empty;
        for (item.events) |event| {
            if (!std.mem.eql(u8, event, "REPLICA")) try events.append(a, event);
        }
        if (events.items.len == 0) continue;
        var active = item;
        active.events = try events.toOwnedSlice(a);
        try items.append(a, active);
    }
    const result: Settings = .{ .items = try items.toOwnedSlice(a) };
    try validate(result);
    return result;
}
pub fn save(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, bucket_id: [16]u8, value: Settings) !void {
    try validate(value);
    const filename = try path(a, bucket_id);
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    try root.createDirPath(io, ".zigfs/config/bucket-subscriptions");
    var file = try root.createFileAtomic(io, filename, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, bytes);
    try file.file.sync(io);
    try file.replace(io);
    try @import("../metadata/durable.zig").syncParent(root, io, filename);
}
test "subscription configuration persists, isolates buckets and preserves data on invalid updates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = @as([16]u8, @splat(1));
    const value: Settings = .{ .items = &.{.{ .id = "one", .prefix = "photos/", .suffix = ".png", .events = &.{ "PUT", "DELETE" } }} };
    try save(a, tmp.dir, std.testing.io, id, value);
    try std.testing.expectEqualStrings("photos/", (try load(a, tmp.dir, std.testing.io, id)).items[0].prefix);
    try std.testing.expectEqual(@as(usize, 0), (try load(a, tmp.dir, std.testing.io, @as([16]u8, @splat(2)))).items.len);
    try std.testing.expectError(error.InvalidEventSubscription, save(a, tmp.dir, std.testing.io, id, .{ .items = &.{.{ .id = "bad", .events = &.{"unknown"} }} }));
    try std.testing.expectEqual(@as(usize, 1), (try load(a, tmp.dir, std.testing.io, id)).items.len);
    try save(a, tmp.dir, std.testing.io, id, .{});
    try std.testing.expectEqual(@as(usize, 0), (try load(a, tmp.dir, std.testing.io, id)).items.len);
}

test "retired replica rules are filtered on load and rejected on save" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const id = @as([16]u8, @splat(3));
    try tmp.dir.createDirPath(io, ".zigfs/config/bucket-subscriptions");
    const filename = try path(a, id);
    {
        var file = try tmp.dir.createFile(io, filename, .{});
        defer file.close(io);
        try file.writeStreamingAll(io,
            \\{"items":[{"id":"mixed","destination":"HTTP","prefix":"photos/","suffix":".jpg","events":["PUT","REPLICA","ILM"]},{"id":"retired","events":["REPLICA"]}]}
        );
    }
    const result = try load(a, tmp.dir, io, id);
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expectEqualStrings("HTTP", result.items[0].destination);
    try std.testing.expectEqualStrings("photos/", result.items[0].prefix);
    try std.testing.expectEqualStrings(".jpg", result.items[0].suffix);
    try std.testing.expectEqual(@as(usize, 2), result.items[0].events.len);
    try std.testing.expectEqualStrings("PUT", result.items[0].events[0]);
    try std.testing.expectEqualStrings("ILM", result.items[0].events[1]);
    try std.testing.expectError(error.InvalidEventSubscription, save(a, tmp.dir, io, id, .{ .items = &.{.{ .id = "bad", .events = &.{ "PUT", "REPLICA" } }} }));
    try save(a, tmp.dir, io, id, result);
    const bytes = try tmp.dir.readFileAlloc(io, filename, a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "REPLICA") == null);
}
