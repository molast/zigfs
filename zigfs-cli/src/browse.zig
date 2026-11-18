const std = @import("std");
const aliases = @import("alias.zig");
const api = @import("s3api.zig");
const A = std.mem.Allocator;
const V = std.json.Value;
const File = opaque {};
extern "c" fn tmpfile() ?*File;
extern "c" fn fclose(*File) c_int;
extern "c" fn fwrite([*]const u8, usize, usize, *File) usize;
extern "c" fn fread([*]u8, usize, usize, *File) usize;
extern "c" fn fseek(*File, c_long, c_int) c_int;
extern "c" fn ferror(*File) c_int;

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn isFlag(s: []const u8) bool {
    return eq(s, "--recursive") or eq(s, "-r") or eq(s, "--yes") or eq(s, "--dry-run") or eq(s, "--summarize") or eq(s, "--insecure");
}
pub fn isValueOption(s: []const u8) bool {
    return eq(s, "--list-api") or eq(s, "--page-size") or eq(s, "--prefix") or (api.isValueOption(s) and !eq(s, "--input-json") and !eq(s, "--body") and !eq(s, "--output"));
}
fn put(a: A, v: *V, key: []const u8, text: []const u8) !void {
    try v.object.put(a, key, .{ .string = text });
}
fn field(v: V, key: []const u8) ?V {
    return if (v == .object) v.object.get(key) else null;
}
fn str(v: V, key: []const u8) ?[]const u8 {
    const f = field(v, key) orelse return null;
    return if (f == .string) f.string else null;
}
fn write(f: *File, s: []const u8) !void {
    if (fwrite(s.ptr, 1, s.len, f) != s.len) return error.InputOutput;
}
fn emit(a: A, f: *File, v: anytype) !void {
    try write(f, try std.json.Stringify.valueAlloc(a, v, .{}));
}

