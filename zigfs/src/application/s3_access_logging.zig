//! Successful and failed S3 requests are written as JSONL objects to a same-owner
//! destination bucket. Internal writes bypass event capture, avoiding log recursion.
const std = @import("std");
const App = @import("mod.zig").Application;
const config = @import("s3_configuration.zig");
const stream = @import("../ports/byte_stream.zig");
const A = std.mem.Allocator;

pub const Request = struct {
    bucket: []const u8,
    key: ?[]const u8,
    method: []const u8,
    actor: []const u8,
    request_id: []const u8,
    status: u16,
    duration_ms: u64,
};

pub const Source = struct {
    bytes: []const u8,
    offset: usize = 0,
    pub fn interface(self: *Source) stream.Source {
        return .{ .context = self, .vtable = &.{ .read = read } };
    }
    fn read(context: *anyopaque, buffer: []u8) stream.Source.Error!usize {
        const self: *Source = @ptrCast(@alignCast(context));
        const count = @min(buffer.len, self.bytes.len - self.offset);
        @memcpy(buffer[0..count], self.bytes[self.offset..][0..count]);
        self.offset += count;
        return count;
    }
};

pub fn record(app: *App, request: Request) !void {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const buckets = app.bucketService() orelse return;
    const bucket = buckets.head(request.bucket) catch |err| switch (err) {
        error.BucketNotFound => return,
        else => return err,
    };
    defer bucket.deinit(app.allocator);
    try @import("s3_reports.zig").recordRequest(a, app, bucket.id, request.key, request.method, request.status);
    const document = try config.load(a, app.systemStore(), bucket.id, "logging") orelse return;
    const enabled = config.child(document, "LoggingEnabled") orelse return;
    const target_name = config.text(enabled, "TargetBucket") orelse return error.InvalidLogging;
    const target = try buckets.head(target_name);
    defer target.deinit(app.allocator);
    if (!std.mem.eql(u8, target.owner, bucket.owner)) return error.AccessDenied;
    const prefix = config.text(enabled, "TargetPrefix") orelse "";
    const io = app.io orelse return;
    const timestamp = std.Io.Clock.real.now(io).toMilliseconds();
    const uuid = try @import("../common/id.zig").randomV4(io);
    const name = try std.fmt.allocPrint(a, "{s}{d}-{s}.jsonl", .{ prefix, timestamp, std.fmt.bytesToHex(uuid, .lower) });
    const json = try std.json.Stringify.valueAlloc(a, .{
        .timestamp_unix_ms = timestamp,
        .bucket = request.bucket,
        .key = request.key,
        .method = request.method,
        .actor = request.actor,
        .request_id = request.request_id,
        .status = request.status,
        .duration_ms = request.duration_ms,
    }, .{});
    var source: Source = .{ .bytes = try std.fmt.allocPrint(a, "{s}\n", .{json}) };
    var objects = app.objectService() orelse return;
    objects.event_sink = null;
    const stored = try objects.put(target_name, name, source.interface(), .{ .content_type = "application/x-ndjson" });
    stored.deinit(app.allocator);
}
