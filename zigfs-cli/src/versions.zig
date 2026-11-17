//! Version-aware destructive plans. Exact version IDs; enumerate before modifying.
const std = @import("std");
const m = @import("modeled.zig");
const w = @import("wire.zig");
const support = @import("command_support.zig");
const aliases = @import("alias.zig");
const A = std.mem.Allocator;
const V = std.json.Value;
extern fn zc_bulk_begin() void;
extern fn zc_bulk_listen() void;
extern fn zc_bulk_end() void;
extern fn zc_interrupted() c_int;
pub fn wanted(action: []const u8, args: []const []const u8) bool {
    if (!w.eq(action, "object remove") and !w.eq(action, "bucket remove")) return false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (w.eq(arg, "--")) break;
        if (w.eq(arg, "--versions") or (w.eq(action, "bucket remove") and w.eq(arg, "--force"))) return true;
        if (arg.len > 1 and arg[0] == '-' and std.mem.indexOfScalar(u8, arg, '=') == null and !m.isFlag(arg) and !@import("bulk.zig").isFlag(arg) and !@import("objects.zig").isFlag(arg)) index += 1;
    }
    return false;
}
fn result(a: A, out: w.Output) !V {
    return (try std.json.parseFromSlice(V, a, out.stdout, .{})).value.object.get("data").?;
}
pub fn execute(a: A, ctx: aliases.Context, action: []const u8, args: []const []const u8, config: ?[]const u8, json: bool, quiet: bool) anyerror!w.Output {
    zc_bulk_begin();
    zc_bulk_listen();
    defer zc_bulk_end();
    const r = try m.parse(a, args);
    if (r.operands.items.len != 1) return error.InvalidInput;
    try support.check(r, &.{"--page-size"}, &.{ "--force", "--dangerous", "--versions", "--recursive", "-r", "--bypass-governance-retention" });
    // Custom headers and management-only overrides have no version-delete contract.
    if (r.headers.items.len != 0 or r.values.contains("--management-endpoint") or r.values.contains("--token-file")) return error.InvalidInput;
    const remote = try m.remote(r.operands.items[0]);
    const rb = w.eq(action, "bucket remove");
    if (rb and (remote.key != null or !r.flags.contains("--force"))) return error.InvalidInput;
    if (!rb and (remote.key == null or remote.key.?.len == 0) and !r.flags.contains("--recursive") and !r.flags.contains("-r")) return error.InvalidInput;
    if (!rb and (r.flags.contains("--force") or r.flags.contains("--dangerous"))) return error.InvalidInput;
    if (!r.flags.contains("--yes") and !r.flags.contains("--dry-run")) return error.ConfirmationRequired;
    var options = try support.network(a, r, false);
    try options.flags.put(a, "--all-pages", {});

    var input: V = .{ .object = .{} };
    try m.put(a, &input, "Bucket", remote.bucket);
    if (remote.key) |prefix| try m.put(a, &input, "Prefix", prefix);
    const page_size = if (r.values.get("--page-size")) |value| try std.fmt.parseInt(i64, value, 10) else 1000;
    if (page_size < 1 or page_size > 1000) return error.InvalidInput;
    try input.object.put(a, "MaxKeys", .{ .integer = page_size });
    const listed = try m.executeInput(a, ctx, "list-object-versions", options, remote.alias, input, config, true, false);
    if (listed.exit_code != 0) return listed;
    const pages = m.get(try result(a, listed), "pages").?;
    var plan: std.ArrayList(Item) = .empty;
    for (pages.array.items) |page| for ([_][]const u8{ "Versions", "DeleteMarkers" }) |kind| {
        const entries = m.get(page, kind) orelse continue;
        if (entries != .array) return error.InvalidResponse;
        for (entries.array.items) |entry| {
            const key = m.text(entry, "Key") orelse return error.InvalidResponse;
            if (!rb and !r.flags.contains("--recursive") and !r.flags.contains("-r") and !w.eq(key, remote.key orelse "")) continue;
            if (plan.items.len >= 100000) return error.InvalidResponse;
            try plan.append(a, .{ .key = key, .version = m.text(entry, "VersionId") orelse return error.InvalidResponse });
        }
    };
    var uploads: std.ArrayList(Upload) = .empty;
    if (rb) {
        _ = input.object.swapRemove("MaxKeys");
        try input.object.put(a, "MaxUploads", .{ .integer = page_size });
        const listed_uploads = try m.executeInput(a, ctx, "list-multipart-uploads", options, remote.alias, input, config, true, false);
        if (listed_uploads.exit_code != 0) return listed_uploads;
        for (m.get(try result(a, listed_uploads), "pages").?.array.items) |page| {
            const entries = m.get(page, "Uploads") orelse continue;
            for (entries.array.items) |entry| {
                if (uploads.items.len >= 100000) return error.InvalidResponse;
                try uploads.append(a, .{ .key = m.text(entry, "Key") orelse return error.InvalidResponse, .id = m.text(entry, "UploadId") orelse return error.InvalidResponse });
            }
        }
        if (uploads.items.len > 0 and !r.flags.contains("--dangerous")) return w.failure(a, json, "CONFLICT", "pending multipart uploads exist; --dangerous required; nothing deleted", 6);
    }
    if (r.flags.contains("--dry-run")) return w.output(a, json, quiet, "version-delete-plan", .{ .versions = plan.items, .uploads = uploads.items, .remove_bucket = rb });
    var progress: support.Progress = .{ .planned = plan.items.len + uploads.items.len + @intFromBool(rb) };
    return applyPlan(a, ctx, r, remote, plan.items, uploads.items, rb, config, json, quiet, &progress) catch |err| {
        return progress.failure(a, json, "version-delete", try support.localFailure(a, err));
    };
}
const Item = struct { key: []const u8, version: []const u8 };
const Upload = struct { key: []const u8, id: []const u8 };
fn applyPlan(a: A, ctx: aliases.Context, r: m.Args, remote: m.Remote, plan: []const Item, uploads: []const Upload, rb: bool, config: ?[]const u8, json: bool, quiet: bool, progress: *support.Progress) !w.Output {
    const deletion_options = try support.network(a, r, true);
    var options = try support.network(a, r, true);
    _ = options.flags.remove("--bypass-governance-retention");
    for (plan) |item| {
        progress.stage = "delete-version";
        progress.item = item.key;
        progress.version_id = item.version;
        if (zc_interrupted() != 0) return error.Interrupted;
        var deletion = try support.base(a, remote, null);
        try m.put(a, &deletion, "Key", item.key);
        try m.put(a, &deletion, "VersionId", item.version);
        progress.attempted = true;
        const out = try mutate(a, ctx, "delete-object", deletion_options, remote.alias, deletion, config);
        if (out.exit_code != 0) return progress.failure(a, json, "version-delete", out);
        progress.deleted += 1;
        progress.attempted = false;
    }
    for (uploads) |upload| {
        progress.stage = "abort-upload";
        progress.item = upload.key;
        progress.version_id = null;
        progress.upload_id = upload.id;
        if (zc_interrupted() != 0) return error.Interrupted;
        var abort = try support.base(a, remote, null);
        try m.put(a, &abort, "Key", upload.key);
        try m.put(a, &abort, "UploadId", upload.id);
        progress.attempted = true;
        const out = try mutate(a, ctx, "abort-multipart-upload", options, remote.alias, abort, config);
        if (out.exit_code != 0) return progress.failure(a, json, "version-delete", out);
        progress.aborted += 1;
        progress.attempted = false;
    }
    if (rb) {
        progress.stage = "delete-bucket";
        progress.item = remote.bucket;
        progress.version_id = null;
        progress.upload_id = null;
        if (zc_interrupted() != 0) return error.Interrupted;
        const input = try support.base(a, remote, null);
        progress.attempted = true;
        const out = try mutate(a, ctx, "delete-bucket", options, remote.alias, input, config);
        if (out.exit_code != 0) return progress.failure(a, json, "version-delete", out);
        progress.removed_bucket = true;
        progress.attempted = false;
    }
    return w.output(a, json, quiet, "version-delete", .{ .deleted = progress.deleted, .aborted = progress.aborted, .removed_bucket = progress.removed_bucket });
}
fn mutate(a: A, ctx: aliases.Context, op: []const u8, options: m.Args, alias: []const u8, input: V, config: ?[]const u8) !w.Output {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const out = try m.executeInput(arena.allocator(), ctx, op, options, alias, input, config, true, false);
    if (out.exit_code != 0) return support.ownOutput(a, out);
    return .{};
}
pub const help =
    \\Version cleanup: rm ALIAS/BUCKET/KEY --versions [--recursive/-r]
    \\  rb ALIAS/BUCKET --force [--dangerous] enumerates and deletes every version.
    \\Requires --yes or --dry-run. Pending uploads require --dangerous for rb.
    \\Supports --endpoint --region --bucket-lookup --ca-cert --insecure
    \\  --timeout --connect-timeout --page-size 1..1000 --bypass-governance-retention (--bypass).
    \\Bypass applies only to object deletion; it does not bypass compliance mode or legal holds.
    \\This path is sequential: filters, concurrency, retry/rate controls, custom headers,
    \\  summary, continue-on-error and fail-empty are rejected, despite general bulk help.
    \\Failures include confirmed counts, stage/item, unstarted work and uncertain attempted outcome.
    \\Logic connected; pending validation.
    \\
;