/// Pages have independent arenas. Anonymous disk spool keeps stdout atomic on
/// remote failures without accumulating the complete listing in memory.
pub fn execute(a: A, ctx: aliases.Context, action: []const u8, args: []const []const u8, config: ?[]const u8, json: bool, quiet: bool) anyerror!api.Output {
    if (eq(action, "object list") or eq(action, "ls")) {
        var v1 = false;
        for (args, 0..) |arg, i| if (eq(arg, "--list-api=v1") or (eq(arg, "--list-api") and i + 1 < args.len and eq(args[i + 1], "v1"))) {
            v1 = true;
        };
        if (v1) {
            var forwarded: std.ArrayList([]const u8) = .empty;
            var recursive = false;
            try forwarded.append(a, "--all-pages");
            var n: usize = 0;
            while (n < args.len) : (n += 1) {
                if (eq(args[n], "--list-api")) {
                    n += 1;
                    continue;
                }
                if (eq(args[n], "--list-api=v1")) continue;
                if (eq(args[n], "--recursive") or eq(args[n], "-r")) {
                    recursive = true;
                    continue;
                }
                try forwarded.append(a, if (eq(args[n], "--page-size")) "--max-keys" else args[n]);
            }
            if (!recursive) try forwarded.appendSlice(a, &.{ "--delimiter", "/" });
            return @import("modeled.zig").execute(a, ctx, "object list-v1", forwarded.items, config, json, quiet);
        }
    }

    var target: ?[]const u8 = null;
    var pass: std.ArrayList([]const u8) = .empty;
    var recursive = false;
    var yes = false;
    var dry = false;
    var summarize = false;
    var prefix: ?[]const u8 = null;
    var region: ?[]const u8 = null;
    var size: i64 = 1000;
    var list_option = false;
    var ended = false;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!ended and eq(arg, "--")) {
            ended = true;
            continue;
        }
        if (!ended and std.mem.startsWith(u8, arg, "-")) {
            const split = std.mem.indexOfScalar(u8, arg, '=');
            const name = if (split) |n| arg[0..n] else arg;
            if (!eq(name, "--header") and !eq(name, "-H")) {
                if (seen.contains(name)) return error.InvalidInput;
                try seen.put(a, name, {});
            }
            if (isFlag(name)) {
                if (split != null) return error.InvalidInput;
                if (eq(name, "--recursive") or eq(name, "-r")) {
                    recursive = true;
                    list_option = true;
                } else if (eq(name, "--summarize")) {
                    summarize = true;
                    list_option = true;
                } else if (eq(name, "--yes")) yes = true else if (eq(name, "--dry-run")) dry = true else try pass.append(a, arg);
            } else if (isValueOption(name)) {
                const value = if (split) |n| arg[n + 1 ..] else blk: {
                    i += 1;
                    if (i == args.len) return error.InvalidInput;
                    break :blk args[i];
                };
                if (value.len == 0) return error.InvalidInput;
                if (eq(name, "--list-api")) {
                    if (!eq(value, "v2")) return error.UnsupportedOperation;
                    list_option = true;
                } else if (eq(name, "--page-size")) {
                    size = std.fmt.parseInt(i64, value, 10) catch return error.InvalidInput;
                    if (size < 1 or size > 1000) return error.InvalidInput;
                    list_option = true;
                } else if (eq(name, "--prefix")) {
                    prefix = value;
                    list_option = true;
                } else {
                    if (eq(name, "--region")) region = value;
                    try pass.appendSlice(a, &.{ name, value });
                }
            } else return error.InvalidInput;
        } else {
            if (target != null) return error.InvalidInput;
            target = arg;
        }
    }
    const remote = target orelse return error.InvalidInput;
    const slash = std.mem.indexOfScalar(u8, remote, '/');
    const name = if (slash) |s| remote[0..s] else remote;
    if (name.len == 0) return error.InvalidInput;
    const rest = if (slash) |s| remote[s + 1 ..] else "";
    const cut = std.mem.indexOfScalar(u8, rest, '/');
    const bucket = if (cut) |s| rest[0..s] else rest;
    const path_prefix = if (cut) |s| rest[s + 1 ..] else "";
    const command = if (eq(action, "ls")) (if (bucket.len == 0) "bucket list" else "object list") else action;
    const buckets = eq(command, "bucket list");
    const listing = buckets or eq(command, "object list");
    const remove = eq(command, "bucket remove");
    if (buckets) {
        if (rest.len != 0 or recursive or seen.contains("--list-api")) return error.InvalidInput;
    } else if (bucket.len == 0 or (!listing and path_prefix.len != 0)) return error.InvalidInput;
    if (!listing and list_option) return error.InvalidInput;
    if (!remove and (yes or dry)) return error.InvalidInput;
    if (remove and !yes and !dry) return error.ConfirmationRequired;
    if (prefix != null and path_prefix.len > 0) return error.InvalidInput;
    try pass.append(a, name);
    if (remove) try pass.append(a, "--yes");
    const op: []const u8 = if (buckets) "list-buckets" else if (listing) "list-objects-v2" else if (eq(command, "bucket create")) "create-bucket" else if (remove) "delete-bucket" else if (eq(command, "bucket stat")) "head-bucket" else "get-bucket-location";
    var base: V = .{ .object = .{} };
    if (!buckets) try put(a, &base, "Bucket", bucket);
    if (listing) {
        try base.object.put(a, if (buckets) "MaxBuckets" else "MaxKeys", .{ .integer = size });
        if (prefix orelse if (path_prefix.len > 0) path_prefix else null) |p| try put(a, &base, "Prefix", p);
        if (!buckets and !recursive) try put(a, &base, "Delimiter", "/");
    }
    if (eq(op, "create-bucket")) {
        const conn = try aliases.connection(a, ctx, config, name, .{ .region = region });
        if (!eq(conn.region, "us-east-1")) {
            var location: V = .{ .object = .{} };
            try put(a, &location, "LocationConstraint", conn.region);
            try base.object.put(a, "CreateBucketConfiguration", location);
        }
    }
    if (dry) return .{ .stdout = if (quiet and !json) "" else if (json) try std.fmt.allocPrint(a, "{s}\n", .{try std.json.Stringify.valueAlloc(a, .{ .schema_version = 1, .type = command, .status = "success", .data = .{ .dry_run = true, .target = remote } }, .{})}) else try std.fmt.allocPrint(a, "Would remove empty bucket {s}\n", .{remote}) };
    if (!listing) return api.executeInput(a, ctx, op, pass.items, config, json, quiet, base);
    const spool = tmpfile() orelse return error.InputOutput;
    defer _ = fclose(spool);
    if (json) {
        try write(spool, "{\"schema_version\":1,\"type\":");
        try emit(a, spool, command);
        try write(spool, ",\"status\":\"success\",\"data\":{\"items\":[");
    }
    var token: ?[]u8 = null;
    defer if (token) |t| std.heap.page_allocator.free(t);
    var hashes: std.AutoHashMapUnmanaged([32]u8, void) = .empty;
    defer hashes.deinit(std.heap.page_allocator);
    var count: u64 = 0;
    var pages: u64 = 0;
    while (true) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const pa = arena.allocator();
        var input = base;
        // Clone the map so continuation updates cannot mutate the base.
        input.object = .{};
        var it = base.object.iterator();
        while (it.next()) |e| try input.object.put(pa, e.key_ptr.*, e.value_ptr.*);
        if (token) |t| try put(pa, &input, "ContinuationToken", t);
        const response = try api.executeInput(pa, ctx, op, pass.items, config, true, false, input);
        if (response.exit_code != 0) return .{ .exit_code = response.exit_code, .stderr = if (json) try a.dupe(u8, response.stderr) else try std.fmt.allocPrint(a, "zc: listing failed after {d} pages; no partial results emitted\n{s}", .{ pages, response.stderr }) };
        const envelope = (try std.json.parseFromSlice(V, pa, response.stdout, .{})).value;
        const result = envelope.object.get("data").?.object.get("result").?;
        if (result != .object) return error.InvalidResponse;
        pages += 1;
        const container = if (buckets) field(result, "Buckets") orelse .null else result;
        const entries = field(container, if (buckets) "Bucket" else "Contents");
        const prefixes = if (buckets) null else field(result, "CommonPrefixes");
        for ([_]?V{ entries, prefixes }, 0..) |maybe, kind| {
            if (maybe) |items| {
                if (items != .array) return error.InvalidResponse;
                for (items.array.items) |item| {
                    const label = str(item, if (buckets) "Name" else if (kind == 1) "Prefix" else "Key") orelse return error.InvalidResponse;
                    if (json) {
                        if (count > 0) try write(spool, ",");
                        try emit(pa, spool, .{ .kind = if (buckets) "bucket" else if (kind == 1) "prefix" else "object", .entry = item });
                    } else if (!quiet) {
                        // JSON quoting protects terminals from control characters in keys.
                        try emit(pa, spool, label);
                        try write(spool, "\n");
                    }
                    count += 1;
                }
            }
        }
        const next = str(result, if (buckets) "ContinuationToken" else "NextContinuationToken");
        const truncated = str(result, "IsTruncated");
        if (!buckets and (truncated == null or (!eq(truncated.?, "true") and !eq(truncated.?, "false")))) return error.InvalidResponse;
        const more = if (buckets) next != null and next.?.len > 0 else eq(truncated.?, "true");
        if (!more) break;
        const n = next orelse return error.InvalidResponse;
        if (n.len == 0 or n.len > 65536 or pages >= 100000) return error.InvalidResponse;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(n, &digest, .{});
        if (hashes.contains(digest)) return error.InvalidResponse;
        try hashes.put(std.heap.page_allocator, digest, {});
        if (token) |t| std.heap.page_allocator.free(t);
        token = try std.heap.page_allocator.dupe(u8, n);
    }
    if (json) try write(spool, try std.fmt.allocPrint(a, "],\"count\":{d},\"pages\":{d},\"complete\":true}}}}\n", .{ count, pages })) else if (summarize and !quiet) try write(spool, try std.fmt.allocPrint(a, "{d} entries, {d} pages\n", .{ count, pages }));
    if (fseek(spool, 0, 0) != 0) return error.InputOutput;
    var buffer: [65536]u8 = undefined;
    while (true) {
        const n = fread(&buffer, 1, buffer.len, spool);
        if (n == 0) break;
        try std.Io.File.stdout().writeStreamingAll(ctx.io, buffer[0..n]);
    }
    if (ferror(spool) != 0) return error.InputOutput;
    return .{};
}
pub const help =
    \\Usage: zc bucket list ALIAS | zc bucket create/stat/location/remove ALIAS/BUCKET
    \\       zc object list ALIAS/BUCKET[/PREFIX] [--list-api v2]
    \\Aliases: ls ALIAS[/BUCKET/PREFIX], mb ALIAS/BUCKET, rb ALIAS/BUCKET
    \\Listing: --recursive/-r --prefix TEXT --page-size 1..1000 --summarize
    \\Lists all pages; default delimiter /; recursive lists all matching objects.
    \\JSON is one document. Results spool to disk; page failures emit no partial list.
    \\Safety bounds: 100000 pages, 64 KiB token; repeated tokens fail explicitly.
    \\Remove: --yes required, or --dry-run; empty buckets by default; --force uses version-aware cleanup (pending validation).
    \\Connection overrides: --endpoint --region --bucket-lookup --ca-cert --insecure
    \\  --connect-timeout --timeout --retry-attempts; -H/--header x-amz-NAME:VALUE
    \\For version cleanup options and restrictions, see rb/rm --help.
    \\
;
