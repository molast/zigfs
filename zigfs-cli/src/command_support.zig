//! Helpers used by high-level commands. Values are owned by the invocation arena.
const std = @import("std");
const m = @import("modeled.zig");
const w = @import("wire.zig");
const aliases = @import("alias.zig");
pub const A = std.mem.Allocator;
pub const V = std.json.Value;
pub fn object() V {
    return .{ .object = .{} };
}
pub fn array(a: A) V {
    return .{ .array = std.array_list.Managed(V).init(a) };
}
pub fn contains(items: []const []const u8, name: []const u8) bool {
    for (items) |item| if (w.eq(item, name)) return true;
    return false;
}
pub fn values(r: m.Args, name: []const u8) []const []const u8 {
    if (r.repeated.get(name)) |list| return list.items;
    return &.{};
}
pub fn mutation(r: m.Args) !void {
    if (!r.flags.contains("--yes") and !r.flags.contains("--dry-run")) return error.ConfirmationRequired;
}
pub fn result(a: A, out: w.Output) !V {
    if (out.exit_code != 0) return error.RemoteError;
    const envelope = (try std.json.parseFromSlice(V, a, out.stdout, .{})).value;
    return m.get(m.get(envelope, "data") orelse return error.InvalidResponse, "result") orelse return error.InvalidResponse;
}
pub fn base(a: A, remote: m.Remote, version: ?[]const u8) !V {
    var input = object();
    try m.put(a, &input, "Bucket", remote.bucket);
    if (remote.key) |key| if (key.len > 0) {
        try m.put(a, &input, "Key", key);
    };
    if (version) |id| try m.put(a, &input, "VersionId", id);
    return input;
}
pub const connection_options = [_][]const u8{
    "--endpoint",            "--region",     "--bucket-lookup", "--ca-cert", "--timeout", "--connect-timeout",
    "--management-endpoint", "--token-file",
};
/// Fail on unconsumed options instead of silently discarding typos.
pub fn check(r: m.Args, allowed_values: []const []const u8, allowed_flags: []const []const u8) !void {
    var entries = r.values.keyIterator();
    while (entries.next()) |name| {
        if (!contains(&connection_options, name.*) and !contains(allowed_values, name.*)) return error.InvalidInput;
    }
    var flags = r.flags.keyIterator();
    while (flags.next()) |name| {
        if (!contains(&.{ "--insecure", "--yes", "--dry-run" }, name.*) and !contains(allowed_flags, name.*)) return error.InvalidInput;
    }
}
pub fn network(a: A, r: m.Args, writing: bool) !m.Args {
    var clean: m.Args = .{};
    clean.headers = r.headers;
    var entries = r.values.iterator();
    while (entries.next()) |entry| {
        if (contains(&connection_options, entry.key_ptr.*)) try clean.values.put(a, entry.key_ptr.*, entry.value_ptr.*);
    }
    for ([_][]const u8{ "--insecure", "--yes", "--dry-run", "--bypass-governance-retention" }) |flag| {
        if (r.flags.contains(flag) and (writing or w.eq(flag, "--insecure"))) try clean.flags.put(a, flag, {});
    }
    return clean;
}
pub fn arguments(a: A, r: m.Args, operands: []const []const u8, writing: bool) ![]const []const u8 {
    const clean = try network(a, r, writing);
    var args: std.ArrayList([]const u8) = .empty;
    var entries = clean.values.iterator();
    while (entries.next()) |entry| try args.appendSlice(a, &.{ entry.key_ptr.*, entry.value_ptr.* });
    var flags = clean.flags.keyIterator();
    while (flags.next()) |flag| try args.append(a, flag.*);
    try args.append(a, "--");
    try args.appendSlice(a, operands);
    return args.items;
}
pub fn rawJson(a: A, ctx: aliases.Context, r: m.Args, value: V) !w.Output {
    const bytes = try std.fmt.allocPrint(a, "{s}\n", .{try std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2 })});
    if (r.values.get("--output")) |path| {
        if (w.eq(path, "-")) return .{ .stdout = bytes };
        var file = try std.Io.Dir.cwd().createFileAtomic(ctx.io, path, .{ .replace = r.flags.contains("--overwrite"), .permissions = @fromBackingInt(0o600) });
        defer file.deinit(ctx.io);
        try file.file.writeStreamingAll(ctx.io, bytes);
        try file.file.sync(ctx.io);
        if (r.flags.contains("--overwrite")) try file.replace(ctx.io) else try file.link(ctx.io);
        return .{};
    }
    return .{ .stdout = bytes };
}
pub fn readJson(a: A, ctx: aliases.Context, path: []const u8) !V {
    return (try std.json.parseFromSlice(V, a, try readBytes(a, ctx, path), .{})).value;
}
pub fn readBytes(a: A, ctx: aliases.Context, path: []const u8) ![]const u8 {
    if (!w.eq(path, "-")) {
        const file = try std.Io.Dir.cwd().openFile(ctx.io, path, .{ .follow_symlinks = false });
        defer file.close(ctx.io);
        const stat = try file.stat(ctx.io);
        if (stat.kind != .file or stat.size > 4 * 1024 * 1024) return error.InvalidInput;
        const bytes = try a.alloc(u8, @intCast(stat.size));
        if (try file.readPositionalAll(ctx.io, bytes, 0) != bytes.len) return error.InvalidInput;
        return bytes;
    }
    var data: std.ArrayList(u8) = .empty;
    var buffer: [8192]u8 = undefined;
    while (true) {
        const count = std.Io.File.stdin().readStreaming(ctx.io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };
        if (count == 0) break;
        if (data.items.len + count > 4 * 1024 * 1024) return error.InvalidInput;
        try data.appendSlice(a, buffer[0..count]);
    }
    return data.items;
}
pub fn duration(value: []const u8) !i64 {
    if (value.len < 2) return error.InvalidInput;
    const multiplier: i64 = switch (value[value.len - 1]) {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        'd' => 86400,
        'y' => 365 * 86400,
        else => return error.InvalidInput,
    };
    const count = try std.fmt.parseInt(i64, value[0 .. value.len - 1], 10);
    if (count <= 0) return error.InvalidInput;
    return std.math.mul(i64, count, multiplier) catch error.InvalidInput;
}

