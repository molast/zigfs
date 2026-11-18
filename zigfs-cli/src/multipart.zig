const std = @import("std");
const api = @import("s3api.zig");
const aliases = @import("alias.zig");
const signing = @import("signing.zig");
const A = std.mem.Allocator;
const V = std.json.Value;
const Io = std.Io;
const Map = std.StringHashMapUnmanaged([]const u8);
const private_mode: Io.File.Permissions = @fromBackingInt(0o600);
const mib = 1024 * 1024;
pub fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn isFlag(n: []const u8) bool {
    return eq(n, "--yes") or eq(n, "--dry-run") or eq(n, "--insecure") or eq(n, "--overwrite") or eq(n, "--resume");
}
pub fn isValueOption(n: []const u8) bool {
    for ([_][]const u8{ "--if-match", "--if-none-match", "--upload-id", "--part-number", "--body", "--file", "--page-size", "--prefix", "--content-type", "--metadata", "--multipart-threshold", "--part-size", "--part-concurrency", "--max-parts", "--state-file" }) |f| if (eq(n, f)) return true;
    return api.isValueOption(n) and !eq(n, "--input-json") and !eq(n, "--output");
}
pub fn size(text: []const u8) !u64 {
    var raw = text;
    var scale: u64 = 1;
    inline for (.{ .{ "KiB", @as(u64, 1024) }, .{ "MiB", @as(u64, mib) }, .{ "GiB", @as(u64, 1024 * mib) } }) |suffix| {
        if (std.mem.endsWith(u8, text, suffix[0])) {
            raw = text[0 .. text.len - suffix[0].len];
            scale = suffix[1];
        }
    }
    const value = std.fmt.parseInt(u64, raw, 10) catch return error.InvalidInput;
    if (value == 0) return error.InvalidInput;
    return std.math.mul(u64, value, scale) catch return error.InvalidInput;
}
fn put(a: A, v: *V, k: []const u8, s: []const u8) !void {
    try v.object.put(a, k, .{ .string = s });
}
fn integer(a: A, v: *V, k: []const u8, n: u64) !void {
    try v.object.put(a, k, .{ .integer = @intCast(n) });
}
fn str(v: V, k: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(k) orelse return null;
    return if (f == .string) f.string else null;
}
fn numeric(v: V, k: []const u8) !u64 {
    const f = if (v == .object) v.object.get(k) orelse return error.InvalidResponse else return error.InvalidResponse;
    return switch (f) {
        .integer => if (f.integer >= 0) @intCast(f.integer) else error.InvalidResponse,
        .string => std.fmt.parseInt(u64, f.string, 10) catch error.InvalidResponse,
        else => error.InvalidResponse,
    };
}
const Remote = struct { alias: []const u8, bucket: []const u8, key: []const u8 };
fn remote(path: []const u8, bucket_only: bool) !Remote {
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return error.InvalidInput;
    const rest = path[slash + 1 ..];
    const cut = std.mem.indexOfScalar(u8, rest, '/');
    if (slash == 0 or rest.len == 0 or (bucket_only and cut != null) or (!bucket_only and (cut == null or cut.? + 1 == rest.len))) return error.InvalidInput;
    return .{ .alias = path[0..slash], .bucket = if (cut) |c| rest[0..c] else rest, .key = if (cut) |c| rest[c + 1 ..] else "" };
}
fn target(a: A, r: Remote) !V {
    var v: V = .{ .object = .{} };
    try put(a, &v, "Bucket", r.bucket);
    if (r.key.len > 0) try put(a, &v, "Key", r.key);
    return v;
}
fn clone(a: A, v: V) !V {
    return (try std.json.parseFromSlice(V, a, try std.json.Stringify.valueAlloc(a, v, .{}), .{ .allocate = .alloc_always })).value;
}
const Reply = union(enum) { ok: V, failed: api.Output };
fn request(a: A, ctx: aliases.Context, op: []const u8, args: []const []const u8, config: ?[]const u8, input: V, transfer: api.TransferOptions) !Reply {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const pa = arena.allocator();
    const response = try api.executeTransfer(pa, ctx, op, args, config, true, false, input, transfer);
    if (response.exit_code != 0) return .{ .failed = .{ .exit_code = response.exit_code, .stderr = try a.dupe(u8, response.stderr) } };
    const envelope = (try std.json.parseFromSlice(V, a, response.stdout, .{ .allocate = .alloc_always })).value;
    return .{ .ok = envelope.object.get("data").? };
}
fn output(a: A, json: bool, quiet: bool, kind: []const u8, value: V) !api.Output {
    if (quiet and !json) return .{};
    const bytes = if (json) try std.json.Stringify.valueAlloc(a, .{ .schema_version = 1, .type = kind, .status = "success", .data = value }, .{}) else try std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2 });
    return .{ .stdout = try std.fmt.allocPrint(a, "{s}\n", .{bytes}) };
}
fn fail(a: A, json: bool, code: []const u8, message: []const u8, n: u8) !api.Output {
    return .{ .exit_code = n, .stderr = try std.fmt.allocPrint(a, "{s}\n", .{if (json) try std.json.Stringify.valueAlloc(a, .{ .schema_version = 1, .type = "error", .status = "error", .@"error" = .{ .code = code, .message = message } }, .{}) else try std.fmt.allocPrint(a, "zc: {s}: {s}", .{ code, message })}) };
}
fn forward(a: A, json: bool, r: api.Output) !api.Output {
    if (json) return r;
    return .{ .exit_code = r.exit_code, .stderr = try std.fmt.allocPrint(a, "zc: multipart request failed\n{s}", .{r.stderr}) };
}
fn connectionArgs(a: A, r: Remote, values: Map, initial: []const []const u8) !std.ArrayList([]const u8) {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, initial);
    var it = values.iterator();
    while (it.next()) |e| {
        if (api.isValueOption(e.key_ptr.*) and !eq(e.key_ptr.*, "--body") and !eq(e.key_ptr.*, "--input-json") and !eq(e.key_ptr.*, "--output")) try args.appendSlice(a, &.{ e.key_ptr.*, e.value_ptr.* });
    }
    try args.append(a, r.alias);
    return args;
}
fn allPages(a: A, ctx: aliases.Context, op: []const u8, args: []const []const u8, config: ?[]const u8, base: V, page_size: u64) !Reply {
    const parts = eq(op, "list-parts");
    var input = try clone(a, base);
    try integer(a, &input, if (parts) "MaxParts" else "MaxUploads", page_size);
    var items: std.array_list.Managed(V) = .init(a);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var pages: u64 = 0;
    var total: usize = 0;
    while (true) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const pa = arena.allocator();
        const reply = try request(pa, ctx, op, args, config, input, .{});
        if (reply == .failed) return .{ .failed = .{ .exit_code = reply.failed.exit_code, .stderr = try a.dupe(u8, reply.failed.stderr) } };
        const result = reply.ok.object.get("result").?;
        if (result != .object) return error.InvalidResponse;
        const bytes = try std.json.Stringify.valueAlloc(pa, result, .{});
        total += bytes.len;
        pages += 1;
        if (total > 16 * mib or pages > 10000) return error.InvalidResponse;
        if (result.object.get(if (parts) "Part" else "Upload")) |entries| {
            if (entries != .array) return error.InvalidResponse;
            for (entries.array.items) |item| try items.append(try clone(a, item));
        }
        const truncated = str(result, "IsTruncated") orelse return error.InvalidResponse;
        if (eq(truncated, "false")) break;
        if (!eq(truncated, "true")) return error.InvalidResponse;
        const marker = if (parts) str(result, "NextPartNumberMarker") orelse return error.InvalidResponse else str(result, "NextKeyMarker") orelse return error.InvalidResponse;
        const upload = if (parts) "" else str(result, "NextUploadIdMarker") orelse return error.InvalidResponse;
        const key = try std.json.Stringify.valueAlloc(a, .{ marker, upload }, .{});
        if (seen.contains(key)) return error.InvalidResponse;
        try seen.put(a, key, {});
        if (parts) {
            const n = std.fmt.parseInt(u64, marker, 10) catch return error.InvalidResponse;
            if (n == 0 or n > 10000) return error.InvalidResponse;
            try integer(a, &input, "PartNumberMarker", n);
        } else {
            try put(a, &input, "KeyMarker", try a.dupe(u8, marker));
            try put(a, &input, "UploadIdMarker", try a.dupe(u8, upload));
        }
    }
    var result: V = .{ .object = .{} };
    try result.object.put(a, "items", .{ .array = items });
    try integer(a, &result, "pages", pages);
    try result.object.put(a, "complete", .{ .bool = true });
    return .{ .ok = result };
}
pub fn execute(a: A, ctx: aliases.Context, action: []const u8, args: []const []const u8, config: ?[]const u8, json: bool, quiet: bool) anyerror!api.Output {
    var values: Map = .empty;
    var flags: std.StringHashMapUnmanaged(void) = .empty;
    var initial: std.ArrayList([]const u8) = .empty;
    var operand: ?[]const u8 = null;
    var metadata: V = .{ .object = .{} };
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
            if (values.contains(n) or flags.contains(n)) return error.InvalidInput;
            if (isFlag(n)) {
                if (split != null) return error.InvalidInput;
                try flags.put(a, n, {});
                if (eq(n, "--insecure")) try initial.append(a, n);
            } else if (isValueOption(n)) {
                const v = if (split) |s| arg[s + 1 ..] else blk: {
                    i += 1;
                    if (i == args.len) return error.InvalidInput;
                    break :blk args[i];
                };
                if (v.len == 0) return error.InvalidInput;
                if (eq(n, "--header") or eq(n, "-H")) try initial.appendSlice(a, &.{ n, v }) else if (eq(n, "--metadata")) {
                    const at = std.mem.indexOfScalar(u8, v, '=') orelse return error.InvalidInput;
                    const key = try std.ascii.allocLowerString(a, v[0..at]);
                    if (metadata.object.contains(key)) return error.InvalidInput;
                    try put(a, &metadata, key, v[at + 1 ..]);
                } else try values.put(a, n, v);
            } else return error.InvalidInput;
        } else {
            if (operand != null) return error.InvalidInput;
            operand = arg;
        }
    }
    if (eq(action, "pipe")) return autoUpload(a, ctx, null, operand orelse return error.InvalidInput, initial.items, values, flags, metadata, config, json, quiet);
    const list = eq(action, "multipart list");
    const parts = eq(action, "multipart parts");
    const create = eq(action, "multipart create");
    const complete = eq(action, "multipart complete");
    const upload = eq(action, "multipart upload-part");
    const r = try remote(operand orelse return error.InvalidInput, list);
    const op = if (list) "list-multipart-uploads" else if (parts) "list-parts" else if (create) "create-multipart-upload" else if (complete) "complete-multipart-upload" else if (upload) "upload-part" else "abort-multipart-upload";
    var input = try target(a, r);
    var it = values.iterator();
    while (it.next()) |e| {
        const n = e.key_ptr.*;
        const v = e.value_ptr.*;
        if (eq(n, "--if-match") and complete) try put(a, &input, "IfMatch", v) else if (eq(n, "--if-none-match") and complete) try put(a, &input, "IfNoneMatch", v) else if (eq(n, "--upload-id") and !list and !create) try put(a, &input, "UploadId", v) else if (eq(n, "--part-number") and upload) try integer(a, &input, "PartNumber", try size(v)) else if (eq(n, "--content-type") and create) try put(a, &input, "ContentType", v) else if (eq(n, "--prefix") and list) try put(a, &input, "Prefix", v) else if ((eq(n, "--page-size") and (list or parts)) or (eq(n, "--file") and complete) or (eq(n, "--body") and upload)) {} else if (!api.isValueOption(n) or eq(n, "--body")) return error.InvalidInput;
    }
    if (metadata.object.count() > 0) {
        if (!create) return error.InvalidInput;
        try input.object.put(a, "Metadata", metadata);
    }
    if (flags.contains("--resume") or flags.contains("--overwrite")) return error.InvalidInput;
    if (complete) {
        const path = values.get("--file") orelse return error.InvalidInput;
        const bytes = try Io.Dir.cwd().readFileAlloc(ctx.io, path, a, .limited(2 * mib));
        try input.object.put(a, "MultipartUpload", (std.json.parseFromSlice(V, a, bytes, .{}) catch return error.InvalidInput).value);
    }
    try api.validateInput(std.meta.stringToEnum(api.Operation, op).?, input);
    if (!list and !parts and !create and !flags.contains("--yes") and !flags.contains("--dry-run")) return error.ConfirmationRequired;
    if (upload and !values.contains("--body")) return error.InvalidInput;
    if (flags.contains("--dry-run")) {
        try input.object.put(a, "dry_run", .{ .bool = true });
        return output(a, json, quiet, action, input);
    }
    var wire = try connectionArgs(a, r, values, initial.items);
    if (list or parts) {
        if (flags.contains("--yes")) return error.InvalidInput;
        const page = if (values.get("--page-size")) |v| try size(v) else 1000;
        if (page > 1000) return error.InvalidInput;
        const reply = try allPages(a, ctx, op, wire.items, config, input, page);
        return switch (reply) {
            .failed => |f| forward(a, json, f),
            .ok => |v| output(a, json, quiet, action, v),
        };
    }
    try wire.append(a, "--yes");
    if (upload) try wire.appendSlice(a, &.{ "--body", values.get("--body").? });
    const reply = try request(a, ctx, op, wire.items, config, input, .{});
    return switch (reply) {
        .failed => |f| forward(a, json, f),
        .ok => |v| output(a, json, quiet, action, v),
    };
}
fn fileHash(a: A, io: Io, path: []const u8) ![]const u8 {
    const f = try Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const stat = try f.stat(io);
    if (stat.kind != .file) return error.InvalidInput;
    @import("progress.zig").zc_progress_stage("Verifying source", stat.size);
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [65536]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try f.readPositionalAll(io, &buffer, offset);
        if (n == 0) break;
        sha.update(buffer[0..n]);
        offset += n;
        @import("progress.zig").zc_progress_update(offset);
    }
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}
fn sourceInfo(a: A, io: Io, path: []const u8, part_size: u64, expected_length: u64) !struct { hash: []const u8, parts: [][]const u8 } {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    @import("progress.zig").zc_progress_stage("Hashing source", expected_length);
    var whole = std.crypto.hash.sha2.Sha256.init(.{});
    var part = std.crypto.hash.sha2.Sha256.init(.{});
    var hashes: std.ArrayList([]const u8) = .empty;
    var offset: u64 = 0;
    var part_bytes: u64 = 0;
    var buffer: [65536]u8 = undefined;
    while (offset < expected_length) {
        const n = try file.readPositionalAll(io, buffer[0..@min(buffer.len, part_size - part_bytes, expected_length - offset)], offset);
        if (n == 0) break;
        whole.update(buffer[0..n]);
        part.update(buffer[0..n]);
        offset += n;
        part_bytes += n;
        @import("progress.zig").zc_progress_update(offset);
        if (part_bytes == part_size) {
            var digest: [32]u8 = undefined;
            part.final(&digest);
            try hashes.append(a, try a.dupe(u8, &std.fmt.bytesToHex(digest, .lower)));
            part = .init(.{});
            part_bytes = 0;
        }
    }
    if (offset != expected_length) return error.ResumeMismatch;
    if (part_bytes > 0 or hashes.items.len == 0) {
        var digest: [32]u8 = undefined;
        part.final(&digest);
        try hashes.append(a, try a.dupe(u8, &std.fmt.bytesToHex(digest, .lower)));
    }
    var digest: [32]u8 = undefined;
    whole.final(&digest);
    return .{ .hash = try a.dupe(u8, &std.fmt.bytesToHex(digest, .lower)), .parts = hashes.items };
}
fn save(a: A, io: Io, path: []const u8, state: V, replace: bool) !void {
    var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{ .permissions = private_mode, .replace = replace });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, try std.json.Stringify.valueAlloc(a, state, .{}));
    try atomic.file.sync(io);
    if (replace) try atomic.replace(io) else try atomic.link(io);
}
fn pending(a: A, json: bool, state: V, path: ?[]const u8, cause: ?api.Output, phase: []const u8) !api.Output {
    const detail = if (cause) |c| (try std.json.parseFromSlice(V, a, c.stderr, .{})).value else V.null;
    const message = "multipart operation incomplete; retain checkpoint; inspect upload/parts before retry; completion is never blindly retried";
    const value = .{ .schema_version = 1, .type = "error", .status = "error", .@"error" = .{ .code = "MULTIPART_INCOMPLETE", .message = message, .phase = phase, .upload_id = str(state, "upload_id"), .state_file = path, .cause = detail } };
    return .{ .exit_code = if (cause) |c| c.exit_code else 1, .stderr = try std.fmt.allocPrint(a, "{s}\n", .{try std.json.Stringify.valueAlloc(a, value, .{ .whitespace = if (json) .minified else .indent_2 })}) };
}
// Each worker owns its arena. Only the coordinator publishes checkpoints, in
// part-number order, after draining every in-flight request in the bounded wave.
const PartWork = struct {
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    ctx: aliases.Context,
    config: ?[]const u8,
    base: V,
    args: []const []const u8,
    source: []const u8,
    number: u64,
    offset: u64,
    length: u64,
    sha256: []const u8,
    lanes: u32,
    progress: ?*anyopaque,
    reply: ?Reply = null,
};

