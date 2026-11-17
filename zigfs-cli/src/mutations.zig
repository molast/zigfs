const std = @import("std");
const api = @import("s3api.zig");
const aliases = @import("alias.zig");
const signing = @import("signing.zig");
const A = std.mem.Allocator;
const V = std.json.Value;
const Map = std.StringHashMapUnmanaged([]const u8);
const Remote = struct { alias: []const u8, bucket: []const u8, key: []const u8 };
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn remote(path: []const u8, batch: bool) !Remote {
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return error.InvalidInput;
    const rest = path[slash + 1 ..];
    const cut = std.mem.indexOfScalar(u8, rest, '/');
    if (slash == 0 or rest.len == 0 or (batch and cut != null) or (!batch and (cut == null or cut.? + 1 == rest.len))) return error.InvalidInput;
    return .{ .alias = path[0..slash], .bucket = if (cut) |c| rest[0..c] else rest, .key = if (cut) |c| rest[c + 1 ..] else "" };
}
fn put(a: A, v: *V, key: []const u8, value: []const u8) !void {
    try v.object.put(a, key, .{ .string = value });
}
fn target(a: A, r: Remote, key: bool) !V {
    var v: V = .{ .object = .{} };
    try put(a, &v, "Bucket", r.bucket);
    if (key) try put(a, &v, "Key", r.key);
    return v;
}
fn data(a: A, output: api.Output) !V {
    return (try std.json.parseFromSlice(V, a, output.stdout, .{})).value.object.get("data").?;
}
fn text(v: V, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .string) f.string else null;
}
fn report(a: A, json: bool, code: []const u8, message: []const u8, exit_code: u8, phase: []const u8, copied: bool, cause: ?V) !api.Output {
    const body = if (json) try std.json.Stringify.valueAlloc(a, .{ .schema_version = 1, .type = "error", .status = "error", .@"error" = .{ .code = code, .message = message, .phase = phase, .copy_completed = copied, .cause = cause } }, .{}) else try std.fmt.allocPrint(a, "zc: {s} (phase={s}, copy_completed={}){s}", .{ message, phase, copied, if (cause) |c| try std.fmt.allocPrint(a, "\n{s}", .{try std.json.Stringify.valueAlloc(a, c, .{})}) else "" });
    return .{ .exit_code = exit_code, .stderr = try std.fmt.allocPrint(a, "{s}\n", .{body}) };
}
fn failed(a: A, json: bool, output: api.Output, phase: []const u8, copied: bool) !api.Output {
    const cause = (try std.json.parseFromSlice(V, a, output.stderr, .{})).value;
    return report(a, json, if (copied) "MOVE_INCOMPLETE" else "OPERATION_FAILED", if (copied) "copy succeeded but move did not complete; destination retained; inspect source before retrying" else "operation failed; no automatic mutation retry", output.exit_code, phase, copied, cause);
}
fn finish(a: A, json: bool, quiet: bool, action: []const u8, result: V) !api.Output {
    if (quiet and !json) return .{};
    const body = if (json) try std.json.Stringify.valueAlloc(a, .{ .schema_version = 1, .type = action, .status = "success", .data = result }, .{}) else try std.json.Stringify.valueAlloc(a, result, .{ .whitespace = .indent_2 });
    return .{ .stdout = try std.fmt.allocPrint(a, "{s}\n", .{body}) };
}
pub fn execute(a: A, ctx: aliases.Context, action: []const u8, operands: []const []const u8, initial_pass: []const []const u8, values: Map, flags: std.StringHashMapUnmanaged(void), metadata: V, config: ?[]const u8, json: bool, quiet: bool) anyerror!api.Output {
    if (flags.contains("--resume")) return error.InvalidInput;
    const copy = eq(action, "object copy");
    const move = eq(action, "object move");
    const batch = eq(action, "object remove-batch");
    if (operands.len != @as(usize, if (copy or move) 2 else 1)) return error.InvalidInput;
    const source = try remote(operands[0], batch);
    const destination = if (copy or move) try remote(operands[1], false) else source;
    if (!eq(source.alias, destination.alias)) return error.UnsupportedOperation;
    if ((copy or move) and eq(source.bucket, destination.bucket) and eq(source.key, destination.key)) return error.InvalidInput;
    const overwrite = flags.contains("--overwrite");
    const dry = flags.contains("--dry-run");
    if ((!copy and !dry and !flags.contains("--yes")) or (overwrite and !dry and !flags.contains("--yes"))) return error.ConfirmationRequired;
    if (!copy and !move and overwrite) return error.InvalidInput;
    var pass: std.ArrayList([]const u8) = .empty;
    try pass.appendSlice(a, initial_pass);
    var input = try target(a, destination, !batch);
    const mappings = .{
        .{ "--content-type", "ContentType" },                           .{ "--content-encoding", "ContentEncoding" },
        .{ "--content-disposition", "ContentDisposition" },             .{ "--content-language", "ContentLanguage" },
        .{ "--cache-control", "CacheControl" },                         .{ "--metadata-directive", "MetadataDirective" },
        .{ "--if-match", "IfMatch" },                                   .{ "--if-none-match", "IfNoneMatch" },
        .{ "--source-if-match", "CopySourceIfMatch" },                  .{ "--source-if-none-match", "CopySourceIfNoneMatch" },
        .{ "--source-if-modified-since", "CopySourceIfModifiedSince" }, .{ "--source-if-unmodified-since", "CopySourceIfUnmodifiedSince" },
    };
    var it = values.iterator();
    while (it.next()) |e| {
        const n = e.key_ptr.*;
        if (eq(n, "--version-id")) {
            if (batch) return error.InvalidInput;
            if (!copy and !move) try put(a, &input, "VersionId", e.value_ptr.*);
            continue;
        }
        if (api.isValueOption(n)) {
            try pass.appendSlice(a, &.{ n, e.value_ptr.* });
            continue;
        }
        if (batch and (eq(n, "--keys-file") or eq(n, "--file"))) continue;
        if (eq(n, "--expected-bucket-owner") or eq(n, "--request-payer")) {
            try put(a, &input, if (eq(n, "--expected-bucket-owner")) "ExpectedBucketOwner" else "RequestPayer", e.value_ptr.*);
            continue;
        }
        var found = false;
        inline for (mappings) |m| if ((copy or move) and eq(n, m[0])) {
            try put(a, &input, m[1], e.value_ptr.*);
            found = true;
        };
        if (!found) return error.InvalidInput;
    }
    if (metadata.object.count() > 0) {
        if (!copy and !move) return error.InvalidInput;
        try input.object.put(a, "Metadata", metadata);
    }
    if (copy or move) {
        try put(a, &input, "CopySource", try signing.encode(a, try std.fmt.allocPrint(a, "/{s}/{s}", .{ source.bucket, source.key }), true));
        if (values.get("--version-id")) |v| {
            const encoded = try signing.encode(a, v, false);
            try put(a, &input, "CopySource", try std.fmt.allocPrint(a, "{s}?versionId={s}", .{ text(input, "CopySource").?, encoded }));
        }
        if (overwrite) {
            if (input.object.contains("IfNoneMatch")) return error.InvalidInput;
        } else {
            if (input.object.contains("IfMatch")) return error.InvalidInput;
            if (text(input, "IfNoneMatch")) |v| if (!eq(v, "*")) return error.InvalidInput;
            try put(a, &input, "IfNoneMatch", "*");
        }
    }
    if (batch) {
        if (values.contains("--file") and values.contains("--keys-file")) return error.InvalidInput;
        const path = values.get("--file") orelse values.get("--keys-file") orelse return error.InvalidInput;
        if (eq(path, "-")) return error.InvalidInput;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(ctx.io, path, a, .limited(1024 * 1024));
        const document = (std.json.parseFromSlice(V, a, bytes, .{}) catch return error.InvalidInput).value;
        var deletion = document;
        if (values.contains("--keys-file")) {
            if (document != .array or document.array.items.len == 0 or document.array.items.len > 1000) return error.InvalidInput;
            var objects: std.array_list.Managed(V) = .init(a);
            for (document.array.items) |key| {
                if (key != .string) return error.InvalidInput;
                var item: V = .{ .object = .{} };
                try put(a, &item, "Key", key.string);
                try objects.append(item);
            }
            deletion = .{ .object = .{} };
            try deletion.object.put(a, "Objects", .{ .array = objects });
            try deletion.object.put(a, "Quiet", .{ .bool = false });
        }
        try input.object.put(a, "Delete", deletion);
    }
    const operation: []const u8 = if (copy or move) "copy-object" else if (batch) "delete-objects" else "delete-object";
    try api.validateInput(std.meta.stringToEnum(api.Operation, operation).?, input);
    try pass.append(a, source.alias);
    if (dry) {
        var preview: V = .{ .object = .{} };
        try preview.object.put(a, "dry_run", .{ .bool = true });
        try preview.object.put(a, "request", input);
        return finish(a, json, quiet, action, preview);
    }
    // Fail closed for enabled/suspended versioning and for unavailable/denied checks.
    if (move and !values.contains("--version-id")) for ([_]Remote{ source, destination }, 0..) |r, index| {
        if (index == 1 and eq(source.bucket, destination.bucket)) continue;
        const check = try api.executeInput(a, ctx, "get-bucket-versioning", pass.items, config, true, false, try target(a, r, false));
        if (check.exit_code != 0) return failed(a, json, check, "versioning", false);
        const version = (try data(a, check)).object.get("result").?;
        if (!(version == .string and version.string.len == 0) and !(version == .object and version.object.count() == 0))
            return report(a, json, "NOT_SUPPORTED", "versioned or unknown bucket state; version-aware mutations await step 10", 7, "versioning", false, null);
    };
    var original: ?V = null;
    if (move) {
        var source_head = try target(a, source, true);
        if (values.get("--version-id")) |v| try put(a, &source_head, "VersionId", v);
        const observed = try api.executeInput(a, ctx, "head-object", pass.items, config, true, false, source_head);
        if (observed.exit_code != 0) return failed(a, json, observed, "source-head", false);
        original = (try data(a, observed)).object.get("headers").?;
        const etag = text(original.?, "etag") orelse return error.InvalidResponse;
        if (!input.object.contains("CopySourceIfMatch")) try put(a, &input, "CopySourceIfMatch", etag);
    }
    try pass.append(a, "--yes");
    const result = try api.executeInput(a, ctx, operation, pass.items, config, true, false, input);
    if (result.exit_code != 0) return failed(a, json, result, operation, false);
    const completed = try data(a, result);
    if (!move) return finish(a, json, quiet, action, completed);
    // Read-only confirmation must not inherit mutation-only --yes.
    const reads = pass.items[0 .. pass.items.len - 1];
    const copied_etag = text(completed.object.get("result").?, "ETag") orelse return error.InvalidResponse;
    for ([_]Remote{ destination, source }, 0..) |r, index| {
        var check_input = try target(a, r, true);
        if (index == 1) {
            if (values.get("--version-id")) |v| try put(a, &check_input, "VersionId", v);
        }
        const observed = api.executeInput(a, ctx, "head-object", reads, config, true, false, check_input) catch return report(a, json, "MOVE_INCOMPLETE", "copy succeeded; verification failed; source deletion was not attempted", 1, "verify", true, null);
        if (observed.exit_code != 0) return failed(a, json, observed, "verify", true);
        const headers = (try data(a, observed)).object.get("headers").?;
        const expected = if (index == 0) copied_etag else text(original.?, "etag").?;
        var same = if (text(headers, "etag")) |v| eq(v, expected) else false;
        if (index == 1) for ([_][]const u8{ "content_length", "last_modified" }) |key| {
            same = same and eq(text(headers, key) orelse "", text(original.?, key) orelse "");
        };
        if (!same) return report(a, json, "MOVE_INCOMPLETE", "object changed during move; destination retained; source deletion was not attempted", 6, "verify", true, null);
    }
    var delete_input = try target(a, source, true);
    if (values.get("--version-id")) |v| try put(a, &delete_input, "VersionId", v);
    const deleted = api.executeInput(a, ctx, "delete-object", pass.items, config, true, false, delete_input) catch return report(a, json, "MOVE_INCOMPLETE", "copy succeeded; delete outcome unknown; inspect source before retrying", 1, "delete-source", true, null);
    if (deleted.exit_code != 0) return failed(a, json, deleted, "delete-source", true);
    var result_data: V = .{ .object = .{} };
    try result_data.object.put(a, "copy", completed);
    try result_data.object.put(a, "delete", try data(a, deleted));
    return finish(a, json, quiet, action, result_data);
}