/// Own both streams before releasing a request or bucket arena.
pub fn ownOutput(a: A, out: w.Output) !w.Output {
    return .{ .exit_code = out.exit_code, .stdout = try a.dupe(u8, out.stdout), .stderr = try a.dupe(u8, out.stderr) };
}
pub fn localFailure(a: A, err: anyerror) !w.Output {
    const code: u8 = switch (err) {
        error.AccessDenied => 4,
        error.FileNotFound, error.AliasNotFound => 5,
        error.Canceled, error.Cancelled, error.Interrupted => 130,
        error.InvalidInput, error.ConflictingOptions, error.ConfirmationRequired => 2,
        error.UnsupportedOperation => 7,
        else => 1,
    };
    return w.failure(a, true, @errorName(err), @errorName(err), code);
}
/// Mutation progress counts confirmed successes only; an attempted failure is conservative.
pub const Progress = struct {
    planned: usize = 0,
    copied: usize = 0,
    removed: usize = 0,
    deleted: usize = 0,
    aborted: usize = 0,
    removed_bucket: bool = false,
    stage: []const u8 = "prepare",
    item: []const u8 = "",
    version_id: ?[]const u8 = null,
    upload_id: ?[]const u8 = null,
    attempted: bool = false,
    pub fn failure(self: Progress, a: A, json: bool, kind: []const u8, cause: w.Output) !w.Output {
        const completed = self.copied + self.removed + self.deleted + self.aborted + @intFromBool(self.removed_bucket);
        const data = .{
            .complete = false,
            .progress = self,
            .completed = completed,
            .unstarted = self.planned - completed - @intFromBool(self.attempted),
            .outcome_unknown = self.attempted,
            .cause = .{ .exit_code = cause.exit_code, .stdout = cause.stdout, .stderr = cause.stderr },
        };
        const envelope = .{ .schema_version = 1, .type = kind, .status = "error", .data = data };
        const detail = try std.json.Stringify.valueAlloc(a, envelope, .{});
        return .{
            .exit_code = cause.exit_code,
            .stderr = if (json) try std.fmt.allocPrint(a, "{s}\n", .{detail}) else try std.fmt.allocPrint(a, "{s}\n{s}\n", .{ cause.stderr, detail }),
        };
    }
};
/// Rebuild normalized arguments without dropping repeatable options.
pub fn allArguments(a: A, r: m.Args, operands: []const []const u8) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    var entries = r.values.iterator();
    while (entries.next()) |entry| {
        if (r.repeated.get(entry.key_ptr.*)) |list| {
            for (list.items) |value| try args.appendSlice(a, &.{ entry.key_ptr.*, value });
        } else try args.appendSlice(a, &.{ entry.key_ptr.*, entry.value_ptr.* });
    }
    var flags = r.flags.keyIterator();
    while (flags.next()) |flag| try args.append(a, flag.*);
    for (r.headers.items) |header| {
        try args.appendSlice(a, &.{ "--header", try std.fmt.allocPrint(a, "{s}:{s}", .{ header.name, header.value }) });
    }
    try args.append(a, "--");
    try args.appendSlice(a, operands);
    return args.items;
}
