//! Bounded snapshot planning. No writes until both snapshots and all names are valid.
const std = @import("std");
const m = @import("modeled.zig");
const w = @import("wire.zig");
const aliases = @import("alias.zig");
const objects = @import("objects.zig");
const Io = std.Io;
const support = @import("command_support.zig");
const utc = @import("utc_time");
const glob = @import("bulk.zig").glob;
extern fn zc_interrupted() c_int;
extern fn zc_bulk_begin() void;
extern fn zc_bulk_listen() void;
extern fn zc_bulk_end() void;
extern fn zc_regex([*:0]const u8, [*:0]const u8) c_int;
const A = std.mem.Allocator;
const V = std.json.Value;
const Entry = struct {
    name: []const u8,
    size: u64,
    etag: []const u8 = "",
    modified: i64 = 0,
    version_id: ?[]const u8 = null,
    delete_marker: bool = false,
};
const Snapshot = struct {
    root: []const u8,
    remote: ?m.Remote,
    items: std.StringHashMapUnmanaged(Entry) = .empty,
    used: usize = 0,
    fn add(self: *Snapshot, a: A, item: Entry) !void {
        self.used += item.name.len + item.etag.len + @sizeOf(Entry) + if (item.version_id) |id| item.name.len + 1 + id.len else @as(usize, 0);
        const identity = if (item.version_id) |version| try std.fmt.allocPrint(a, "{s}\x00{s}", .{ item.name, version }) else item.name;
        if (self.items.count() >= 100000 or self.used > 64 * 1024 * 1024 or self.items.contains(identity)) return error.InvalidResponse;
        try self.items.put(a, identity, item);
    }
};
fn localWalk(a: A, ctx: aliases.Context, s: *Snapshot, relative: []const u8, depth: usize) anyerror!void {
    if (zc_interrupted() != 0) return error.Interrupted;
    if (depth > 128) return error.InvalidInput;
    const path = try std.fs.path.join(a, &.{ s.root, relative });
    var dir = try Io.Dir.cwd().openDir(ctx.io, path, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(ctx.io);
    var iterator = dir.iterate();
    while (try iterator.next(ctx.io)) |entry| {
        const name = if (relative.len == 0) try a.dupe(u8, entry.name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ relative, entry.name });
        const stat = try dir.statFile(ctx.io, entry.name, .{ .follow_symlinks = false });
        if (stat.kind == .directory) try localWalk(a, ctx, s, name, depth + 1) else if (stat.kind == .file) try s.add(a, .{ .name = name, .size = stat.size, .modified = stat.mtime.toSeconds() }) else return error.InvalidInput;
    }
}
const ScanContext = struct {
    budget: *m.ScanBudget,
    failure: ?w.Output = null,
    fn failed(self: *ScanContext, a: A, out: w.Output, stage: []const u8) !void {
        self.failure = .{
            .exit_code = out.exit_code,
            .stderr = try std.fmt.allocPrint(a, "{s}\n", .{try std.json.Stringify.valueAlloc(a, .{
                .schema_version = 1,
                .type = "scan-error",
                .status = "error",
                .stage = stage,
                .cause = .{ .exit_code = out.exit_code, .stdout = out.stdout, .stderr = out.stderr },
            }, .{})}),
        };
        return error.RemoteScanFailed;
    }
};
fn snapshot(a: A, ctx: aliases.Context, r: m.Args, config: ?[]const u8, target: []const u8, scan: *ScanContext) !Snapshot {
    const explicit_local = std.mem.startsWith(u8, target, "/") or std.mem.startsWith(u8, target, "./") or std.mem.startsWith(u8, target, "../");
    var remote: ?m.Remote = null;
    if (!explicit_local) {
        const candidate = m.remote(target) catch null;
        if (candidate) |c| {
            const conn = aliases.connection(a, ctx, config, c.alias, .{}) catch |err| switch (err) {
                error.AliasNotFound, error.InvalidAliasInput => null,
                else => return err,
            };
            if (conn != null) remote = c;
        }
    }
    var s: Snapshot = .{ .root = target, .remote = remote };
    if (remote) |rem| {
        if (!r.flags.contains("--fallback")) return error.InvalidInput;
        var options = try support.network(a, r, false);
        options.flags = .empty;
        try options.flags.put(a, "--all-pages", {});
        if (r.flags.contains("--insecure")) try options.flags.put(a, "--insecure", {});

        var input: V = .{ .object = .{} };
        try m.put(a, &input, "Bucket", rem.bucket);
        try m.put(a, &input, "Prefix", rem.key orelse "");
        const out = try m.executeInputBudget(a, ctx, if (r.flags.contains("--versions")) "list-object-versions" else "list-objects-v2", options, rem.alias, input, config, true, false, scan.budget);
        if (out.exit_code != 0) try scan.failed(a, out, "snapshot");
        const envelope = (try std.json.parseFromSlice(V, a, out.stdout, .{})).value;
        const pages = m.get(m.get(envelope, "data").?, "pages").?;
        for (pages.array.items) |page| {
            const kinds: []const []const u8 = if (r.flags.contains("--versions")) &.{ "Versions", "DeleteMarkers" } else &.{"Contents"};
            for (kinds) |kind| {
                const contents = m.get(page, kind) orelse continue;
                if (contents != .array) return error.InvalidResponse;
                for (contents.array.items) |item| {
                    const key = m.text(item, "Key") orelse return error.InvalidResponse;
                    const prefix = rem.key orelse "";
                    if (!std.mem.startsWith(u8, key, prefix)) return error.InvalidResponse;
                    const marker = w.eq(kind, "DeleteMarkers");
                    const size = m.get(item, "Size") orelse V{ .integer = 0 };
                    if (size != .integer or size.integer < 0) return error.InvalidResponse;
                    const modified = try utc.parseIso8601(m.text(item, "LastModified") orelse return error.InvalidResponse);
                    try s.add(a, .{
                        .name = key[prefix.len..],
                        .size = @intCast(size.integer),
                        .etag = m.text(item, "ETag") orelse "",
                        .modified = modified,
                        .version_id = if (r.flags.contains("--versions")) m.text(item, "VersionId") orelse return error.InvalidResponse else null,
                        .delete_marker = marker,
                    });
                }
            }
        }
    } else {
        if (r.flags.contains("--versions") or r.flags.contains("--incomplete")) return error.InvalidInput;
        try localWalk(a, ctx, &s, "", 0);
        try scan.budget.charge(s.items.count(), s.used);
    }
    return s;
}
fn less(_: void, x: Entry, y: Entry) bool {
    return std.mem.lessThan(u8, x.name, y.name);
}
fn full(a: A, s: Snapshot, name: []const u8) ![]const u8 {
    if (s.remote) |r| return std.fmt.allocPrint(a, "{s}/{s}/{s}{s}", .{ r.alias, r.bucket, r.key orelse "", name });
    return std.fs.path.join(a, &.{ s.root, name });
}
fn safeName(name: []const u8) !void {
    if (name.len == 0 or name[0] == '/' or std.mem.indexOfScalar(u8, name, '\\') != null or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidInput;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |p| if (p.len == 0 or w.eq(p, ".") or w.eq(p, "..")) return error.InvalidInput;
}
fn localParent(ctx: aliases.Context, s: Snapshot, name: []const u8, create: bool) !Io.Dir {
    var dir = try Io.Dir.cwd().openDir(ctx.io, s.root, .{ .follow_symlinks = false });
    errdefer dir.close(ctx.io);
    const parent = std.fs.path.dirname(name) orelse return dir;
    var parts = std.mem.splitScalar(u8, parent, '/');
    while (parts.next()) |part| {
        const next = dir.openDir(ctx.io, part, .{ .follow_symlinks = false }) catch |err| blk: {
            if (err != error.FileNotFound or !create) return err;
            try dir.createDir(ctx.io, part, .default_dir);
            break :blk try dir.openDir(ctx.io, part, .{ .follow_symlinks = false });
        };
        dir.close(ctx.io);
        dir = next;
    }
    return dir;
}
fn executeOnce(a: A, ctx: aliases.Context, action: []const u8, args: []const []const u8, config: ?[]const u8, json: bool, quiet: bool) anyerror!w.Output {
    var budget: m.ScanBudget = .{};
    return executeBudget(a, ctx, action, args, config, json, quiet, &budget);
}
fn executeBudget(a: A, ctx: aliases.Context, action: []const u8, args: []const []const u8, config: ?[]const u8, json: bool, quiet: bool, budget: *m.ScanBudget) anyerror!w.Output {
    var scan: ScanContext = .{ .budget = budget };
    return executeScan(a, ctx, action, args, config, json, quiet, &scan) catch |err| {
        if (scan.failure) |out| return out;
        return err;
    };
}
fn executeScan(a: A, ctx: aliases.Context, action: []const u8, args: []const []const u8, config: ?[]const u8, json: bool, quiet: bool, scan: *ScanContext) anyerror!w.Output {
    const r = try m.parse(a, args);
    const compare = w.eq(action, "diff") or w.eq(action, "mirror");
    if (r.operands.items.len != @as(usize, if (compare) 2 else 1)) return error.InvalidInput;
    var flags = r.flags.keyIterator();
    while (flags.next()) |flag| {
        var ok = false;
        for ([_][]const u8{ "--fallback", "--yes", "--dry-run", "--remove", "--overwrite", "--insecure", "--versions", "--incomplete", "--recursive", "-r", "--size-only", "--ignore-times" }) |n| if (w.eq(flag.*, n)) {
            ok = true;
            break;
        };
        if (!ok) return error.InvalidInput;
    }
    try support.check(r, &.{ "--name", "--min-size", "--max-size", "--newer", "--older", "--regex", "--max-depth", "--level", "--include", "--exclude" }, &.{ "--fallback", "--remove", "--overwrite", "--versions", "--incomplete", "--recursive", "-r", "--size-only", "--ignore-times" });
    if (compare and (r.flags.contains("--versions") or r.flags.contains("--incomplete"))) return error.InvalidInput;
    if (!w.eq(action, "du") and r.flags.contains("--incomplete")) return error.InvalidInput;
    if (!w.eq(action, "tree") and r.values.contains("--level")) return error.InvalidInput;
    if (r.values.get("--regex")) |pattern| {
        if (zc_regex(try a.dupeSentinel(u8, pattern, 0), "") < 0) return error.InvalidInput;
    }
    if (!w.eq(action, "mirror") and (r.flags.contains("--yes") or r.flags.contains("--remove") or r.flags.contains("--overwrite"))) return error.InvalidInput;
    if (r.headers.items.len != 0) return error.InvalidInput;
    const source = try snapshot(a, ctx, r, config, r.operands.items[0], scan);
    var list: std.ArrayList(Entry) = .empty;
    var iter = source.items.valueIterator();
    var total: u64 = 0;
    while (iter.next()) |entry| {
        if (!try selected(a, ctx, r, entry.*)) continue;
        try list.append(a, entry.*);
        total = try std.math.add(u64, total, entry.size);
    }
    std.mem.sort(Entry, list.items, {}, less);
    if (w.eq(action, "tree")) return tree(a, r, list.items, json, quiet);
    if (!compare) {
        const pending = if (r.flags.contains("--incomplete")) try incomplete(a, ctx, r, config, source.remote orelse return error.InvalidInput, scan) else Pending{};
        return w.output(a, json, quiet, action, .{
            .source = if (source.remote != null) (if (r.flags.contains("--versions")) "s3-list-object-versions" else "s3-list-objects-v2") else "local-scan",
            .complete = true,
            .observed_at = Io.Clock.real.now(ctx.io).toSeconds(),
            .count = list.items.len,
            .bytes = total,
            .incomplete_uploads = pending.uploads,
            .incomplete_bytes = pending.bytes,
            .total_bytes = try std.math.add(u64, total, pending.bytes),
            .entries = if (w.eq(action, "du")) &.{} else list.items,
        });
    }
    const destination = try snapshot(a, ctx, r, config, r.operands.items[1], scan);
    if (source.remote == null and destination.remote == null) return error.UnsupportedOperation;
    if (source.remote) |sr| if (destination.remote) |dr| {
        if (!w.eq(sr.alias, dr.alias)) return error.UnsupportedOperation;
        if (w.eq(sr.bucket, dr.bucket) and (std.mem.startsWith(u8, sr.key orelse "", dr.key orelse "") or std.mem.startsWith(u8, dr.key orelse "", sr.key orelse ""))) return error.InvalidInput;
    };
    var changes: std.ArrayList(Change) = .empty;
    // Cross local/S3 size equality is not content equality: conservatively copy.
    for (list.items) |entry| {
        try safeName(entry.name);
        const old = destination.items.get(entry.name);
        if (old) |v| if (same(r, source, destination, entry, v)) {
            continue;
        };
        try changes.append(a, .{ .kind = if (old == null) "add" else "replace", .name = entry.name, .source = try full(a, source, entry.name), .target = try full(a, destination, entry.name) });
    }
    var dest_iter = destination.items.valueIterator();
    while (dest_iter.next()) |entry| {
        if (!try selected(a, ctx, r, entry.*)) continue;
        try safeName(entry.name);
        if (!source.items.contains(entry.name)) try changes.append(a, .{ .kind = "delete", .name = entry.name, .source = "", .target = try full(a, destination, entry.name) });
    }
    if (w.eq(action, "diff") or r.flags.contains("--dry-run")) return w.output(a, json, quiet, action, .{ .dry_run = true, .comparison = "same-instance size+ETag; local/remote conservatively copies", .delete_enabled = r.flags.contains("--remove"), .changes = changes.items });
    if (!r.flags.contains("--yes")) return error.ConfirmationRequired;
    for (changes.items) |change| if (w.eq(change.kind, "replace") and !r.flags.contains("--overwrite")) return error.ConfirmationRequired;
    var progress: support.Progress = .{};
    for (changes.items) |change| {
        if (!w.eq(change.kind, "delete") or r.flags.contains("--remove")) progress.planned += 1;
    }
    return applyMirror(a, ctx, r, source, destination, changes.items, config, json, quiet, &progress) catch |err| {
        return progress.failure(a, json, "mirror", try support.localFailure(a, err));
    };
}
const Change = struct { kind: []const u8, name: []const u8, source: []const u8, target: []const u8 };
fn applyMirror(a: A, ctx: aliases.Context, r: m.Args, source: Snapshot, destination: Snapshot, changes: []const Change, config: ?[]const u8, json: bool, quiet: bool, progress: *support.Progress) !w.Output {
    // A copy failure returns immediately, so the deletion phase is never entered.
    for (changes) |change| {
        if (w.eq(change.kind, "delete")) continue;
        progress.stage = "copy";
        progress.item = change.target;
        if (zc_interrupted() != 0) return error.Interrupted;
        var options: std.ArrayList([]const u8) = .empty;
        try options.appendSlice(a, try transferOptions(a, r));
        if (w.eq(change.kind, "replace")) try options.append(a, "--overwrite");
        if (source.remote != null) {
            const item = source.items.get(change.name).?;
            if (item.etag.len == 0) return error.InvalidResponse;
            try options.appendSlice(a, &.{ if (destination.remote == null) "--if-match" else "--source-if-match", item.etag });
        }
        if (destination.remote == null) {
            var parent = try localParent(ctx, destination, change.name, true);
            defer parent.close(ctx.io);
            try options.appendSlice(a, &.{ "--", change.source, std.fs.path.basename(change.name) });
            progress.attempted = true;
            const out = try objects.executeAt(a, ctx, "object get", options.items, config, json, false, parent);
            if (out.exit_code != 0) return progress.failure(a, json, "mirror", out);
        } else {
            try options.appendSlice(a, &.{ "--", change.source, change.target });
            progress.attempted = true;
            const out = try objects.execute(a, ctx, "object copy", options.items, config, json, false);
            if (out.exit_code != 0) return progress.failure(a, json, "mirror", out);
        }
        progress.copied += 1;
        progress.attempted = false;
    }
    if (r.flags.contains("--remove")) for (changes) |change| {
        if (!w.eq(change.kind, "delete")) continue;
        progress.stage = "delete";
        progress.item = change.target;
        if (zc_interrupted() != 0) return error.Interrupted;
        if (destination.remote != null) {
            var options: std.ArrayList([]const u8) = .empty;
            try options.appendSlice(a, try transferOptions(a, r));
            try options.appendSlice(a, &.{ "--", change.target });
            progress.attempted = true;
            const out = try objects.execute(a, ctx, "object remove", options.items, config, json, false);
            if (out.exit_code != 0) return progress.failure(a, json, "mirror", out);
        } else {
            var parent = try localParent(ctx, destination, change.name, false);
            defer parent.close(ctx.io);
            const stat = try parent.statFile(ctx.io, std.fs.path.basename(change.name), .{ .follow_symlinks = false });
            if (stat.kind != .file or stat.size != destination.items.get(change.name).?.size) return error.InvalidInput;
            progress.attempted = true;
            try parent.deleteFile(ctx.io, std.fs.path.basename(change.name));
        }
        progress.removed += 1;
        progress.attempted = false;
    };
    return w.output(a, json, quiet, "mirror", .{ .copied = progress.copied, .removed = progress.removed });
}
/// Every mutation uses the same S3 overrides as the snapshots that planned it.
fn transferOptions(a: A, r: m.Args) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    for (support.connection_options) |name| {
        if (w.eq(name, "--management-endpoint") or w.eq(name, "--token-file")) continue;
        if (r.values.get(name)) |value| try args.appendSlice(a, &.{ name, value });
    }
    if (r.flags.contains("--insecure")) try args.append(a, "--insecure");
    try args.append(a, "--yes");
    return args.items;
}
fn selected(a: A, ctx: aliases.Context, r: m.Args, entry: Entry) !bool {
    return try selectedMetadata(a, ctx, r, entry) and try selectedSize(r, entry.size);
}
fn selectedMetadata(a: A, ctx: aliases.Context, r: m.Args, entry: Entry) !bool {
    for (support.values(r, "--exclude")) |pattern| if (glob(pattern, entry.name)) return false;
    const includes = support.values(r, "--include");
    if (includes.len > 0) {
        var matches = false;
        for (includes) |pattern| if (glob(pattern, entry.name)) {
            matches = true;
            break;
        };
        if (!matches) return false;
    }
    if (r.values.get("--name")) |pattern| if (!glob(pattern, std.fs.path.basename(entry.name))) return false;
    if (r.values.get("--regex")) |pattern| {
        const matched = zc_regex(try a.dupeSentinel(u8, pattern, 0), try a.dupeSentinel(u8, entry.name, 0));
        if (matched < 0) return error.InvalidInput;
        if (matched == 0) return false;
    }
    const age = Io.Clock.real.now(ctx.io).toSeconds() - entry.modified;
    if (r.values.get("--newer")) |span| if (age > try support.duration(span)) return false;
    if (r.values.get("--older")) |span| if (age < try support.duration(span)) return false;
    if (r.values.get("--max-depth")) |text| {
        const limit = try std.fmt.parseInt(usize, text, 10);
        if (std.mem.count(u8, entry.name, "/") + 1 > limit) return false;
    }
    return true;
}
fn selectedSize(r: m.Args, size: u64) !bool {
    if (r.values.get("--min-size")) |text| if (size < try @import("multipart.zig").size(text)) return false;
    if (r.values.get("--max-size")) |text| if (size > try @import("multipart.zig").size(text)) return false;
    return true;
}
fn same(r: m.Args, source: Snapshot, destination: Snapshot, left: Entry, right: Entry) bool {
    if (left.size != right.size) return false;
    if (r.flags.contains("--size-only")) return true;
    if (r.flags.contains("--ignore-times")) return false;
    if (source.remote != null and destination.remote != null) return left.etag.len > 0 and w.eq(left.etag, right.etag);
    // Filesystem mtimes are not trustworthy content hashes; copy conservatively.
    return false;
}
const TreeNode = struct {
    name: []const u8,
    objects: std.ArrayList(Entry) = .empty,
    children: std.ArrayList(*TreeNode) = .empty,
    by_name: std.StringHashMapUnmanaged(*TreeNode) = .empty,
    hidden: usize = 0,
};
fn treeValue(a: A, node: *TreeNode) anyerror!V {
    var value = support.object();
    try m.put(a, &value, "name", node.name);
    var children = support.array(a);
    for (node.children.items) |child| try children.array.append(try treeValue(a, child));
    try value.object.put(a, "children", children);
    const objects_json = try std.json.Stringify.valueAlloc(a, node.objects.items, .{});
    try value.object.put(a, "objects", (try std.json.parseFromSlice(V, a, objects_json, .{})).value);
    try value.object.put(a, "hidden_descendants", .{ .integer = @intCast(node.hidden) });
    return value;
}
fn tree(a: A, r: m.Args, entries: []const Entry, json: bool, quiet: bool) !w.Output {
    const level = if (r.values.get("--level")) |text| try std.fmt.parseInt(usize, text, 10) else 128;
    if (level == 0 or level > 128) return error.InvalidInput;
    var root: TreeNode = .{ .name = "" };
    var nodes: usize = 1;
    var truncated = false;
    for (entries) |entry| {
        var current = &root;
        var parts = std.mem.splitScalar(u8, entry.name, '/');
        var depth: usize = 0;
        while (parts.next()) |part| {
            if (depth == level) {
                current.hidden += 1;
                truncated = true;
                break;
            }
            depth += 1;
            const slot = try current.by_name.getOrPut(a, part);
            if (!slot.found_existing) {
                nodes += 1;
                if (nodes > 200000) return error.InvalidResponse;
                const child = try a.create(TreeNode);
                child.* = .{ .name = part };
                slot.value_ptr.* = child;
                try current.children.append(a, child);
            }
            current = slot.value_ptr.*;
            if (parts.peek() == null) try current.objects.append(a, entry);
        }
    }
    return w.output(a, json, quiet, "tree", .{ .tree = try treeValue(a, &root), .count = entries.len, .level = level, .complete = true, .view_truncated = truncated });
}
const Pending = struct { uploads: usize = 0, bytes: u64 = 0 };
fn incomplete(a: A, ctx: aliases.Context, r: m.Args, config: ?[]const u8, remote: m.Remote, scan: *ScanContext) !Pending {
    const prefix: []const u8 = remote.key orelse "";
    var options = try support.network(a, r, false);
    try options.flags.put(a, "--all-pages", {});
    var input = support.object();
    try m.put(a, &input, "Bucket", remote.bucket);
    try m.put(a, &input, "Prefix", prefix);
    const out = try m.executeInputBudget(a, ctx, "list-multipart-uploads", options, remote.alias, input, config, true, false, scan.budget);
    if (out.exit_code != 0) try scan.failed(a, out, "list-multipart-uploads");
    const envelope = (try std.json.parseFromSlice(V, a, out.stdout, .{})).value;
    const pages = m.get(m.get(envelope, "data").?, "pages").?;
    var result: Pending = .{};
    for (pages.array.items) |page| if (m.get(page, "Uploads")) |uploads| {
        for (uploads.array.items) |upload| {
            const key = m.text(upload, "Key") orelse return error.InvalidResponse;
            if (!std.mem.startsWith(u8, key, prefix)) return error.InvalidResponse;
            const entry: Entry = .{
                .name = key[prefix.len..],
                .size = 0,
                .modified = try utc.parseIso8601(m.text(upload, "Initiated") orelse return error.InvalidResponse),
            };
            if (!try selectedMetadata(a, ctx, r, entry)) continue;
            var upload_bytes: u64 = 0;
            // A fresh arena per upload bounds memory independently of the part count.
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const pa = arena.allocator();
            var part_input = support.object();
            try m.put(pa, &part_input, "Bucket", remote.bucket);
            try m.put(pa, &part_input, "Key", key);
            try m.put(pa, &part_input, "UploadId", m.text(upload, "UploadId") orelse return error.InvalidResponse);
            const listed = try m.executeInputBudget(pa, ctx, "list-parts", options, remote.alias, part_input, config, true, false, scan.budget);
            if (listed.exit_code != 0) try scan.failed(a, listed, "list-parts");
            const decoded = (try std.json.parseFromSlice(V, pa, listed.stdout, .{})).value;
            for (m.get(m.get(decoded, "data").?, "pages").?.array.items) |part_page| if (m.get(part_page, "Parts")) |parts| {
                for (parts.array.items) |part| {
                    const size = m.get(part, "Size") orelse return error.InvalidResponse;
                    if (size != .integer or size.integer < 0) return error.InvalidResponse;
                    upload_bytes = try std.math.add(u64, upload_bytes, @intCast(size.integer));
                }
            };
            if (!try selectedSize(r, upload_bytes)) continue;
            result.uploads += 1;
            result.bytes = try std.math.add(u64, result.bytes, upload_bytes);
        }
    };
    return result;
}
/// Continuous mirroring re-evaluates complete snapshots. It is explicitly not an event stream.
pub fn execute(a: A, ctx: aliases.Context, action: []const u8, args: []const []const u8, config: ?[]const u8, json: bool, quiet: bool) anyerror!w.Output {
    zc_bulk_begin();
    zc_bulk_listen();
    defer zc_bulk_end();
    const r = try m.parse(a, args);
    if (w.eq(action, "du")) return usage(a, ctx, r, args, config, json, quiet);
    if (!r.flags.contains("--watch")) return executeOnce(a, ctx, action, args, config, json, quiet);
    if (!w.eq(action, "mirror") or r.flags.contains("--dry-run")) return error.InvalidInput;
    try support.mutation(r);
    const interval = try std.fmt.parseInt(u32, r.values.get("--interval") orelse "5", 10);
    if (interval == 0 or interval > 3600) return error.InvalidInput;
    var forwarded: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    var ended = false;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (w.eq(arg, "--")) ended = true;
        if (!ended and w.eq(arg, "--watch")) continue;
        if (!ended and w.eq(arg, "--interval")) {
            index += 1;
            continue;
        }
        if (!ended and std.mem.startsWith(u8, arg, "--interval=")) continue;
        try forwarded.append(a, arg);
    }
    while (zc_interrupted() == 0) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const out = try executeOnce(arena.allocator(), ctx, action, forwarded.items, config, true, false);
        if (out.exit_code != 0) return .{ .exit_code = out.exit_code, .stderr = try a.dupe(u8, out.stderr) };
        if (!quiet or json) try Io.File.stdout().writeStreamingAll(ctx.io, out.stdout);
        var tick: u32 = 0;
        while (tick < interval and zc_interrupted() == 0) : (tick += 1) try Io.sleep(ctx.io, .fromSeconds(1), .awake);
    }
    return .{ .exit_code = 130 };
}
fn usage(a: A, ctx: aliases.Context, r: m.Args, args: []const []const u8, config: ?[]const u8, json: bool, quiet: bool) !w.Output {
    if (r.operands.items.len != 1) return error.InvalidInput;
    try support.check(r, &.{ "--name", "--min-size", "--max-size", "--newer", "--older", "--regex", "--max-depth", "--include", "--exclude" }, &.{ "--fallback", "--versions", "--incomplete" });
    const target = r.operands.items[0];
    var service = std.mem.indexOfScalar(u8, target, '/') == null;
    if (service) {
        const conn = aliases.connection(a, ctx, config, target, .{}) catch |err| switch (err) {
            error.AliasNotFound, error.InvalidAliasInput => null,
            else => return err,
        };
        service = conn != null;
    }
    const remote = if (service) null else m.remote(target) catch null;
    const local = std.mem.startsWith(u8, target, "/") or std.mem.startsWith(u8, target, "./") or std.mem.startsWith(u8, target, "../");
    var filtered = false;
    var keys = r.values.keyIterator();
    while (keys.next()) |key| if (!support.contains(&support.connection_options, key.*)) {
        filtered = true;
    };
    const full_bucket = remote != null and (remote.?.key == null or remote.?.key.?.len == 0);
    if (!local and (service or full_bucket) and !filtered and !r.flags.contains("--versions") and !r.flags.contains("--incomplete")) {
        const operands: []const []const u8 = if (service) &.{target} else &.{ remote.?.alias, remote.?.bucket };
        const out = @import("management.zig").execute(a, ctx, if (service) "admin storage info" else "admin bucket usage get", try support.arguments(a, r, operands, false), config, true, false) catch |err| blk: {
            if (!r.flags.contains("--fallback")) return err;
            break :blk w.Output{ .exit_code = 7 };
        };
        if (out.exit_code == 0) return w.output(a, json, quiet, "du", .{ .source = "management-snapshot", .observed_at = Io.Clock.real.now(ctx.io).toSeconds(), .snapshot_time = @as(?i64, null), .usage = try support.result(a, out) });
        if (!r.flags.contains("--fallback")) return out;
    }
    if (!service) return executeOnce(a, ctx, "du", args, config, json, quiet);
    if (!r.flags.contains("--fallback")) return error.InvalidInput;
    var options = try support.network(a, r, false);
    try options.flags.put(a, "--all-pages", {});
    var budget: m.ScanBudget = .{};
    const listed = try m.executeInputBudget(a, ctx, "list-buckets", options, target, support.object(), config, true, false, &budget);
    if (listed.exit_code != 0) return listed;
    const envelope = (try std.json.parseFromSlice(V, a, listed.stdout, .{})).value;
    var buckets = support.array(a);
    var total: u64 = 0;
    for (m.get(m.get(envelope, "data").?, "pages").?.array.items) |page| if (m.get(page, "Buckets")) |items| {
        for (items.array.items) |bucket| {
            const name = m.text(bucket, "Name") orelse return error.InvalidResponse;
            if (buckets.array.items.len >= 10000) return error.ScanLimitExceeded;
            var bucket_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer bucket_arena.deinit();
            const ba = bucket_arena.allocator();
            const child_target = try std.fmt.allocPrint(ba, "{s}/{s}", .{ target, name });
            const child_args = try support.allArguments(ba, r, &.{child_target});
            const out = try executeBudget(ba, ctx, "du", child_args, config, true, false, &budget);
            if (out.exit_code != 0) return support.ownOutput(a, out);
            // du returns only totals; retain those, never the bucket's full snapshot.
            const value = (try std.json.parseFromSlice(V, a, out.stdout, .{ .allocate = .alloc_always })).value;
            const data = m.get(value, "data").?;
            const bytes = m.get(data, "total_bytes").?;
            if (bytes != .integer or bytes.integer < 0) return error.InvalidResponse;
            total = try std.math.add(u64, total, @intCast(bytes.integer));
            var item = support.object();
            try m.put(a, &item, "bucket", name);
            try item.object.put(a, "usage", data);
            try buckets.array.append(item);
            if (buckets.array.items.len > 10000) return error.InvalidResponse;
        }
    };
    return w.output(a, json, quiet, "du", .{ .source = "service-scan", .observed_at = Io.Clock.real.now(ctx.io).toSeconds(), .bytes = total, .buckets = buckets, .scanned_records = budget.records, .scanned_payload_bytes = budget.bytes, .complete = true });
}
