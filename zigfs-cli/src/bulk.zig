const std = @import("std");
const aliases = @import("alias.zig");
const api = @import("s3api.zig");
const objects = @import("objects.zig");
const multipart = @import("multipart.zig");
const A = std.mem.Allocator;
const V = std.json.Value;
const Io = std.Io;
extern fn zc_bulk_begin() void;
extern fn zc_bulk_listen() void;
extern fn zc_bulk_end() void;
extern fn zc_interrupted() c_int;
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn isFlag(s: []const u8) bool {
    for ([_][]const u8{ "-r", "--recursive", "--summary", "--continue-on-error", "--fail-empty", "--portable-names", "--versions", "--force", "--dangerous", "--bypass", "--bypass-governance-retention" }) |n| if (eq(s, n)) return true;
    return false;
}
pub fn isValueOption(s: []const u8) bool {
    for ([_][]const u8{ "--include", "--exclude", "--concurrency", "--rate-limit", "--retry-initial-backoff-ms", "--retry-max-backoff-ms", "--page-size" }) |n| if (eq(s, n)) return true;
    return false;
}
pub fn wanted(action: []const u8, args: []const []const u8) bool {
    if (!eq(action, "object copy") and !eq(action, "object move") and !eq(action, "object remove") and !eq(action, "object remove-batch") and !eq(action, "bucket remove")) return false;
    if (eq(action, "object remove-batch")) return true;
    var operands: usize = 0;
    var ended = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!ended and eq(arg, "--")) {
            ended = true;
            continue;
        }
        if (!ended and arg.len > 1 and arg[0] == '-') {
            const split = std.mem.indexOfScalar(u8, arg, '=');
            const n = if (split) |s| arg[0..s] else arg;
            if (isFlag(n) or isValueOption(n)) return true;
            if (split == null and (objects.isValueOption(n) or eq(n, "--header") or eq(n, "-H"))) i += 1;
        } else operands += 1;
    }
    return if (eq(action, "object remove")) operands > 1 else if (eq(action, "object copy") or eq(action, "object move")) operands > 2 else false;
}
const Remote = struct { alias: []const u8, bucket: []const u8, key: []const u8 };
fn remote(path: []const u8) !Remote {
    const at = std.mem.indexOfScalar(u8, path, '/') orelse return error.InvalidInput;
    const rest = path[at + 1 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/');
    if (at == 0 or rest.len == 0) return error.InvalidInput;
    return .{ .alias = path[0..at], .bucket = if (slash) |s| rest[0..s] else rest, .key = if (slash) |s| rest[s + 1 ..] else "" };
}
fn isRemote(a: A, ctx: aliases.Context, config: ?[]const u8, p: []const u8) !bool {
    if (std.mem.startsWith(u8, p, "/") or std.mem.startsWith(u8, p, "./") or std.mem.startsWith(u8, p, "../")) return false;
    const slash = std.mem.indexOfScalar(u8, p, '/') orelse return false;
    _ = aliases.connection(a, ctx, config, p[0..slash], .{}) catch |err| switch (err) {
        error.AliasNotFound, error.InvalidAliasInput => return false,
        else => return err,
    };
    return true;
}
fn put(a: A, v: *V, k: []const u8, s: []const u8) !void {
    try v.object.put(a, k, .{ .string = s });
}
fn target(a: A, r: Remote) !V {
    var v: V = .{ .object = .{} };
    try put(a, &v, "Bucket", r.bucket);
    if (r.key.len > 0) try put(a, &v, "Key", r.key);
    return v;
}
fn text(v: V, k: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(k) orelse return null;
    return if (f == .string) f.string else null;
}
pub fn glob(pattern: []const u8, value: []const u8) bool {
    var p: usize = 0;
    var v: usize = 0;
    var star: ?usize = null;
    var restart: usize = 0;
    while (v < value.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == value[v])) {
            p += 1;
            v += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            restart = v;
        } else if (star) |s| {
            restart += 1;
            v = restart;
            p = s + 1;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}
fn portable(path: []const u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return error.InvalidInput;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |s| {
        if (s.len == 0 or eq(s, ".") or eq(s, "..") or s[s.len - 1] == '.' or s[s.len - 1] == ' ') return error.InvalidInput;
        for (s) |c| if (c < 32 or c >= 127 or std.mem.indexOfScalar(u8, "\\:*?\"<>|", c) != null) return error.InvalidInput;
        const stem = if (std.mem.indexOfScalar(u8, s, '.')) |i| s[0..i] else s;
        for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9" }) |name| if (std.ascii.eqlIgnoreCase(stem, name)) return error.InvalidInput;
    }
}
const Kind = enum { copy, move, remove, batch, abort };
const Job = struct {
    kind: Kind,
    source: []const u8,
    destination: []const u8 = "",
    local_root: ?[]const u8 = null,
    relative: []const u8 = "",
    etag: ?[]const u8 = null,
    bytes: u64 = 0,
    keys: []const []const u8 = &.{},
    upload_id: []const u8 = "",
};
const Options = struct {
    recursive: bool = false,
    dry: bool = false,
    yes: bool = false,
    overwrite: bool = false,
    keep_going: bool = false,
    fail_empty: bool = false,
    portable_names: bool = false,
    force: bool = false,
    dangerous: bool = false,
    explicit: bool = false,
    concurrency: usize = 1,
    page_size: u64 = 1000,
    rate: u64 = 0,
    retries: u32 = 3,
    initial: u32 = 100,
    max: u32 = 1600,
    include: std.ArrayList([]const u8) = .empty,
    exclude: std.ArrayList([]const u8) = .empty,
    pass: std.ArrayList([]const u8) = .empty,
    network: std.ArrayList([]const u8) = .empty,
    operands: std.ArrayList([]const u8) = .empty,
    file: ?[]const u8 = null,
    keys_file: bool = false,
};
fn parse(a: A, args: []const []const u8) !Options {
    var o: Options = .{};
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var ended = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!ended and eq(arg, "--")) {
            ended = true;
            continue;
        }
        if (!ended and arg.len > 1 and arg[0] == '-') {
            const split = std.mem.indexOfScalar(u8, arg, '=');
            const n = if (split) |s| arg[0..s] else arg;
            if (isFlag(n) or objects.isFlag(n)) {
                if (split != null or seen.contains(n)) return error.InvalidInput;
                try seen.put(a, n, {});
                if (isFlag(n)) o.explicit = true;
                if (eq(n, "-r") or eq(n, "--recursive")) o.recursive = true else if (eq(n, "--dry-run")) o.dry = true else if (eq(n, "--yes")) o.yes = true else if (eq(n, "--overwrite")) {
                    o.overwrite = true;
                    try o.pass.append(a, n);
                } else if (eq(n, "--continue-on-error")) o.keep_going = true else if (eq(n, "--fail-empty")) o.fail_empty = true else if (eq(n, "--portable-names")) o.portable_names = true else if (eq(n, "--force")) o.force = true else if (eq(n, "--dangerous")) {
                    o.dangerous = true;
                    o.force = true;
                } else if (eq(n, "--summary")) {} else if (eq(n, "--resume")) return error.UnsupportedOperation else {
                    try o.pass.append(a, n);
                    try o.network.append(a, n);
                }
            } else if (isValueOption(n) or objects.isValueOption(n)) {
                const value = if (split) |s| arg[s + 1 ..] else blk: {
                    i += 1;
                    if (i == args.len) return error.InvalidInput;
                    break :blk args[i];
                };
                if (value.len == 0) return error.InvalidInput;
                if (!eq(n, "--include") and !eq(n, "--exclude") and !eq(n, "--metadata") and !eq(n, "--header") and !eq(n, "-H")) {
                    if (seen.contains(n)) return error.InvalidInput;
                    try seen.put(a, n, {});
                }
                if (isValueOption(n)) o.explicit = true;
                if (eq(n, "--include")) try o.include.append(a, value) else if (eq(n, "--exclude")) try o.exclude.append(a, value) else if (eq(n, "--concurrency")) {
                    const v = try multipart.size(value);
                    if (v > 32) return error.InvalidInput;
                    o.concurrency = @intCast(v);
                } else if (eq(n, "--page-size")) {
                    o.page_size = try multipart.size(value);
                    if (o.page_size > 1000) return error.InvalidInput;
                } else if (eq(n, "--rate-limit")) o.rate = try multipart.size(value) else if (eq(n, "--retry-initial-backoff-ms")) {
                    const v = try multipart.size(value);
                    if (v > 60000) return error.InvalidInput;
                    o.initial = @intCast(v);
                } else if (eq(n, "--retry-max-backoff-ms")) {
                    const v = try multipart.size(value);
                    if (v > 60000) return error.InvalidInput;
                    o.max = @intCast(v);
                } else if (eq(n, "--file") or eq(n, "--keys-file")) {
                    if (o.file != null) return error.InvalidInput;
                    o.file = value;
                    o.keys_file = eq(n, "--keys-file");
                } else {
                    if (eq(n, "--state-file") or eq(n, "--checksum-sha256") or eq(n, "--range") or eq(n, "--offset") or eq(n, "--length")) return error.InvalidInput;
                    if (eq(n, "--retry-attempts")) {
                        const v = try multipart.size(value);
                        if (v > 5) return error.InvalidInput;
                        o.retries = @intCast(v);
                    }
                    try o.pass.appendSlice(a, &.{ n, value });
                    if (api.isValueOption(n)) try o.network.appendSlice(a, &.{ n, value });
                }
            } else return error.InvalidInput;
        } else try o.operands.append(a, arg);
    }
    if (o.rate > std.math.maxInt(i64) or o.max < o.initial or (o.rate > 0 and o.rate < 2 * o.concurrency)) return error.InvalidInput;
    if (o.yes) try o.pass.append(a, "--yes");
    return o;
}
const Plan = struct {
    a: A,
    ctx: aliases.Context,
    config: ?[]const u8,
    o: *Options,
    jobs: std.ArrayList(Job) = .empty,
    used: usize = 0,
    scanned: usize = 0,
    skipped: usize = 0,
    guarded: std.StringHashMapUnmanaged(void) = .empty,
    cause: ?[]const u8 = null,
    cause_code: u8 = 1,
    exact_destination: bool = false,
    fn selected(p: *Plan, name: []const u8) bool {
        for (p.o.exclude.items) |pattern| if (glob(pattern, name)) return false;
        if (p.o.include.items.len == 0) return true;
        for (p.o.include.items) |pattern| if (glob(pattern, name)) return true;
        return false;
    }
    fn add(p: *Plan, j: Job) !void {
        p.used += j.source.len + j.destination.len + j.relative.len + j.upload_id.len + @sizeOf(Job);
        for (j.keys) |k| p.used += k.len;
        if (p.jobs.items.len >= 100000 or p.used > 64 * 1024 * 1024) return error.PlanLimit;
        try p.jobs.append(p.a, j);
    }
    fn wire(p: *Plan, a: A, r: Remote) ![]const []const u8 {
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(a, p.o.network.items);
        try args.append(a, r.alias);
        return args.items;
    }
    fn call(p: *Plan, a: A, op: []const u8, r: Remote, input: V) !V {
        const out = try api.executeInput(a, p.ctx, op, try p.wire(a, r), p.config, true, false, input);
        if (out.exit_code != 0) {
            p.cause = try p.a.dupe(u8, out.stderr);
            p.cause_code = out.exit_code;
            return error.ListFailed;
        }
        return (try std.json.parseFromSlice(V, a, out.stdout, .{})).value.object.get("data").?;
    }
    fn guard(p: *Plan, r: Remote) !void {
        const key = try std.fmt.allocPrint(p.a, "{s}/{s}", .{ r.alias, r.bucket });
        if (p.guarded.contains(key)) return;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const v = (try p.call(a, "get-bucket-versioning", r, try target(a, .{ .alias = r.alias, .bucket = r.bucket, .key = "" }))).object.get("result").?;
        if (!(v == .string and v.string.len == 0) and !(v == .object and v.object.count() == 0)) return error.VersionedBucket;
        try p.guarded.put(p.a, key, {});
    }
    fn remoteTree(p: *Plan, src: []const u8, dst: ?[]const u8, kind: Kind, recursive: bool) !void {
        const r = try remote(src);
        if (kind == .remove or kind == .move or (dst != null and try isRemote(p.a, p.ctx, p.config, dst.?))) try p.guard(r);
        const dest_remote = if (dst) |d| try isRemote(p.a, p.ctx, p.config, d) else false;
        if (dest_remote) {
            const dr = try remote(dst.?);
            if (!eq(r.alias, dr.alias)) return error.UnsupportedOperation;
            try p.guard(dr);
            const prefix = if (r.key.len == 0 or std.mem.endsWith(u8, r.key, "/")) r.key else try std.fmt.allocPrint(p.a, "{s}/", .{r.key});
            if (recursive and eq(r.bucket, dr.bucket) and (std.mem.startsWith(u8, dr.key, prefix) or std.mem.startsWith(u8, prefix, dr.key))) return error.PathConflict;
        }
        if (!recursive) {
            if (r.key.len == 0) return error.InvalidInput;
            const name = std.fs.path.basename(r.key);
            if (!p.selected(name)) {
                p.skipped += 1;
                return;
            }
            try p.mapped(src, dst, name, kind, dest_remote, null, 0);
            return;
        }
        const prefix = if (r.key.len == 0 or std.mem.endsWith(u8, r.key, "/")) r.key else try std.fmt.allocPrint(p.a, "{s}/", .{r.key});
        var token: ?[]u8 = null;
        defer if (token) |t| std.heap.page_allocator.free(t);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        while (true) {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var input = try target(a, .{ .alias = r.alias, .bucket = r.bucket, .key = "" });
            try put(a, &input, "Prefix", prefix);
            try input.object.put(a, "MaxKeys", .{ .integer = @intCast(p.o.page_size) });
            if (token) |t| try put(a, &input, "ContinuationToken", t);
            const result = (try p.call(a, "list-objects-v2", r, input)).object.get("result").?;
            if (result != .object) return error.InvalidResponse;
            if (result.object.get("Contents")) |contents| {
                if (contents != .array) return error.InvalidResponse;
                for (contents.array.items) |item| {
                    p.scanned += 1;
                    if (p.scanned > 100000) return error.PlanLimit;
                    const key = text(item, "Key") orelse return error.InvalidResponse;
                    if (!std.mem.startsWith(u8, key, prefix)) return error.InvalidResponse;
                    const relative = key[prefix.len..];
                    const bytes = std.fmt.parseInt(u64, text(item, "Size") orelse return error.InvalidResponse, 10) catch return error.InvalidResponse;
                    if (!p.selected(relative)) {
                        p.skipped += 1;
                        continue;
                    }
                    if (dst != null and !dest_remote and (relative.len == 0 or std.mem.endsWith(u8, relative, "/"))) {
                        if (bytes != 0) return error.PathConflict;
                        p.skipped += 1;
                        continue;
                    }
                    const source = try std.fmt.allocPrint(p.a, "{s}/{s}/{s}", .{ r.alias, r.bucket, key });
                    const rel = if (r.key.len > 0 and !std.mem.endsWith(u8, r.key, "/")) try std.fmt.allocPrint(p.a, "{s}/{s}", .{ std.fs.path.basename(r.key), relative }) else try p.a.dupe(u8, relative);
                    try p.mapped(source, dst, rel, kind, dest_remote, if (text(item, "ETag")) |e| try p.a.dupe(u8, e) else null, bytes);
                }
            }
            const truncated = text(result, "IsTruncated") orelse return error.InvalidResponse;
            if (eq(truncated, "false")) break;
            if (!eq(truncated, "true")) return error.InvalidResponse;
            const next = text(result, "NextContinuationToken") orelse return error.InvalidResponse;
            if (next.len == 0 or next.len > 65536 or seen.count() >= 100000 or seen.contains(next)) return error.InvalidResponse;
            p.used += next.len;
            if (p.used > 64 * 1024 * 1024) return error.PlanLimit;
            const saved = try p.a.dupe(u8, next);
            try seen.put(p.a, saved, {});
            if (token) |t| std.heap.page_allocator.free(t);
            token = try std.heap.page_allocator.dupe(u8, next);
        }
    }
    fn mapped(p: *Plan, source: []const u8, dst: ?[]const u8, relative: []const u8, kind: Kind, dest_remote: bool, etag: ?[]const u8, bytes: u64) !void {
        if (dst == null) {
            try p.add(.{ .kind = kind, .source = source, .etag = etag, .bytes = bytes });
            return;
        }
        if (dest_remote) {
            if (p.o.portable_names) try portable(relative);
            const d = dst.?;
            const destination = if (p.exact_destination) d else try std.fmt.allocPrint(p.a, "{s}{s}{s}", .{ d, if (std.mem.endsWith(u8, d, "/")) "" else "/", relative });
            if (eq(source, destination)) return error.PathConflict;
            try p.add(.{ .kind = kind, .source = source, .destination = destination, .etag = etag, .bytes = bytes });
        } else {
            const rel = if (p.exact_destination) std.fs.path.basename(dst.?) else relative;
            try portable(rel);
            const root = try Io.Dir.cwd().realPathFileAlloc(p.ctx.io, if (p.exact_destination) std.fs.path.dirname(dst.?) orelse "." else dst.?, p.a);
            try p.add(.{ .kind = kind, .source = source, .destination = try std.fs.path.join(p.a, &.{ root, rel }), .local_root = root, .relative = try p.a.dupe(u8, rel), .etag = etag, .bytes = bytes });
        }
    }
    fn localTree(p: *Plan, source: []const u8, dst: []const u8) !void {
        if (!try isRemote(p.a, p.ctx, p.config, dst)) return error.UnsupportedOperation;
        const stat_path = if (source.len > 1) std.mem.trimEnd(u8, source, "/") else source;
        const stat = try Io.Dir.cwd().statFile(p.ctx.io, stat_path, .{ .follow_symlinks = false });
        if (stat.kind == .sym_link) return error.UnsafePath;
        if (stat.kind == .file) {
            if (!p.selected(std.fs.path.basename(source))) {
                p.skipped += 1;
                return;
            }
            try p.mapped(try Io.Dir.cwd().realPathFileAlloc(p.ctx.io, source, p.a), dst, std.fs.path.basename(source), .copy, true, null, stat.size);
            return;
        }
        if (stat.kind != .directory or !p.o.recursive) return error.InvalidInput;
        const root = try Io.Dir.cwd().realPathFileAlloc(p.ctx.io, source, p.a);
        const name = if (std.mem.endsWith(u8, source, "/")) "" else std.fs.path.basename(root);
        try p.walkLocal(root, "", name, dst, 0);
    }
    fn walkLocal(p: *Plan, root: []const u8, relative: []const u8, name: []const u8, dst: []const u8, depth: usize) !void {
        if (depth > 128) return error.PlanLimit;
        const full = try std.fs.path.join(p.a, &.{ root, relative });
        const dir = try Io.Dir.cwd().openDir(p.ctx.io, full, .{ .iterate = true, .follow_symlinks = false });
        defer dir.close(p.ctx.io);
        var iterator = dir.iterate();
        while (try iterator.next(p.ctx.io)) |entry| {
            p.scanned += 1;
            if (p.scanned > 100000) return error.PlanLimit;
            p.used += 4 * (root.len + relative.len + entry.name.len + 4);
            if (p.used > 64 * 1024 * 1024) return error.PlanLimit;
            const rel = try std.fs.path.join(p.a, &.{ relative, entry.name });
            if (entry.kind == .sym_link) return error.UnsafePath;
            if (entry.kind == .directory) {
                try p.walkLocal(root, rel, name, dst, depth + 1);
                continue;
            }
            if (entry.kind != .file) return error.UnsafePath;
            if (!p.selected(rel)) {
                p.skipped += 1;
                continue;
            }
            const src = try std.fs.path.join(p.a, &.{ root, rel });
            const stat = try dir.statFile(p.ctx.io, entry.name, .{ .follow_symlinks = false });
            if (stat.kind != .file) return error.UnsafePath;
            const mapped_name = if (name.len == 0) rel else try std.fmt.allocPrint(p.a, "{s}/{s}", .{ name, rel });
            try p.mapped(src, dst, mapped_name, .copy, true, null, stat.size);
        }
    }
};
fn secureParent(io: Io, root: []const u8, relative: []const u8, create: bool) !Io.Dir {
    try portable(relative);
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .follow_symlinks = false });
    errdefer dir.close(io);
    var parts = std.mem.splitScalar(u8, relative, '/');
    while (parts.next()) |part| {
        if (parts.peek() == null) break;
        const next = dir.openDir(io, part, .{ .follow_symlinks = false }) catch |err| blk: {
            if (err != error.FileNotFound or !create) return err;
            dir.createDir(io, part, .default_dir) catch |e| if (e != error.PathAlreadyExists) return e;
            break :blk try dir.openDir(io, part, .{ .follow_symlinks = false });
        };
        dir.close(io);
        dir = next;
    }
    return dir;
}
fn validatePlan(p: *Plan) !void {
    var destinations: std.StringHashMapUnmanaged(void) = .empty;
    var sources: std.StringHashMapUnmanaged(void) = .empty;
    for (p.jobs.items) |j| {
        if (j.kind == .abort) continue;
        if (sources.contains(j.source)) return error.PathConflict;
        try sources.put(p.a, j.source, {});
        if (j.destination.len > 0) {
            const key = if (j.local_root != null) try std.ascii.allocLowerString(p.a, j.destination) else j.destination;
            if (destinations.contains(key)) return error.PathConflict;
            try destinations.put(p.a, key, {});
            if (j.local_root) |root| {
                var parent = secureParent(p.ctx.io, root, j.relative, false) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return error.UnsafePath,
                };
                defer parent.close(p.ctx.io);
                const existing = parent.statFile(p.ctx.io, std.fs.path.basename(j.relative), .{ .follow_symlinks = false }) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return err,
                };
                if (existing.kind != .file or !p.o.overwrite) return error.PathConflict;
            }
        }
    }
    for (p.jobs.items) |j| if (j.local_root != null) {
        var parent = std.fs.path.dirname(j.destination);
        while (parent) |path| {
            const key = try std.ascii.allocLowerString(p.a, path);
            if (destinations.contains(key)) return error.PathConflict;
            parent = std.fs.path.dirname(path);
        }
    };
    for (p.jobs.items) |j| if (j.destination.len > 0 and sources.contains(j.destination)) return error.PathConflict;
}
const Result = struct { code: u8 = 0, error_json: []const u8 = "", bytes: u64 = 0, deleted: usize = 0, delete_failed: usize = 0, delete_unknown: usize = 0 };
const Work = struct { ctx: aliases.Context, config: ?[]const u8, job: Job, pass: []const []const u8, network: []const []const u8, result: *Result };
fn worker(w: Work) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const response = perform(a, w) catch |err| blk: {
        const code: u8 = if (err == error.PathAlreadyExists or err == error.PathConflict) 6 else if (err == error.Interrupted or err == error.Canceled) 130 else if (err == error.FileNotFound) 5 else 1;
        break :blk api.Output{ .exit_code = code, .stderr = std.fmt.allocPrint(a, "{{\"schema_version\":1,\"type\":\"error\",\"status\":\"error\",\"error\":{{\"code\":\"LOCAL_ERROR\",\"message\":\"{s}\"}}}}\n", .{@errorName(err)}) catch "" };
    };
    w.result.code = response.exit_code;
    w.result.bytes = if (response.exit_code == 0) w.job.bytes else 0;
    if (response.exit_code == 0 and w.job.local_root != null and response.stdout.len > 0) {
        if (std.json.parseFromSlice(V, a, response.stdout, .{})) |parsed| {
            const data = parsed.value.object.get("data") orelse .null;
            if (data == .object) if (data.object.get("bytes_written")) |count| {
                if (count == .integer and count.integer >= 0) w.result.bytes = @intCast(count.integer);
            };
        } else |_| {}
    }
    if (w.job.kind == .batch) {
        const encoded = if (response.exit_code == 0) response.stdout else response.stderr;
        if (std.json.parseFromSlice(V, a, encoded, .{})) |parsed| {
            const outer = parsed.value.object.get(if (response.exit_code == 0) "data" else "error") orelse .null;
            const result = if (outer == .object) outer.object.get("result") orelse .null else V.null;
            if (result == .object) {
                if (result.object.get("Deleted")) |list| if (list == .array) {
                    w.result.deleted = list.array.items.len;
                };
                if (result.object.get("Error")) |list| if (list == .array) {
                    w.result.delete_failed = list.array.items.len;
                };
            }
        } else |_| {}
        w.result.delete_unknown = w.job.keys.len - @min(w.job.keys.len, w.result.deleted + w.result.delete_failed);
    } else if (w.job.kind == .remove) {
        if (response.exit_code == 0) w.result.deleted = 1 else if (response.exit_code == 3 or response.exit_code == 130) w.result.delete_unknown = 1 else w.result.delete_failed = 1;
    }
    if (response.stderr.len > 0) w.result.error_json = std.heap.page_allocator.dupe(u8, if (response.stderr.len > 1024 * 1024) "{\"error\":{\"code\":\"DETAIL_LIMIT\",\"message\":\"per-operation error detail exceeds 1 MiB\"}}" else response.stderr) catch "";
}
fn perform(a: A, w: Work) !api.Output {
    if (zc_interrupted() != 0) return error.Interrupted;
    const j = w.job;
    if (j.kind == .batch or j.kind == .abort) {
        const r = try remote(j.source);
        var input = try target(a, .{ .alias = r.alias, .bucket = r.bucket, .key = if (j.kind == .abort) r.key else "" });
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(a, w.network);
        try args.appendSlice(a, &.{ r.alias, "--yes" });
        if (j.kind == .abort) try put(a, &input, "UploadId", j.upload_id) else {
            var entries: std.array_list.Managed(V) = .init(a);
            for (j.keys) |key| {
                var item: V = .{ .object = .{} };
                try put(a, &item, "Key", key);
                try entries.append(item);
            }
            var deletion: V = .{ .object = .{} };
            try deletion.object.put(a, "Objects", .{ .array = entries });
            try input.object.put(a, "Delete", deletion);
        }
        return api.executeInput(a, w.ctx, if (j.kind == .batch) "delete-objects" else "abort-multipart-upload", args.items, w.config, true, false, input);
    }
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, w.pass);
    const name = if (j.kind == .copy) "object copy" else if (j.kind == .move) "object move" else "object remove";
    if (j.etag) |etag| if (j.kind == .copy or j.kind == .move) {
        const local = j.local_root != null;
        var has_condition = false;
        for (w.pass) |arg| if (eq(arg, if (local) "--if-match" else "--source-if-match")) {
            has_condition = true;
        };
        if (!has_condition) try args.appendSlice(a, &.{ if (local) "--if-match" else "--source-if-match", etag });
    };
    try args.append(a, "--");
    try args.append(a, j.source);
    if (j.local_root) |root| {
        var dir = try secureParent(w.ctx.io, root, j.relative, true);
        defer dir.close(w.ctx.io);
        try args.append(a, std.fs.path.basename(j.relative));
        return objects.executeAt(a, w.ctx, name, args.items, w.config, true, false, dir);
    }
    if (j.destination.len > 0) try args.append(a, j.destination);
    return objects.execute(a, w.ctx, name, args.items, w.config, true, false);
}
fn errorOutput(a: A, json: bool, code: []const u8, message: []const u8, n: u8, cause: ?[]const u8) !api.Output {
    const body = try std.json.Stringify.valueAlloc(a, .{ .schema_version = 1, .type = "error", .status = "error", .@"error" = .{ .code = code, .message = message, .completed = 0, .cause = if (cause) |c| (std.json.parseFromSlice(V, a, c, .{}) catch return error.InvalidResponse).value else V.null } }, .{ .whitespace = if (json) .minified else .indent_2 });
    return .{ .exit_code = n, .stderr = try std.fmt.allocPrint(a, "{s}\n", .{body}) };
}
pub fn execute(a: A, ctx: aliases.Context, action: []const u8, args: []const []const u8, config: ?[]const u8, json: bool, quiet: bool) anyerror!api.Output {
    if (!eq(action, "object copy") and !eq(action, "object move") and !eq(action, "object remove") and !eq(action, "object remove-batch") and !eq(action, "bucket remove")) return error.InvalidInput;
    var o = try parse(a, args);
    const rb = eq(action, "bucket remove");
    const batch = eq(action, "object remove-batch");
    const remove = eq(action, "object remove");
    const move = eq(action, "object move");
    if (o.operands.items.len == 0 or ((batch or rb) and o.operands.items.len != 1)) return error.InvalidInput;
    if (!rb and (o.force or o.dangerous)) return error.InvalidInput;
    if ((remove or move or batch or rb or o.overwrite) and !o.dry and !o.yes) return error.ConfirmationRequired;
    if ((remove or batch or rb) and o.overwrite) return error.InvalidInput;
    if (rb and (!o.force or o.include.items.len > 0 or o.exclude.items.len > 0 or o.file != null)) return error.InvalidInput;
    if (!batch and o.file != null) return error.InvalidInput;
    if (batch and !o.explicit and o.file != null) {
        const document = (std.json.parseFromSlice(V, a, try Io.Dir.cwd().readFileAlloc(ctx.io, o.file.?, a, .limited(64 * 1024 * 1024)), .{}) catch return error.InvalidInput).value;
        const entries = if (o.keys_file) document else if (document == .object) document.object.get("Objects") orelse return error.InvalidInput else return error.InvalidInput;
        if (entries != .array) return error.InvalidInput;
        if (entries.array.items.len <= 1000) return objects.execute(a, ctx, action, args, config, json, quiet);
    }
    if (rb or batch) {
        var option_index: usize = 0;
        while (option_index < o.pass.items.len) : (option_index += 1) {
            const name = o.pass.items[option_index];
            if (eq(name, "--yes") or eq(name, "--insecure")) continue;
            if (!api.isValueOption(name)) return error.InvalidInput;
            option_index += 1;
        }
    }
    var policy: aliases.RequestPolicy = .{ .retries_left = .init(o.retries - 1), .rate_limit = if (o.rate == 0) 0 else o.rate / (2 * o.concurrency), .initial_backoff = o.initial, .max_backoff = o.max };
    var context = ctx;
    context.policy = &policy;
    zc_bulk_begin();
    zc_bulk_listen();
    defer zc_bulk_end();
    var plan: Plan = .{ .a = a, .ctx = context, .config = config, .o = &o };
    prepare(&plan, action, batch, rb, remove, move, args, json, quiet) catch |err| return errorOutput(a, json, if (zc_interrupted() != 0) "INTERRUPTED" else "PLAN_FAILED", switch (err) {
        error.PathConflict => "source overlap or destination path collision; no mutations were scheduled",
        error.UnsafePath => "symlink, nonregular file or unsafe local path; no mutations were scheduled",
        error.VersionedBucket => "versioned/unknown bucket state; recursive cleanup is unsupported until step 10",
        error.PendingUploads => "unfinished multipart uploads exist; --dangerous is required before any cleanup",
        error.PlanLimit => "plan exceeds 100000 entries or 64 MiB; narrow the source/filter",
        error.UnsupportedOperation => "unsupported direction or options; bulk moves require one remote alias",
        else => "planning or enumeration failed; no mutations were scheduled",
    }, if (zc_interrupted() != 0) 130 else if (plan.cause != null) plan.cause_code else if (err == error.VersionedBucket or err == error.UnsupportedOperation) 7 else if (err == error.PathConflict or err == error.PendingUploads) 6 else if (err == error.InvalidInput or err == error.UnsafePath) 2 else 1, plan.cause);
    validatePlan(&plan) catch return errorOutput(a, json, "PATH_CONFLICT", "unsafe, overlapping or colliding source/destination paths; no mutations were scheduled", 6, null);
    for (plan.jobs.items) |job| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const pa = arena.allocator();
        if (job.kind == .batch or job.kind == .abort) continue;
        var check: std.ArrayList([]const u8) = .empty;
        try check.appendSlice(pa, o.pass.items);
        try check.appendSlice(pa, &.{ "--dry-run", "--", job.source });
        if (job.destination.len > 0) try check.append(pa, job.destination);
        const checked = objects.execute(pa, context, if (job.kind == .copy) "object copy" else if (job.kind == .move) "object move" else "object remove", check.items, config, true, false) catch return errorOutput(a, json, "INVALID_OPTIONS", "operation options or local source are invalid; no mutations were scheduled", 2, null);
        if (checked.exit_code != 0) return errorOutput(a, json, "INVALID_OPTIONS", "operation validation failed; no mutations were scheduled", checked.exit_code, checked.stderr);
    }
    if (o.fail_empty and plan.jobs.items.len == 0) return errorOutput(a, json, "EMPTY_SELECTION", "no matching objects", 5, null);
    if (o.dry) {
        const data = .{ .dry_run = true, .planned = plan.jobs.items.len, .skipped = plan.skipped, .remove_bucket = rb, .jobs = plan.jobs.items };
        const result = try std.json.Stringify.valueAlloc(a, .{ .schema_version = 1, .type = action, .status = "success", .data = data }, .{ .whitespace = if (json) .minified else .indent_2 });
        return .{ .stdout = if (quiet and !json) "" else try std.fmt.allocPrint(a, "{s}\n", .{result}) };
    }
    var completed: usize = 0;
    var failed: usize = 0;
    var scheduled: usize = 0;
    var bytes: u64 = 0;
    var errors: std.array_list.Managed(V) = .init(a);
    var error_bytes: usize = 0;
    var omitted: usize = 0;
    var exit_code: u8 = 0;
    var deleted: usize = 0;
    var delete_failed: usize = 0;
    var delete_unknown: usize = 0;
    while (scheduled < plan.jobs.items.len and zc_interrupted() == 0) {
        const count = @min(o.concurrency, plan.jobs.items.len - scheduled);
        const results = try a.alloc(Result, count);
        @memset(results, .{});
        var group: Io.Group = .init;
        var started: usize = 0;
        for (0..count) |i| {
            group.concurrent(context.io, worker, .{Work{ .ctx = context, .config = config, .job = plan.jobs.items[scheduled + i], .pass = o.pass.items, .network = o.network.items, .result = &results[i] }}) catch {
                results[i].code = 1;
                break;
            };
            started += 1;
        }
        group.await(context.io) catch {
            exit_code = 130;
        };
        if (started == 0) {
            exit_code = 1;
            break;
        }
        for (results[0..started], 0..) |result, i| {
            deleted += result.deleted;
            delete_failed += result.delete_failed;
            delete_unknown += result.delete_unknown;
            if (result.code == 0) {
                completed += 1;
                bytes += result.bytes;
            } else {
                failed += 1;
                if (exit_code == 0) exit_code = result.code;
                if (error_bytes + result.error_json.len < 8 * 1024 * 1024 and errors.items.len < 1000) {
                    var item: V = .{ .object = .{} };
                    try put(a, &item, "source", plan.jobs.items[scheduled + i].source);
                    try put(a, &item, "destination", plan.jobs.items[scheduled + i].destination);
                    try item.object.put(a, "cause", if (result.error_json.len > 0) (std.json.parseFromSlice(V, a, result.error_json, .{ .allocate = .alloc_always }) catch return error.InvalidResponse).value else .null);
                    try errors.append(item);
                    error_bytes += result.error_json.len;
                } else omitted += 1;
            }
            if (result.error_json.len > 0) std.heap.page_allocator.free(result.error_json);
        }
        scheduled += started;
        if (started < count) {
            exit_code = 1;
            break;
        }
        if (exit_code == 130 or (failed > 0 and !o.keep_going)) break;
    }
    var bucket_removed = false;
    if (zc_interrupted() != 0) exit_code = 130;
    if (rb and exit_code == 0 and scheduled == plan.jobs.items.len) {
        const r = try remote(o.operands.items[0]);
        var wire: std.ArrayList([]const u8) = .empty;
        try wire.appendSlice(a, o.network.items);
        try wire.appendSlice(a, &.{ r.alias, "--yes" });
        const outcome = api.executeInput(a, context, "delete-bucket", wire.items, config, true, false, try target(a, r)) catch try errorOutput(a, true, "DELETE_BUCKET_FAILED", "local failure while deleting bucket; cleanup may have partially completed", 1, null);
        if (outcome.exit_code == 0) bucket_removed = true else {
            exit_code = outcome.exit_code;
            try errors.append((try std.json.parseFromSlice(V, a, outcome.stderr, .{})).value);
        }
    }
    const summary = .{ .planned = plan.jobs.items.len, .completed = completed, .failed = failed, .not_started = plan.jobs.items.len - scheduled, .filtered = plan.skipped, .known_object_bytes = bytes, .delete_confirmed = deleted, .delete_failed = delete_failed, .delete_outcome_unknown = delete_unknown, .concurrency = o.concurrency, .retries_used = o.retries - 1 - policy.retries_left.load(.monotonic), .bucket_removed = bucket_removed, .errors = V{ .array = errors }, .errors_omitted = omitted };
    const body = if (exit_code == 0) try std.json.Stringify.valueAlloc(a, .{ .schema_version = 1, .type = action, .status = "success", .data = summary }, .{ .whitespace = if (json) .minified else .indent_2 }) else try std.json.Stringify.valueAlloc(a, .{ .schema_version = 1, .type = "error", .status = "error", .@"error" = .{ .code = if (exit_code == 130) "INTERRUPTED" else "BULK_INCOMPLETE", .message = "batch did not fully complete; inspect known successes and per-operation errors before retrying", .summary = summary } }, .{ .whitespace = if (json) .minified else .indent_2 });
    if (exit_code != 0) return .{ .exit_code = exit_code, .stderr = try std.fmt.allocPrint(a, "{s}\n", .{body}) };
    return .{ .stdout = if (quiet and !json) "" else try std.fmt.allocPrint(a, "{s}\n", .{body}) };
}
fn prepare(p: *Plan, action: []const u8, batch: bool, rb: bool, remove: bool, move: bool, args: []const []const u8, json: bool, quiet: bool) !void {
    _ = action;
    _ = args;
    _ = json;
    _ = quiet;
    const o = p.o;
    if (batch) {
        if (o.recursive or o.include.items.len > 0 or o.exclude.items.len > 0) return error.InvalidInput;
        const r = try remote(o.operands.items[0]);
        if (r.key.len > 0) return error.InvalidInput;
        try p.guard(r);
        const file = o.file orelse return error.InvalidInput;
        const input = (try std.json.parseFromSlice(V, p.a, try Io.Dir.cwd().readFileAlloc(p.ctx.io, file, p.a, .limited(64 * 1024 * 1024)), .{})).value;
        var keys: std.ArrayList([]const u8) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        const entries = if (o.keys_file) input else if (input == .object) input.object.get("Objects") orelse return error.InvalidInput else return error.InvalidInput;
        if (!o.keys_file) {
            var field_it = input.object.iterator();
            while (field_it.next()) |field| if (!eq(field.key_ptr.*, "Objects") and !eq(field.key_ptr.*, "Quiet")) return error.InvalidInput;
            if (input.object.get("Quiet")) |v| if (v != .bool or v.bool) return error.InvalidInput;
        }
        if (entries != .array or entries.array.items.len == 0 or entries.array.items.len > 100000) return error.InvalidInput;
        for (entries.array.items) |entry| {
            const key = if (o.keys_file) if (entry == .string) entry.string else return error.InvalidInput else blk: {
                if (entry != .object or entry.object.count() != 1) return error.InvalidInput;
                break :blk text(entry, "Key") orelse return error.InvalidInput;
            };
            if (seen.contains(key)) return error.InvalidInput;
            try seen.put(p.a, key, {});
            var validation = try target(p.a, .{ .alias = r.alias, .bucket = r.bucket, .key = key });
            try api.validateInput(.@"delete-object", validation);
            _ = &validation;
            try keys.append(p.a, key);
        }
        var at: usize = 0;
        while (at < keys.items.len) {
            const end = @min(at + 1000, keys.items.len);
            // Unique chunk label also avoids treating multiple chunks as duplicate sources.
            try p.add(.{ .kind = .batch, .source = try std.fmt.allocPrint(p.a, "{s}/{s}/chunk-{d}", .{ r.alias, r.bucket, at / 1000 }), .keys = keys.items[at..end] });
            at = end;
        }
        return;
    }
    if (rb) {
        const r = try remote(o.operands.items[0]);
        if (r.key.len > 0) return error.InvalidInput;
        try p.guard(r);
        var listargs: std.ArrayList([]const u8) = .empty;
        try listargs.appendSlice(p.a, o.network.items);
        try listargs.append(p.a, o.operands.items[0]);
        const listed = try multipart.execute(p.a, p.ctx, "multipart list", listargs.items, p.config, true, false);
        if (listed.exit_code != 0) {
            p.cause = listed.stderr;
            p.cause_code = listed.exit_code;
            return error.ListFailed;
        }
        const uploads = (try std.json.parseFromSlice(V, p.a, listed.stdout, .{})).value.object.get("data").?.object.get("items").?;
        if (uploads != .array) return error.InvalidResponse;
        if (uploads.array.items.len > 0 and !o.dangerous) return error.PendingUploads;
        for (uploads.array.items) |upload| {
            const key = text(upload, "Key") orelse return error.InvalidResponse;
            try p.add(.{ .kind = .abort, .source = try std.fmt.allocPrint(p.a, "{s}/{s}/{s}", .{ r.alias, r.bucket, key }), .upload_id = text(upload, "UploadId") orelse return error.InvalidResponse });
        }
        try p.remoteTree(o.operands.items[0], null, .remove, true);
        return;
    }
    if (remove) {
        for (o.operands.items) |src| {
            if (!try isRemote(p.a, p.ctx, p.config, src)) return error.UnsupportedOperation;
            try p.remoteTree(src, null, .remove, o.recursive);
        }
        return;
    }
    if (o.operands.items.len < 2) return error.InvalidInput;
    const sources = o.operands.items[0 .. o.operands.items.len - 1];
    const dest = o.operands.items[o.operands.items.len - 1];
    const dr = try isRemote(p.a, p.ctx, p.config, dest);
    if (move and !dr) return error.UnsupportedOperation;
    if (!dr) {
        const st = Io.Dir.cwd().statFile(p.ctx.io, if (dest.len > 1) std.mem.trimEnd(u8, dest, "/") else dest, .{ .follow_symlinks = false }) catch |err| blk: {
            if (err != error.FileNotFound) return err;
            break :blk null;
        };
        if (st == null or st.?.kind != .directory) {
            if (o.recursive or sources.len > 1) return error.InvalidInput;
            if (st != null and st.?.kind != .file) return error.UnsafePath;
            p.exact_destination = true;
        }
    } else {
        if (!o.recursive and sources.len > 1 and (try remote(dest)).key.len > 0 and !std.mem.endsWith(u8, dest, "/")) return error.InvalidInput;
        p.exact_destination = !o.recursive and sources.len == 1 and (try remote(dest)).key.len > 0 and !std.mem.endsWith(u8, dest, "/");
    }
    for (sources) |src| {
        if (try isRemote(p.a, p.ctx, p.config, src)) {
            try p.remoteTree(src, dest, if (move) .move else .copy, o.recursive);
        } else {
            if (move) return error.UnsupportedOperation;
            try p.localTree(src, dest);
        }
    }
}
test "bulk glob and portable-path rejection" {
    try std.testing.expect(glob("*.txt", "a/b.txt"));
    try std.testing.expect(!glob("a?.txt", "aaa.txt"));
    try std.testing.expectError(error.InvalidInput, portable("../escape"));
    try std.testing.expectError(error.InvalidInput, portable("a//b"));
    try std.testing.expectError(error.InvalidInput, portable("a/CON.txt"));
    try portable("a/file.txt");
}
pub const help =
    \\Bulk cp/mv/rm: --recursive/-r, multiple source operands, --include/--exclude GLOB
    \\--concurrency 1..32 --rate-limit BYTES|KiB|MiB|GiB --retry-attempts 1..5
    \\--retry-initial-backoff-ms N --retry-max-backoff-ms N --continue-on-error
    \\--fail-empty --summary --portable-names --page-size 1..1000 --dry-run
    \\Targets are remote prefixes or existing local directories. Trailing source /
    \\copies contents; otherwise recursive copy nests the source basename.
    \\Moves remain same-alias remote-to-remote. Downloads reject unsafe/non-ASCII
    \\relative paths and symlinks. Local trees must not change during traversal.
    \\Glob * and ? match bytes including /; excludes win; no brace/class syntax.
    \\Planning finishes before mutations; max 100000 entries / 64 MiB plan.
    \\Reads share a command-wide retry budget; mutations never automatically retry.
    \\Rate is split across worker slots and directions; server-side copies have no
    \\client payload bandwidth to throttle. SIGINT stops scheduling and cancels HTTP.
    \\rb --force --yes cleans an unversioned bucket; pending uploads additionally
    \\require --dangerous. Versioned buckets are rejected before any deletion.
    \\remove-batch --file accepts up to 100000 keys, executes chunks of at most 1000.
    \\JSON emits one summary; failures include completed/failed/not-started counts.
    \\
;