fn uploadPartWorker(work: *PartWork) void {
    @import("progress.zig").zc_progress_object_attach(work.progress, work.number);
    defer @import("progress.zig").zc_progress_object_attach(null, 0);
    work.reply = uploadFilePart(work) catch null;
}

fn uploadFilePart(work: *PartWork) !Reply {
    const a = work.arena.allocator();
    var input = try clone(a, work.base);
    try integer(a, &input, "PartNumber", work.number);
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, work.args);
    try args.appendSlice(a, &.{ "--body", work.source });
    return request(a, work.ctx, "upload-part", args.items, work.config, input, .{
        .body_offset = work.offset,
        .body_length = work.length,
        .expected_body_sha256 = work.sha256,
        .rate_limit_divisor = work.lanes,
    });
}

pub fn autoUpload(a: A, ctx: aliases.Context, source: ?[]const u8, remote_path: []const u8, initial: []const []const u8, values: Map, flags: std.StringHashMapUnmanaged(void), metadata: V, config: ?[]const u8, json: bool, quiet: bool) anyerror!api.Output {
    const r = try remote(remote_path, false);
    if (source == null and (flags.contains("--resume") or values.contains("--state-file") or values.contains("--multipart-threshold"))) return error.InvalidInput;
    if (flags.contains("--overwrite") and !flags.contains("--yes")) return error.ConfirmationRequired;
    if (flags.contains("--overwrite") and values.contains("--if-none-match")) return error.InvalidInput;
    if (!flags.contains("--overwrite") and values.contains("--if-match")) return error.InvalidInput;
    if (values.get("--if-none-match")) |v| if (!eq(v, "*")) return error.InvalidInput;
    var publication: V = .{ .object = .{} };
    if (!flags.contains("--overwrite")) try put(a, &publication, "IfNoneMatch", "*");
    if (values.get("--if-match")) |v| try put(a, &publication, "IfMatch", v);
    var create = try target(a, r);
    var it = values.iterator();
    while (it.next()) |e| {
        const n = e.key_ptr.*;
        if (eq(n, "--content-type")) try put(a, &create, "ContentType", e.value_ptr.*) else if (eq(n, "--part-size") or eq(n, "--part-concurrency") or eq(n, "--max-parts") or eq(n, "--multipart-threshold") or eq(n, "--state-file") or eq(n, "--if-match") or eq(n, "--if-none-match")) {} else if (!api.isValueOption(n) or eq(n, "--body") or eq(n, "--file")) return error.UnsupportedOperation;
    }
    if (metadata.object.count() > 0) try create.object.put(a, "Metadata", metadata);
    try api.validateInput(.@"create-multipart-upload", create);
    const path = if (source) |p| try Io.Dir.cwd().realPathFileAlloc(ctx.io, p, a) else null;
    const length: u64 = if (path) |p| blk: {
        const stat = try Io.Dir.cwd().statFile(ctx.io, p, .{});
        if (stat.kind != .file) return error.InvalidInput;
        break :blk stat.size;
    } else 0;
    const max_parts = if (values.get("--max-parts")) |v| try size(v) else 10000;
    const plan = try @import("upload_policy.zig").choose(length, max_parts);
    var part_size = if (values.get("--part-size")) |v| try size(v) else plan.part_size;
    // Resume must use the persisted layout, even after client defaults change.
    // The checkpoint is re-read and validated under its exclusive lock below.
    if (flags.contains("--resume") and !values.contains("--part-size")) {
        const checkpoint = values.get("--state-file") orelse try std.fmt.allocPrint(a, "{s}.zc-upload.json", .{path.?});
        const previous = Io.Dir.cwd().openFile(ctx.io, checkpoint, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (previous) |file| {
            defer file.close(ctx.io);
            const stat = try file.stat(ctx.io);
            if (stat.kind != .file or stat.size > 4 * mib) return error.InvalidInput;
            if (@backingInt(stat.permissions) & 0o077 != 0) return error.InsecurePermissions;
            const bytes = try a.alloc(u8, @intCast(stat.size));
            if (try file.readPositionalAll(ctx.io, bytes, 0) != bytes.len) return error.InvalidInput;
            const saved = (try std.json.parseFromSlice(V, a, bytes, .{})).value;
            if (saved != .object) return error.InvalidInput;
            part_size = try numeric(saved.object.get("identity") orelse return error.InvalidInput, "part_size");
        }
    }
    if (part_size < 5 * mib or part_size > 5 * 1024 * mib) return error.InvalidInput;
    const cpu_limit = std.Thread.getCpuCount() catch 1;
    const shared_budget = if (ctx.policy) |policy|
        (if (policy.part_lanes == 0) cpu_limit else policy.part_lanes)
    else
        cpu_limit;
    const limit = @min(4, cpu_limit, shared_budget);
    const requested_lanes = if (values.get("--part-concurrency")) |v| try size(v) else @min(plan.concurrency, limit);
    if (requested_lanes > limit) return error.ConcurrencyLimit;
    const lanes: usize = @intCast(requested_lanes);
    if (length > 5 * 1024 * 1024 * mib or (length + part_size - 1) / part_size > max_parts) return error.InvalidInput;
    if (flags.contains("--dry-run")) {
        try create.object.put(a, "dry_run", .{ .bool = true });
        try integer(a, &create, "part_size", part_size);
        try create.object.put(a, "publication", publication);
        return output(a, json, quiet, "multipart upload", create);
    }
    var wire = try connectionArgs(a, r, values, initial);
    const read_args_len = wire.items.len;
    try wire.append(a, "--yes");
    const state_path = if (path) |p| values.get("--state-file") orelse try std.fmt.allocPrint(a, "{s}.zc-upload.json", .{p}) else null;
    var lock: ?Io.File = null;
    defer if (lock) |f| f.close(ctx.io);
    var state: V = .{ .object = .{} };
    var exists = false;
    var replace_completed = false;
    const conn = try aliases.connection(a, ctx, config, r.alias, .{ .endpoint = values.get("--endpoint"), .region = values.get("--region") });
    const source_info = if (path) |p| try sourceInfo(a, ctx.io, p, part_size, length) else null;
    const digest = if (source_info) |info| info.hash else "";
    var identity: V = .{ .object = .{} };
    try put(a, &identity, "endpoint", conn.endpoint);
    try put(a, &identity, "region", conn.region);
    try put(a, &identity, "access_key_hash", &signing.hash(conn.access_key));
    try put(a, &identity, "source", path orelse "stdin");
    try put(a, &identity, "sha256", digest);
    try integer(a, &identity, "size", length);
    try integer(a, &identity, "part_size", part_size);
    try integer(a, &identity, "max_parts", max_parts);
    try identity.object.put(a, "request", create);
    try identity.object.put(a, "publication", publication);
    try put(a, &identity, "headers_hash", &signing.hash(try std.json.Stringify.valueAlloc(a, initial, .{})));
    const fingerprint = &signing.hash(try std.json.Stringify.valueAlloc(a, identity, .{}));
    if (state_path) |p| {
        // State must never replace the source file, including an alternate spelling.
        const parent = std.fs.path.dirname(p) orelse ".";
        const real_parent = try Io.Dir.cwd().realPathFileAlloc(ctx.io, parent, a);
        const canonical = try std.fs.path.join(a, &.{ real_parent, std.fs.path.basename(p) });
        if (eq(canonical, path.?)) return error.InvalidInput;
        const lock_path = try std.fmt.allocPrint(a, "{s}.lock", .{p});
        lock = Io.Dir.cwd().openFile(ctx.io, lock_path, .{ .mode = .read_write, .follow_symlinks = false, .lock = .exclusive, .lock_nonblocking = true }) catch |err| switch (err) {
            error.FileNotFound => try Io.Dir.cwd().createFile(ctx.io, lock_path, .{ .exclusive = true, .permissions = private_mode, .lock = .exclusive, .lock_nonblocking = true }),
            else => return err,
        };
        if ((try lock.?.stat(ctx.io)).kind != .file) return error.InvalidInput;
        const file = Io.Dir.cwd().openFile(ctx.io, p, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (file) |f| {
            defer f.close(ctx.io);
            exists = true;
            const stat = try f.stat(ctx.io);
            if (@backingInt(stat.permissions) & 0o077 != 0) return error.InsecurePermissions;
            if (stat.kind != .file or stat.size > 4 * mib) return error.InvalidInput;
            const bytes = try a.alloc(u8, @intCast(stat.size));
            if (try f.readPositionalAll(ctx.io, bytes, 0) != bytes.len) return error.InvalidInput;
            state = (std.json.parseFromSlice(V, a, bytes, .{}) catch return error.InvalidInput).value;
            if (try numeric(state, "schema_version") != 1) return error.InvalidInput;
            if (!flags.contains("--resume")) {
                const previous_identity = state.object.get("identity") orelse V.null;
                const previous_parts = state.object.get("parts") orelse V.null;
                const reusable = !values.contains("--state-file") and
                    eq(str(state, "phase") orelse "", "completed") and
                    eq(str(previous_identity, "source") orelse "", path.?) and
                    str(state, "upload_id") != null and previous_parts == .array;
                if (!reusable) {
                    return fail(a, json, "CHECKPOINT_EXISTS", "local multipart checkpoint already exists, not the remote object; use --resume for an uploading checkpoint or --state-file NEW_PATH for a new transfer", 6);
                }
                // Completion was acknowledged and durably recorded. Start a new
                // upload under the same lock, atomically replacing only this
                // default sidecar. Unknown outcomes and explicit files stay intact.
                state = .{ .object = .{} };
                exists = false;
                replace_completed = true;
            } else {
                if (!eq(str(state, "fingerprint") orelse "", fingerprint)) return error.ResumeMismatch;
                if (!eq(str(state, "phase") orelse "", "uploading")) return fail(a, json, "RESUME_UNSAFE", "checkpoint is creating/completing/completed; inspect remote outcome instead of automatically retrying", 6);
                if (str(state, "upload_id") == null or state.object.get("parts") == null or state.object.get("parts").? != .array) return error.InvalidInput;
            }
        }
    }
    if (!exists) {
        try integer(a, &state, "schema_version", 1);
        try put(a, &state, "fingerprint", fingerprint);
        try state.object.put(a, "identity", identity);
        try put(a, &state, "phase", "creating");
        try state.object.put(a, "parts", .{ .array = std.array_list.Managed(V).init(a) });
        if (state_path) |p| try save(a, ctx.io, p, state, replace_completed);
        const created = request(a, ctx, "create-multipart-upload", wire.items, config, create, .{}) catch return pending(a, json, state, state_path, null, "create");
        if (created == .failed) return pending(a, json, state, state_path, created.failed, "create");
        try put(a, &state, "upload_id", str(created.ok.object.get("result").?, "UploadId") orelse return error.InvalidResponse);
        try put(a, &state, "phase", "uploading");
        if (state_path) |p| try save(a, ctx.io, p, state, true);
    }
    const id = str(state, "upload_id").?;
    var base = try target(a, r);
    try put(a, &base, "UploadId", id);
    var recorded = state.object.getPtr("parts").?;
    if (recorded.array.items.len > max_parts or recorded.array.items.len > @max(1, (length + part_size - 1) / part_size)) return error.InvalidInput;
    if (recorded.array.items.len > 0) {
        var check = try clone(a, base);
        var layout: V = .{ .object = .{} };
        try layout.object.put(a, "Parts", recorded.*);
        try check.object.put(a, "MultipartUpload", layout);
        try api.validateInput(.@"complete-multipart-upload", check);
    }
    if (exists) {
        const listed = try allPages(a, ctx, "list-parts", wire.items[0..read_args_len], config, base, 1000);
        if (listed == .failed) return pending(a, json, state, state_path, listed.failed, "list-parts");
        const server = listed.ok.object.get("items").?.array.items;
        var previous_number: u64 = 0;
        for (server) |part| {
            const n = try numeric(part, "PartNumber");
            if (n <= previous_number or n > max_parts or n > @max(1, (length + part_size - 1) / part_size)) return error.ResumeMismatch;
            previous_number = n;
        }
        for (recorded.array.items, 0..) |part, index| {
            if (try numeric(part, "PartNumber") != index + 1) return error.ResumeMismatch;
            var found = false;
            for (server) |actual| if (try numeric(actual, "PartNumber") == index + 1) {
                if (!eq(str(part, "ETag") orelse "", str(actual, "ETag") orelse "") or try numeric(actual, "Size") != @min(part_size, length - index * part_size)) return error.ResumeMismatch;
                found = true;
                break;
            };
            if (!found) return error.ResumeMismatch;
        }
    }
    const progress = @import("progress.zig");
    const object_progress = if (path != null)
        progress.zc_progress_object_begin(length, @min(length, recorded.array.items.len * part_size), @max(1, (length + part_size - 1) / part_size))
    else
        null;
    defer progress.zc_progress_object_end(object_progress);
    if (path) |source_path| {
        const part_count = @max(1, (length + part_size - 1) / part_size);
        while (recorded.array.items.len < part_count) {
            const first = recorded.array.items.len + 1;
            const count: usize = @intCast(@min(lanes, part_count - first + 1));
            var work: [4]PartWork = undefined;
            for (work[0..count], 0..) |*item, index| {
                const number = first + index;
                const offset = (number - 1) * part_size;
                item.* = .{
                    .ctx = ctx,
                    .config = config,
                    .base = base,
                    .args = wire.items,
                    .source = source_path,
                    .number = number,
                    .offset = offset,
                    .length = @min(part_size, length - offset),
                    .sha256 = source_info.?.parts[number - 1],
                    .lanes = @intCast(count),
                    .progress = object_progress,
                };
            }
            defer for (work[0..count]) |*item| item.arena.deinit();
            var group: Io.Group = .init;
            defer group.cancel(ctx.io);
            for (work[0..count]) |*item| {
                if (count == 1) {
                    uploadPartWorker(item);
                } else {
                    group.concurrent(ctx.io, uploadPartWorker, .{item}) catch break;
                }
            }
            // Await all workers before reading their arenas or allowing resume.
            group.await(ctx.io) catch return error.Interrupted;
            progress.zc_progress_object_attach(object_progress, 0);
            for (work[0..count]) |*item| {
                const uploaded = item.reply orelse return pending(a, json, state, state_path, null, "upload-part");
                if (uploaded == .failed) return pending(a, json, state, state_path, uploaded.failed, "upload-part");
                var part: V = .{ .object = .{} };
                try integer(a, &part, "PartNumber", item.number);
                try put(a, &part, "ETag", try a.dupe(u8, str(uploaded.ok.object.get("headers").?, "etag") orelse return error.InvalidResponse));
                try recorded.array.append(part);
                if (state_path) |checkpoint| try save(a, ctx.io, checkpoint, state, true);
            }
        }
    }
    var part_number: u64 = recorded.array.items.len + 1;
    var pipe_file: ?Io.File = null;
    var pipe_path: ?[]const u8 = null;
    defer if (pipe_file) |f| f.close(ctx.io);
    defer if (pipe_path) |p| Io.Dir.cwd().deleteFile(ctx.io, p) catch {};
    if (source == null) {
        const tmp = ctx.env.get("TMPDIR") orelse "/tmp";
        var random: [16]u8 = undefined;
        ctx.io.random(&random);
        pipe_path = try std.fmt.allocPrint(a, "{s}/zc-pipe-{s}.part", .{ tmp, std.fmt.bytesToHex(random, .lower) });
        pipe_file = Io.Dir.cwd().createFile(ctx.io, pipe_path.?, .{ .read = true, .exclusive = true, .permissions = private_mode }) catch return pending(a, json, state, state_path, null, "stdin-temp-file");
    }
    defer @import("progress.zig").zc_progress_part(0, 0, 0, 0);
    while (path == null) : (part_number += 1) {
        var count: u64 = 0;
        if (source == null) {
            @import("progress.zig").zc_progress_stage("Reading stdin", 0);
            pipe_file.?.setLength(ctx.io, 0) catch return pending(a, json, state, state_path, null, "stdin-temp-file");
            var buffer: [65536]u8 = undefined;
            while (count < part_size) {
                const n = Io.File.stdin().readStreaming(ctx.io, &.{buffer[0..@min(buffer.len, part_size - count)]}) catch |err| switch (err) {
                    error.EndOfStream => 0,
                    else => return pending(a, json, state, state_path, null, "stdin"),
                };
                if (n == 0) break;
                pipe_file.?.writePositionalAll(ctx.io, buffer[0..n], count) catch return pending(a, json, state, state_path, null, "stdin-temp-file");
                count += n;
            }
            if (count == 0 and part_number > 1) break;
        } else {
            const offset = (part_number - 1) * part_size;
            if (offset >= length and part_number > 1) break;
            count = @min(part_size, length - offset);
        }
        @import("progress.zig").zc_progress_part(part_number, if (path != null) @max(1, (length + part_size - 1) / part_size) else 0, (part_number - 1) * part_size, length);
        if (part_number > max_parts or (part_number - 1) * part_size + count > 5 * 1024 * 1024 * mib) return pending(a, json, state, state_path, null, "part-limit");
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const pa = arena.allocator();
        var input = try clone(pa, base);
        try integer(pa, &input, "PartNumber", part_number);
        var part_args: std.ArrayList([]const u8) = .empty;
        try part_args.appendSlice(pa, wire.items);
        try part_args.appendSlice(pa, &.{ "--body", path orelse pipe_path.? });
        const uploaded = request(pa, ctx, "upload-part", part_args.items, config, input, .{ .body_offset = if (path != null) (part_number - 1) * part_size else 0, .body_length = count, .expected_body_sha256 = if (source_info) |info| if (part_number <= info.parts.len) info.parts[@intCast(part_number - 1)] else return error.ResumeMismatch else null }) catch return pending(a, json, state, state_path, null, "upload-part");
        if (uploaded == .failed) return pending(a, json, state, state_path, uploaded.failed, "upload-part");
        var part: V = .{ .object = .{} };
        try integer(a, &part, "PartNumber", part_number);
        try put(a, &part, "ETag", try a.dupe(u8, str(uploaded.ok.object.get("headers").?, "etag") orelse return error.InvalidResponse));
        try recorded.array.append(part);
        if (state_path) |p| try save(pa, ctx.io, p, state, true);
        if (source == null and count < part_size) break;
    }
    if (path) |p| if (!eq(try fileHash(a, ctx.io, p), digest)) return error.ResumeMismatch;
    var complete = try clone(a, base);
    var parts: V = .{ .object = .{} };
    try parts.object.put(a, "Parts", recorded.*);
    try complete.object.put(a, "MultipartUpload", parts);
    var conditions = publication.object.iterator();
    while (conditions.next()) |entry| try complete.object.put(a, entry.key_ptr.*, entry.value_ptr.*);
    try put(a, &state, "phase", "completing");
    if (state_path) |p| try save(a, ctx.io, p, state, true);
    const done = request(a, ctx, "complete-multipart-upload", wire.items, config, complete, .{}) catch return pending(a, json, state, state_path, null, "complete");
    if (done == .failed) return pending(a, json, state, state_path, done.failed, "complete");
    try put(a, &state, "phase", "completed");
    if (state_path) |p| try save(a, ctx.io, p, state, true);
    var result = done.ok;
    try put(a, &result, "upload_id", id);
    try result.object.put(a, "state_file", if (state_path) |p| .{ .string = p } else .null);
    try integer(a, &result, "parts_uploaded", recorded.array.items.len);
    return output(a, json, quiet, if (source == null) "pipe" else "multipart upload", result);
}
pub const help =
    \\zc multipart create OBJECT [--content-type TYPE --metadata KEY=VALUE]
    \\zc multipart upload-part OBJECT --upload-id ID --part-number N --body FILE --yes
    \\zc multipart parts OBJECT --upload-id ID [--page-size 1..1000]
    \\zc multipart list ALIAS/BUCKET [--prefix TEXT --page-size 1..1000]
    \\zc multipart complete OBJECT --upload-id ID --file FILE --yes
    \\zc multipart abort OBJECT --upload-id ID --yes
    \\Complete file: {"Parts":[{"PartNumber":1,"ETag":"..."}]} in ascending order.
    \\Complete may replace the destination; --yes acknowledges that.
    \\Use --if-none-match * for create-only or --if-match ETAG for conditional replacement.
    \\put/cp: --multipart-threshold SIZE (default 16MiB) --part-size SIZE (automatic 8..128MiB, enlarged for part limits)
    \\  --max-parts N (10000) --resume --state-file FILE --overwrite --yes
    \\pipe OBJECT [--overwrite --yes] [--part-size SIZE]; stdin cannot resume.
    \\Sizes: bytes or KiB/MiB/GiB; parts 5MiB..5GiB; up to 10000/5TiB total.
    \\File uploads use up to four concurrent parts; --part-concurrency 1..4 overrides this.
    \\Concurrency is capped by available logical CPUs and the shared file-transfer budget.
    \\Automatic multipart defaults to If-None-Match: *; overwrite requires --overwrite --yes.
    \\Checkpoint defaults to SOURCE.zc-upload.json; keep it for resume/unknown outcomes.
    \\Resume checks file SHA256, layout, endpoint/identity/options and remote ETags/sizes.
    \\Resume never retries creating/completing/completed checkpoints.
    \\A new upload may replace a completed default checkpoint for the same source.
    \\Explicit --state-file and unfinished checkpoints are preserved; use a new path.
    \\Listings follow all pages up to 16MiB/10000 pages; excess fails without stdout.
    \\--dry-run validates locally; other connection options match s3api.
    \\Advanced encryption/tagging/checksum/copy-part options await later steps.
    \\
;

test "multipart sizes reject overflow and zero" {
    try std.testing.expectEqual(@as(u64, 5 * mib), try size("5MiB"));
    try std.testing.expectError(error.InvalidInput, size("0"));
    try std.testing.expectError(error.InvalidInput, size("18446744073709551615GiB"));
    try std.testing.expectError(error.InvalidInput, size("-1"));
}
