const std = @import("std");
const Point = @import("monitoring.zig").Point;

pub const max_points = 8640;
pub const max_bytes = 16 * 1024 * 1024;
pub const directory = ".zigfs/monitoring";
pub const path = directory ++ "/history-v1.json";
const temporary = directory ++ "/history-v1.tmp";
const Document = struct { version: u32, points: []const Point };
const BoundedPoints = struct {
    items: []const Point,

    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!@This() {
        if (try source.next() != .array_begin) return error.UnexpectedToken;
        var points: std.ArrayList(Point) = .empty;
        errdefer points.deinit(a);
        while (try source.peekNextTokenType() != .array_end) {
            if (points.items.len >= max_points) return error.LengthMismatch;
            try points.append(a, try std.json.innerParse(Point, a, source, options));
        }
        _ = try source.next();
        return .{ .items = try points.toOwnedSlice(a) };
    }
};
const ReadDocument = struct { version: u32, points: BoundedPoints };

/// Caller owns the result. An invalid snapshot is rejected as a whole.
pub fn load(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, now: i64) ![]Point {
    // Single writer is protected by the ZigFS instance lock. A crashed write is disposable.
    root.deleteFile(io, temporary) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const bytes = root.readFileAlloc(io, path, a, .limited(max_bytes)) catch |err| switch (err) {
        error.FileNotFound => return a.alloc(Point, 0),
        else => return err,
    };
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(ReadDocument, a, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.version != 1 or parsed.value.points.items.len > max_points) return error.InvalidMonitoringHistory;
    var result: std.ArrayList(Point) = .empty;
    errdefer result.deinit(a);
    var previous: i64 = 0;
    for (parsed.value.points.items) |point| {
        if (point.timestamp <= 0 or point.timestamp < previous) return error.InvalidMonitoringHistory;
        if (point.run_id < 0) return error.InvalidMonitoringHistory;
        inline for (@typeInfo(Point).@"struct".field_names) |name| {
            if (comptime @TypeOf(@field(point, name)) == ?f64) {
                if (@field(point, name)) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidMonitoringHistory;
            }
        }
        previous = point.timestamp;
        if (point.timestamp < now - 86400 or point.timestamp > now) continue;
        try result.append(a, point);
    }
    return result.toOwnedSlice(a);
}

/// Atomic replacement; two fixed files bound peak disk usage to 32 MiB.
/// The old committed snapshot remains intact on write or file-sync failure.
pub fn save(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, points: []const Point) !void {
    if (points.len > max_points) return error.MonitoringHistoryTooLarge;
    const bytes = try std.json.Stringify.valueAlloc(a, Document{ .version = 1, .points = points }, .{});
    defer a.free(bytes);
    if (bytes.len > max_bytes) return error.MonitoringHistoryTooLarge;
    try root.createDirPath(io, directory);
    try @import("../metadata/durable.zig").syncParent(root, io, directory);
    defer root.deleteFile(io, temporary) catch {};
    const file = try root.createFile(io, temporary, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
    try root.rename(temporary, root, path, io);
    try @import("../metadata/durable.zig").syncParent(root, io, path);
}

test "history survives reopening, expires old points and ignores incomplete writes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try save(a, tmp.dir, io, &.{ .{ .timestamp = 1, .rss = 99 }, .{ .timestamp = 100000, .rss = 123, .run_id = 42 }, .{ .timestamp = 100001, .rss = null } });
    try tmp.dir.writeFile(io, .{ .sub_path = temporary, .data = "partial" });
    const restored = try load(a, tmp.dir, io, 100000);
    defer a.free(restored);
    try std.testing.expectEqual(@as(usize, 1), restored.len);
    try std.testing.expectEqual(@as(?f64, 123), restored[0].rss);
    try std.testing.expectEqual(@as(i64, 42), restored[0].run_id);
    try save(a, tmp.dir, io, restored);
    const expired = try load(a, tmp.dir, io, 200000);
    defer a.free(expired);
    try std.testing.expectEqual(@as(usize, 0), expired.len);
}

test "corrupt and incompatible history are rejected without touching object data" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, directory);
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "{broken" });
    if (load(a, tmp.dir, io, 100)) |points| {
        a.free(points);
        return error.TestUnexpectedResult;
    } else |_| {}
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "{\"version\":2,\"points\":[]}" });
    try std.testing.expectError(error.InvalidMonitoringHistory, load(a, tmp.dir, io, 100));
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "{\"version\":1,\"points\":[{\"timestamp\":90},{\"timestamp\":80}]}" });
    try std.testing.expectError(error.InvalidMonitoringHistory, load(a, tmp.dir, io, 100));
}

test "snapshot point limit preserves the previous committed file" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try save(a, tmp.dir, io, &.{.{ .timestamp = 100 }});
    const oversized = try a.alloc(Point, max_points + 1);
    defer a.free(oversized);
    try std.testing.expectError(error.MonitoringHistoryTooLarge, save(a, tmp.dir, io, oversized));
    const restored = try load(a, tmp.dir, io, 100);
    defer a.free(restored);
    try std.testing.expectEqual(@as(usize, 1), restored.len);
}

test "oversized disk snapshot is rejected before JSON allocation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, directory);
    const file = try tmp.dir.createFile(io, path, .{});
    defer file.close(io);
    try file.setLength(io, max_bytes + 1);
    try std.testing.expectError(error.StreamTooLong, load(a, tmp.dir, io, 100));
}

test "failed checkpoint leaves the committed history recoverable" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try save(a, tmp.dir, io, &.{.{ .timestamp = 100 }});
    try tmp.dir.createDirPath(io, temporary);
    if (save(a, tmp.dir, io, &.{.{ .timestamp = 110 }})) |_| return error.TestUnexpectedResult else |_| {}
    try tmp.dir.deleteDir(io, temporary);
    const restored = try load(a, tmp.dir, io, 110);
    defer a.free(restored);
    try std.testing.expectEqual(@as(i64, 100), restored[0].timestamp);
}

test "point count is bounded while decoding, before allocating the full array" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, directory);
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    try output.writer.writeAll("{\"version\":1,\"points\":[");
    for (0..max_points + 1) |i| {
        if (i > 0) try output.writer.writeAll(",");
        try output.writer.writeAll("{}");
    }
    try output.writer.writeAll("]}");
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = output.written() });
    try std.testing.expectError(error.LengthMismatch, load(a, tmp.dir, io, 100));
}
