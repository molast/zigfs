//! Long-poll real object events. Resume only after complete output, at-least-once across crashes.
const std = @import("std");
const aliases = @import("alias.zig");
const m = @import("modeled.zig");
const w = @import("wire.zig");
const s = @import("command_support.zig");
const A = std.mem.Allocator;
const V = std.json.Value;
const Io = std.Io;
extern fn zc_bulk_begin() void;
extern fn zc_bulk_listen() void;
extern fn zc_bulk_end() void;
extern fn zc_interrupted() c_int;
fn save(a: A, ctx: aliases.Context, path: []const u8, identity: []const u8, cursor: []const u8) !void {
    var file = try Io.Dir.cwd().createFileAtomic(ctx.io, path, .{ .replace = true, .permissions = @fromBackingInt(0o600) });
    defer file.deinit(ctx.io);
    try file.file.writeStreamingAll(ctx.io, try std.json.Stringify.valueAlloc(a, .{ .identity = identity, .cursor = cursor }, .{}));
    try file.file.sync(ctx.io);
    try file.replace(ctx.io);
}
pub fn execute(a: A, ctx: aliases.Context, _: []const u8, args: []const []const u8, config: ?[]const u8, _: bool, quiet: bool) anyerror!w.Output {
    const r = try m.parse(a, args);
    try s.check(r, &.{ "--prefix", "--suffix", "--events", "--cursor", "--cursor-file", "--count", "--reconnect-attempts" }, &.{});
    if (r.operands.items.len != 1 or r.headers.items.len != 0 or r.flags.contains("--yes") or r.flags.contains("--dry-run")) return error.InvalidInput;
    const cursor_file = r.values.get("--cursor-file");
    if (cursor_file) |path| {
        // A checkpoint must support both reads and atomic file replacement.
        if (w.eq(path, "-") or r.values.contains("--cursor")) return error.InvalidInput;
    }
    const remote = try m.remote(r.operands.items[0]);
    if (remote.key != null and remote.key.?.len > 0 and r.values.contains("--prefix")) return error.InvalidInput;
    const prefix = r.values.get("--prefix") orelse remote.key orelse "";
    const suffix = r.values.get("--suffix") orelse "";
    const events = r.values.get("--events") orelse "PUT,DELETE,ILM,SCANNER";
    var categories = std.mem.splitScalar(u8, events, ',');
    while (categories.next()) |category| if (!s.contains(&.{ "PUT", "GET", "DELETE", "ILM", "SCANNER" }, category)) return error.InvalidInput;
    const count = if (r.values.get("--count")) |text| try std.fmt.parseInt(u64, text, 10) else 0;
    if (r.values.contains("--count") and count == 0) return error.InvalidInput;
    const retries = try std.fmt.parseInt(u32, r.values.get("--reconnect-attempts") orelse "3", 10);
    if (retries > 10) return error.InvalidInput;
    const conn = try m.connection(a, ctx, r, config, remote.alias);
    const endpoint = r.values.get("--management-endpoint") orelse conn.management_endpoint;
    if (endpoint.len == 0) return error.InvalidEndpoint;
    const identity = try std.json.Stringify.valueAlloc(a, .{ .endpoint = endpoint, .bucket = remote.bucket, .prefix = prefix, .suffix = suffix, .events = events }, .{});
    const backing = std.heap.page_allocator;
    var cursor: ?[]const u8 = null;
    if (r.values.get("--cursor")) |value| cursor = try backing.dupe(u8, value);
    if (cursor_file) |path| {
        if (cursor != null) return error.InvalidInput;
        const stored = w.readJson(a, ctx.io, path) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (stored) |value| {
            if (!w.eq(m.text(value, "identity") orelse "", identity)) return error.InvalidInput;
            cursor = try backing.dupe(u8, m.text(value, "cursor") orelse return error.InvalidInput);
        }
    }
    defer if (cursor) |value| backing.free(value);
    zc_bulk_begin();
    zc_bulk_listen();
    defer zc_bulk_end();
    var emitted: u64 = 0;
    var failures: u32 = 0;
    while (zc_interrupted() == 0) {
        var arena = std.heap.ArenaAllocator.init(backing);
        defer arena.deinit();
        const pa = arena.allocator();
        var query: std.ArrayList([]const u8) = .empty;
        try query.appendSlice(pa, try s.arguments(pa, r, &.{}, false));
        // arguments() terminates options; remove that terminator before adding feed fields.
        _ = query.pop();
        if (cursor) |value| try query.appendSlice(pa, &.{ "--cursor", value });
        if (prefix.len > 0) try query.appendSlice(pa, &.{ "--prefix", prefix });
        if (suffix.len > 0) try query.appendSlice(pa, &.{ "--suffix", suffix });
        try query.appendSlice(pa, &.{ "--events", events, "--wait", "20", "--limit", try std.fmt.allocPrint(pa, "{d}", .{if (count == 0) @as(u64, 200) else @min(200, count - emitted)}), "--", remote.alias, remote.bucket });
        const out = try @import("management.zig").execute(pa, ctx, "admin bucket watch get", query.items, config, true, false);
        if (out.exit_code != 0) {
            if (zc_interrupted() != 0) return .{ .exit_code = 130 };
            if (out.exit_code == 3 and failures < retries) {
                failures += 1;
                try Io.sleep(ctx.io, .fromSeconds(@intCast(failures)), .awake);
                continue;
            }
            return .{ .exit_code = out.exit_code, .stderr = try a.dupe(u8, out.stderr) };
        }
        failures = 0;
        const page = try s.result(pa, out);
        const records = m.get(page, "items") orelse return error.InvalidResponse;
        if (records != .array or records.array.items.len > 200) return error.InvalidResponse;
        const next = m.text(page, "next_cursor") orelse return error.InvalidResponse;
        for (records.array.items) |record| {
            const line = try w.output(pa, true, false, "object-event", record);
            try Io.File.stdout().writeStreamingAll(ctx.io, line.stdout);
            emitted += 1;
        }
        // Heartbeats expose a reconnect token; quiet suppresses only these, never object records.
        if (!quiet) {
            const progress = try w.output(pa, true, false, "watch-cursor", .{ .cursor = next, .replay = "bounded-memory", .event_count = emitted });
            try Io.File.stdout().writeStreamingAll(ctx.io, progress.stdout);
        }
        if (cursor_file) |path| try save(pa, ctx, path, identity, next);
        const owned = try backing.dupe(u8, next);
        if (cursor) |previous| backing.free(previous);
        cursor = owned;
        if (count > 0 and emitted >= count) return .{};
    }
    return .{ .exit_code = 130 };
}
