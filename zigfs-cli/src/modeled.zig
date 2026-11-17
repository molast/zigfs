//! Model-driven S3 operations; newly connected workflows await integration validation.
const std = @import("std");
const wire = @import("wire.zig");
const aliases = @import("alias.zig");
const signing = @import("signing.zig");
const xml = @import("xml.zig");
const A = std.mem.Allocator;
const V = std.json.Value;
const Io = std.Io;
pub const Args = struct {
    values: std.StringHashMapUnmanaged([]const u8) = .empty,
    repeated: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,
    flags: std.StringHashMapUnmanaged(void) = .empty,
    operands: std.ArrayList([]const u8) = .empty,
    headers: std.ArrayList(signing.Header) = .empty,
};
pub fn parse(a: A, args: []const []const u8) !Args {
    var r: Args = .{};
    var ended = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!ended and wire.eq(arg, "--")) {
            ended = true;
            continue;
        }
        if (!ended and arg.len > 1 and std.mem.startsWith(u8, arg, "-")) {
            const split = std.mem.indexOfScalar(u8, arg, '=');
            const raw_name = if (split) |n| arg[0..n] else arg;
            const name = if (wire.eq(raw_name, "-L")) "--level" else if (wire.eq(raw_name, "--vid")) "--version-id" else if (wire.eq(raw_name, "--bypass")) "--bypass-governance-retention" else raw_name;
            if (isFlag(name)) {
                if (split != null or r.flags.contains(name)) return error.InvalidInput;
                try r.flags.put(a, name, {});
                continue;
            }
            if (!std.mem.startsWith(u8, name, "--") and !wire.eq(name, "-H")) return error.InvalidInput;
            const value = if (split) |n| arg[n + 1 ..] else blk: {
                i += 1;
                if (i == args.len) return error.InvalidInput;
                break :blk args[i];
            };
            if (value.len == 0) return error.InvalidInput;
            if (wire.eq(name, "--header") or wire.eq(name, "-H")) {
                const colon = std.mem.indexOfScalar(u8, value, ':') orelse return error.InvalidInput;
                const n = try std.ascii.allocLowerString(a, value[0..colon]);
                if (wire.eq(n, "authorization") or wire.eq(n, "host") or wire.eq(n, "content-length") or wire.eq(n, "x-amz-date") or wire.eq(n, "x-amz-content-sha256") or wire.eq(n, "x-amz-security-token")) return error.InvalidInput;
                try r.headers.append(a, .{ .name = n, .value = std.mem.trim(u8, value[colon + 1 ..], " \t") });
            } else {
                const repeatable = wire.eq(name, "--tag") or wire.eq(name, "--key") or
                    wire.eq(name, "--include") or wire.eq(name, "--exclude") or
                    wire.eq(name, "--user") or wire.eq(name, "--group") or wire.eq(name, "--policy");
                if (r.values.contains(name) and !repeatable) return error.InvalidInput;
                if (repeatable) {
                    const list = try r.repeated.getOrPut(a, name);
                    if (!list.found_existing) list.value_ptr.* = .empty;
                    try list.value_ptr.append(a, value);
                }
                try r.values.put(a, name, value);
            }
        } else try r.operands.append(a, arg);
    }
    return r;
}
pub fn isFlag(n: []const u8) bool {
    for ([_][]const u8{ "--all", "--set-as-default", "--default", "--bypass", "--incomplete", "--size-only", "--ignore-times", "--immediate", "--confirm-immediate", "--stdin", "--yes", "--dry-run", "--insecure", "--generate-input-skeleton", "--overwrite", "--all-pages", "--versions", "--force", "--dangerous", "--fallback", "--recursive", "-r", "--remove", "--watch", "--continue-on-error", "--bypass-governance-retention" }) |s| if (wire.eq(s, n)) return true;
    return false;
}
pub fn model(a: A) !V {
    return (try std.json.parseFromSlice(V, a, @embedFile("models/s3.json"), .{})).value;
}
pub fn get(v: V, k: []const u8) ?V {
    return if (v == .object) v.object.get(k) else null;
}
pub fn text(v: V, k: []const u8) ?[]const u8 {
    const x = get(v, k) orelse return null;
    return if (x == .string) x.string else null;
}
pub fn put(a: A, v: *V, k: []const u8, t: []const u8) !void {
    try v.object.put(a, k, .{ .string = t });
}
fn boolean(v: V, k: []const u8) bool {
    const x = get(v, k) orelse return false;
    return x == .bool and x.bool;
}
fn shape(m: V, ref: V) !V {
    return get(get(m, "shapes").?, text(ref, "shape") orelse return error.InvalidInput) orelse return error.InvalidInput;
}
pub fn kebab(a: A, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (name, 0..) |c, i| {
        if (std.ascii.isUpper(c) and i > 0 and (std.ascii.isLower(name[i - 1]) or std.ascii.isDigit(name[i - 1]) or (i + 1 < name.len and std.ascii.isLower(name[i + 1])))) try out.append(a, '-');
        try out.append(a, std.ascii.toLower(c));
    }
    return out.items;
}
fn validate(m: V, ref: V, value: V, depth: usize) anyerror!void {
    if (depth > 32) return error.InvalidInput;
    const s = try shape(m, ref);
    const typ = text(s, "type").?;
    if (wire.eq(typ, "structure")) {
        if (value != .object) return error.InvalidInput;
        if (get(s, "required")) |required| for (required.array.items) |name| if (!value.object.contains(name.string)) return error.InvalidInput;
        const members = get(s, "members") orelse V{ .object = .{} };
        var it = value.object.iterator();
        while (it.next()) |entry| {
            const member = get(members, entry.key_ptr.*) orelse return error.UnknownInputField;
            try validate(m, member, entry.value_ptr.*, depth + 1);
        }
    } else if (wire.eq(typ, "list")) {
        if (value != .array or value.array.items.len > 100000) return error.InvalidInput;
        for (value.array.items) |v| try validate(m, get(s, "member").?, v, depth + 1);
    } else if (wire.eq(typ, "map")) {
        if (value != .object) return error.InvalidInput;
        var it = value.object.iterator();
        while (it.next()) |e| {
            try validate(m, get(s, "key").?, .{ .string = e.key_ptr.* }, depth + 1);
            try validate(m, get(s, "value").?, e.value_ptr.*, depth + 1);
        }
    } else if (wire.eq(typ, "boolean")) {
        if (value != .bool) return error.InvalidInput;
    } else if (wire.eq(typ, "integer") or wire.eq(typ, "long")) {
        if (value != .integer) return error.InvalidInput;
    } else if (wire.eq(typ, "float") or wire.eq(typ, "double")) {
        if (value != .float and value != .integer) return error.InvalidInput;
    } else {
        if (value != .string) return error.InvalidInput;
        if (wire.eq(typ, "blob")) {
            _ = std.base64.standard.Decoder.calcSizeForSlice(value.string) catch return error.InvalidInput;
        }
    }
    if (get(s, "enum")) |en| {
        var found = false;
        for (en.array.items) |v| {
            if (value == .string and wire.eq(v.string, value.string)) found = true;
        }
        if (!found) return error.InvalidInput;
    }
    const length: i64 = if (value == .string) @intCast(value.string.len) else if (value == .array) @intCast(value.array.items.len) else if (value == .integer) value.integer else return;
    if (get(s, "min")) |n| if (length < n.integer) return error.InvalidInput;
    if (get(s, "max")) |n| if (length > n.integer) return error.InvalidInput;
}
fn scalar(a: A, v: V) ![]const u8 {
    return switch (v) {
        .string => v.string,
        .integer => try std.fmt.allocPrint(a, "{d}", .{v.integer}),
        .float => try std.fmt.allocPrint(a, "{d}", .{v.float}),
        .bool => if (v.bool) "true" else "false",
        else => error.InvalidInput,
    };
}
fn escaped(w: *Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&apos;"),
            else => try w.writeByte(c),
        }
    }
}
fn node(a: A, m: V, w: *Io.Writer, name: []const u8, ref: V, value: V, depth: usize) anyerror!void {
    if (depth > 32) return error.InvalidInput;
    const s = try shape(m, ref);
    const typ = text(s, "type").?;
    if (wire.eq(typ, "list") and (boolean(ref, "flattened") or boolean(s, "flattened"))) {
        for (value.array.items) |item| try node(a, m, w, name, get(s, "member").?, item, depth + 1);
        return;
    }
    try w.print("<{s}", .{name});
    if (get(ref, "xmlNamespace") orelse get(s, "xmlNamespace")) |ns| {
        try w.writeAll(" xmlns");
        if (text(ns, "prefix")) |p| try w.print(":{s}", .{p});
        try w.writeAll("=\"");
        try escaped(w, text(ns, "uri").?);
        try w.writeByte('"');
    }
    if (wire.eq(typ, "structure")) {
        var it = value.object.iterator();
        while (it.next()) |e| {
            const member = get(get(s, "members").?, e.key_ptr.*).?;
            if (boolean(member, "xmlAttribute")) {
                try w.print(" {s}=\"", .{text(member, "locationName") orelse e.key_ptr.*});
                try escaped(w, try scalar(a, e.value_ptr.*));
                try w.writeByte('"');
            }
        }
    }
    try w.writeByte('>');
    if (wire.eq(typ, "structure")) {
        var it = get(s, "members").?.object.iterator();
        while (it.next()) |e| {
            const val = get(value, e.key_ptr.*) orelse continue;
            if (boolean(e.value_ptr.*, "xmlAttribute") or get(e.value_ptr.*, "location") != null) continue;
            try node(a, m, w, text(e.value_ptr.*, "locationName") orelse e.key_ptr.*, e.value_ptr.*, val, depth + 1);
        }
    } else if (wire.eq(typ, "list")) {
        const member = get(s, "member").?;
        for (value.array.items) |val| try node(a, m, w, text(member, "locationName") orelse "member", member, val, depth + 1);
    } else if (wire.eq(typ, "map")) {
        var it = value.object.iterator();
        while (it.next()) |e| {
            try w.writeAll("<entry>");
            try node(a, m, w, "key", get(s, "key").?, .{ .string = e.key_ptr.* }, depth + 1);
            try node(a, m, w, "value", get(s, "value").?, e.value_ptr.*, depth + 1);
            try w.writeAll("</entry>");
        }
    } else try escaped(w, try scalar(a, value));
    try w.print("</{s}>", .{name});
}
pub fn normalize(a: A, m: V, ref: V, raw: V, depth: usize) anyerror!V {
    if (depth > 32) return error.InvalidResponse;
    const spec = try shape(m, ref);
    const typ = text(spec, "type").?;
    if (wire.eq(typ, "structure")) {
        var value: V = .{ .object = .{} };
        var it = get(spec, "members").?.object.iterator();
        while (it.next()) |field| {
            if (get(field.value_ptr.*, "location") != null) continue;
            const val = get(raw, text(field.value_ptr.*, "locationName") orelse field.key_ptr.*) orelse continue;
            try value.object.put(a, field.key_ptr.*, try normalize(a, m, field.value_ptr.*, val, depth + 1));
        }
        return value;
    }
    if (wire.eq(typ, "list")) {
        var value: V = .{ .array = std.array_list.Managed(V).init(a) };
        const member = get(spec, "member").?;
        const flat = boolean(ref, "flattened") or boolean(spec, "flattened");
        const entries = if (flat) raw else get(raw, text(member, "locationName") orelse "member") orelse return value;
        if (entries == .array) {
            for (entries.array.items) |item| try value.array.append(try normalize(a, m, member, item, depth + 1));
        } else try value.array.append(try normalize(a, m, member, entries, depth + 1));
        return value;
    }
    if (raw == .string and wire.eq(typ, "boolean")) {
        if (!wire.eq(raw.string, "true") and !wire.eq(raw.string, "false")) return error.InvalidResponse;
        return .{ .bool = wire.eq(raw.string, "true") };
    }
    if (raw == .string and (wire.eq(typ, "integer") or wire.eq(typ, "long"))) return .{ .integer = std.fmt.parseInt(i64, raw.string, 10) catch return error.InvalidResponse };
    return raw;
}
fn skeleton(a: A, m: V, ref: V, depth: usize) anyerror!V {
    if (depth > 8) return .null;
    const s = try shape(m, ref);
    const typ = text(s, "type").?;
    if (wire.eq(typ, "structure")) {
        var v: V = .{ .object = .{} };
        var it = get(s, "members").?.object.iterator();
        while (it.next()) |e| try v.object.put(a, e.key_ptr.*, try skeleton(a, m, e.value_ptr.*, depth + 1));
        return v;
    }
    if (wire.eq(typ, "list")) {
        var v: V = .{ .array = std.array_list.Managed(V).init(a) };
        try v.array.append(try skeleton(a, m, get(s, "member").?, depth + 1));
        return v;
    }
    if (wire.eq(typ, "map")) return .{ .object = .{} };
    if (wire.eq(typ, "boolean")) return .{ .bool = false };
    if (wire.eq(typ, "integer") or wire.eq(typ, "long")) return .{ .integer = 0 };
    if (get(s, "enum")) |en| return en.array.items[0];
    return .{ .string = "" };
}
pub fn connection(a: A, ctx: aliases.Context, r: Args, config: ?[]const u8, name: []const u8) !aliases.Alias {
    return aliases.connection(a, ctx, config, name, .{ .endpoint = r.values.get("--endpoint"), .region = r.values.get("--region"), .bucket_lookup = r.values.get("--bucket-lookup"), .insecure = if (r.flags.contains("--insecure")) true else null, .ca_cert = r.values.get("--ca-cert"), .connect_timeout = try number(r, "--connect-timeout"), .timeout = try number(r, "--timeout") });
}
fn number(r: Args, n: []const u8) !?u32 {
    return if (r.values.get(n)) |s| std.fmt.parseInt(u32, s, 10) catch return error.InvalidInput else null;
}
pub const Remote = struct { alias: []const u8, bucket: []const u8, key: ?[]const u8 };
pub fn remote(path: []const u8) !Remote {
    const i = std.mem.indexOfScalar(u8, path, '/') orelse return error.InvalidInput;
    const rest = path[i + 1 ..];
    const j = std.mem.indexOfScalar(u8, rest, '/');
    if (i == 0 or rest.len == 0) return error.InvalidInput;
    return .{ .alias = path[0..i], .bucket = if (j) |k| rest[0..k] else rest, .key = if (j) |k| rest[k + 1 ..] else null };
}
pub fn validateRequest(a: A, op: []const u8, value: V) !void {
    const m = try model(a);
    const spec = get(get(m, "operations").?, op) orelse return error.UnsupportedOperation;
    try validate(m, get(spec, "input").?, value, 0);
}
pub fn operation(action: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, action, "s3api ")) return action[6..];
    inline for (@import("catalog.zig").entries) |e| if (wire.eq(e.path, action)) return e.operation;
    return null;
}
pub fn execute(a: A, ctx: aliases.Context, action: []const u8, args: []const []const u8, config: ?[]const u8, json: bool, quiet: bool) anyerror!wire.Output {
    const op = operation(action) orelse action;
    var r = try parse(a, args);
    const m = try model(a);
    const spec = get(get(m, "operations").?, op) orelse return error.UnsupportedOperation;
    const ref = get(spec, "input").?;
    const s = try shape(m, ref);
    if (r.values.contains("--input-json") and r.values.contains("--file")) return error.InvalidInput;
    if (wire.eq(r.values.get("--input-json") orelse "", "-") and wire.eq(r.values.get("--body") orelse "", "-")) return error.InvalidInput;
    if (r.flags.contains("--generate-input-skeleton")) return wire.output(a, json, false, "input-skeleton", try skeleton(a, m, ref, 0));
    var input = if (r.values.get("--input-json")) |p| try wire.readInputJson(a, ctx.io, p) else V{ .object = .{} };
    if (input != .object) return error.InvalidInput;
    if (r.operands.items.len == 0 or (r.operands.items.len != 1 and !wire.eq(op, "upload-part-copy"))) return error.InvalidInput;
    var alias_name: []const u8 = undefined;
    if (std.mem.startsWith(u8, action, "s3api ") or operation(action) == null) {
        alias_name = r.operands.items[0];
    } else {
        const target = try remote(r.operands.items[r.operands.items.len - 1]);
        alias_name = target.alias;
        try put(a, &input, "Bucket", target.bucket);
        if (target.key) |key| {
            if (key.len > 0) try put(a, &input, if (wire.eq(op, "list-objects") or wire.eq(op, "list-object-versions")) "Prefix" else "Key", key);
        }
        if (wire.eq(op, "upload-part-copy")) {
            if (r.operands.items.len != 2) return error.InvalidInput;
            const source = try remote(r.operands.items[0]);
            if (!wire.eq(source.alias, target.alias) or source.key == null) return error.UnsupportedOperation;
            try put(a, &input, "CopySource", try signing.encode(a, try std.fmt.allocPrint(a, "/{s}/{s}", .{ source.bucket, source.key.? }), true));
        }
        if (r.values.get("--file")) |path| {
            const payload = text(s, "payload") orelse return error.InvalidInput;
            const val = try wire.readInputJson(a, ctx.io, path);
            if (wire.eq(payload, "Policy")) try put(a, &input, payload, try std.json.Stringify.valueAlloc(a, val, .{})) else try input.object.put(a, payload, val);
        }
    }
    var it = r.values.iterator();
    while (it.next()) |entry| {
        const n = entry.key_ptr.*;
        if (wire.eq(n, "--input-json") or wire.eq(n, "--file") or wire.eq(n, "--body") or wire.eq(n, "--output") or wire.eq(n, "--endpoint") or wire.eq(n, "--region") or wire.eq(n, "--bucket-lookup") or wire.eq(n, "--ca-cert") or wire.eq(n, "--timeout") or wire.eq(n, "--connect-timeout")) continue;
        var found = false;
        var members = get(s, "members").?.object.iterator();
        while (members.next()) |member| {
            const flag = try std.fmt.allocPrint(a, "--{s}", .{try kebab(a, member.key_ptr.*)});
            const special = (wire.eq(n, "--name") and wire.eq(member.key_ptr.*, "AnnotationName")) or (wire.eq(n, "--attributes") and wire.eq(member.key_ptr.*, "ObjectAttributes"));
            if (!wire.eq(flag, n) and !special) continue;
            if (input.object.contains(member.key_ptr.*)) return error.InvalidInput;
            const typ = text(try shape(m, member.value_ptr.*), "type").?;
            const val: V = if (wire.eq(typ, "integer") or wire.eq(typ, "long")) .{ .integer = std.fmt.parseInt(i64, entry.value_ptr.*, 10) catch return error.InvalidInput } else if (wire.eq(typ, "boolean")) blk: {
                if (!wire.eq(entry.value_ptr.*, "true") and !wire.eq(entry.value_ptr.*, "false")) return error.InvalidInput;
                break :blk .{ .bool = wire.eq(entry.value_ptr.*, "true") };
            } else if (wire.eq(typ, "structure") or wire.eq(typ, "map") or wire.eq(typ, "list")) (std.json.parseFromSlice(V, a, entry.value_ptr.*, .{}) catch return error.InvalidInput).value else .{ .string = entry.value_ptr.* };
            try input.object.put(a, member.key_ptr.*, val);
            found = true;
            break;
        }
        if (!found) return error.InvalidInput;
    }
    if (!std.mem.startsWith(u8, action, "s3api ") and std.mem.startsWith(u8, op, "list-")) try r.flags.put(a, "--all-pages", {});
    if (r.flags.contains("--bypass-governance-retention")) try input.object.put(a, "BypassGovernanceRetention", .{ .bool = true });
    return executeInput(a, ctx, op, r, alias_name, input, config, json, quiet);
}
/// Cumulative scan work, before filtering. This is a payload/record budget, not RSS.
pub const ScanBudget = struct {
    records: usize = 0,
    bytes: usize = 0,
    pub fn charge(self: *ScanBudget, records: usize, bytes: usize) !void {
        if (records > 100000 - self.records or bytes > 64 * 1024 * 1024 - self.bytes) return error.ScanLimitExceeded;
        self.records += records;
        self.bytes += bytes;
    }
};
pub fn executeInput(a: A, ctx: aliases.Context, op: []const u8, r: Args, alias_name: []const u8, input_value: V, config: ?[]const u8, json: bool, quiet: bool) anyerror!wire.Output {
    return executeInputBudget(a, ctx, op, r, alias_name, input_value, config, json, quiet, null);
}
pub fn executeInputBudget(a: A, ctx: aliases.Context, op: []const u8, r: Args, alias_name: []const u8, input_value: V, config: ?[]const u8, json: bool, quiet: bool, budget: ?*ScanBudget) anyerror!wire.Output {
    var flags = r.flags.keyIterator();
    while (flags.next()) |flag| {
        var allowed = false;
        for ([_][]const u8{ "--yes", "--dry-run", "--insecure", "--overwrite", "--all-pages", "--bypass-governance-retention" }) |n| if (wire.eq(flag.*, n)) {
            allowed = true;
            break;
        };
        if (!allowed) return error.InvalidInput;
    }
    if (!r.flags.contains("--all-pages") or r.flags.contains("--dry-run")) return executeOne(a, ctx, op, r, alias_name, input_value, config, json, quiet);
    if (!std.mem.startsWith(u8, op, "list-") and !wire.eq(op, "get-object-attributes")) return error.InvalidInput;
    if (r.values.contains("--output")) return error.InvalidInput;
    if (input_value != .object) return error.InvalidInput;
    var input = input_value;
    input.object = try input_value.object.clone(a);
    var pages: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var total: usize = 0;
    while (pages.items.len < 10000) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const pa = arena.allocator();
        const out = try executeOne(pa, ctx, op, r, alias_name, input, config, true, false);
        if (out.exit_code != 0) return .{ .exit_code = out.exit_code, .stderr = try a.dupe(u8, out.stderr) };
        const envelope = (try std.json.parseFromSlice(V, pa, out.stdout, .{})).value;
        const result = get(get(envelope, "data").?, "result").?;
        const encoded = try std.json.Stringify.valueAlloc(pa, result, .{});
        if (budget) |limit| {
            var records: usize = 0;
            for ([_][]const u8{ "Buckets", "Contents", "Versions", "DeleteMarkers", "Uploads", "Parts", "CommonPrefixes" }) |field| {
                if (get(result, field)) |items| {
                    if (items != .array) return error.InvalidResponse;
                    records += items.array.items.len;
                }
            }
            try limit.charge(records, encoded.len);
        }
        total += encoded.len;
        if (total > 64 * 1024 * 1024) return error.InvalidResponse;
        try pages.append(a, try a.dupe(u8, encoded));
        // Only ObjectParts is paginated; other attributes may omit it entirely.
        const cursor_result = if (wire.eq(op, "get-object-attributes")) get(result, "ObjectParts") orelse break else result;
        const truncated = get(cursor_result, "IsTruncated");
        const bucket_token = if (wire.eq(op, "list-buckets")) text(cursor_result, "ContinuationToken") orelse "" else "";
        const more = if (wire.eq(op, "list-buckets")) bucket_token.len > 0 else if (truncated) |v| (v == .bool and v.bool) or (v == .string and wire.eq(v.string, "true")) else text(cursor_result, "NextToken") != null or text(cursor_result, "NextContinuationToken") != null;
        if (!more) break;
        var cursor: Io.Writer.Allocating = .init(a);
        var changed = false;
        const mappings = [_][2][]const u8{ .{ "NextKeyMarker", "KeyMarker" }, .{ "NextVersionIdMarker", "VersionIdMarker" }, .{ "NextUploadIdMarker", "UploadIdMarker" }, .{ "NextPartNumberMarker", "PartNumberMarker" }, .{ "NextMarker", "Marker" }, .{ "NextContinuationToken", "ContinuationToken" }, .{ "NextToken", "ContinuationToken" } };
        for (mappings) |pair| if (get(cursor_result, pair[0])) |cursor_value| {
            const value = try scalar(pa, cursor_value);
            if (value.len == 0) continue;
            if (wire.eq(pair[1], "PartNumberMarker")) {
                try input.object.put(a, pair[1], .{ .integer = std.fmt.parseInt(i64, value, 10) catch return error.InvalidResponse });
            } else try put(a, &input, pair[1], try a.dupe(u8, value));
            try cursor.writer.print("{s}:{d}:{s};", .{ pair[1], value.len, value });
            changed = true;
        };
        if (bucket_token.len > 0) {
            try put(a, &input, "ContinuationToken", try a.dupe(u8, bucket_token));
            try cursor.writer.print("ContinuationToken:{d}:{s};", .{ bucket_token.len, bucket_token });
            changed = true;
        }
        // V1 without a delimiter may omit NextMarker; last Key is the marker.
        if (!changed and wire.eq(op, "list-objects")) {
            const entries = get(result, "Contents") orelse return error.InvalidResponse;
            if (entries != .array or entries.array.items.len == 0) return error.InvalidResponse;
            const key = text(entries.array.items[entries.array.items.len - 1], "Key") orelse return error.InvalidResponse;
            try put(a, &input, "Marker", try a.dupe(u8, key));
            try cursor.writer.writeAll(key);
            changed = true;
        }
        if (!changed or seen.contains(cursor.written())) return error.InvalidResponse;
        try seen.put(a, cursor.written(), {});
    } else return error.InvalidResponse;
    var results: V = .{ .array = std.array_list.Managed(V).init(a) };
    for (pages.items) |page| try results.array.append((try std.json.parseFromSlice(V, a, page, .{})).value);
    return wire.output(a, json, quiet, "s3api-pages", .{ .operation = op, .pages = results, .complete = true });
}
fn executeOne(a: A, ctx: aliases.Context, op: []const u8, r: Args, alias_name: []const u8, input_value: V, config: ?[]const u8, json: bool, quiet: bool) anyerror!wire.Output {
    const m = try model(a);
    const spec = get(get(m, "operations").?, op) orelse return error.UnsupportedOperation;
    const ref = get(spec, "input").?;
    const s = try shape(m, ref);
    var input = input_value;
    if (r.flags.contains("--bypass-governance-retention")) {
        input.object = try input.object.clone(a);
        try input.object.put(a, "BypassGovernanceRetention", .{ .bool = true });
    }
    if (r.values.get("--body")) |_| {
        const payload = text(s, "payload") orelse return error.InvalidInput;
        if (input.object.contains(payload)) return error.InvalidInput;
        const ps = try shape(m, get(get(s, "members").?, payload).?);
        if (!wire.eq(text(ps, "type").?, "blob")) return error.InvalidInput;
        try put(a, &input, payload, "");
    }
    try validate(m, ref, input, 0);
    const http = get(spec, "http").?;
    const method = text(http, "method").?;
    if (!wire.eq(method, "GET") and !wire.eq(method, "HEAD") and !r.flags.contains("--yes") and !r.flags.contains("--dry-run")) return error.ConfirmationRequired;
    var path = text(http, "requestUri").?;
    var pairs: std.ArrayList(signing.Pair) = .empty;
    var headers: std.ArrayList(signing.Header) = .empty;
    if (std.mem.indexOfScalar(u8, path, '?')) |at| {
        var parts = std.mem.splitScalar(u8, path[at + 1 ..], '&');
        while (parts.next()) |part| {
            const sep = std.mem.indexOfScalar(u8, part, '=');
            try pairs.append(a, .{ .name = if (sep) |n| part[0..n] else part, .value = if (sep) |n| part[n + 1 ..] else "" });
        }
        path = path[0..at];
    }
    var members = get(s, "members").?.object.iterator();
    while (members.next()) |e| {
        const value = get(input, e.key_ptr.*) orelse continue;
        const member = e.value_ptr.*;
        const location = text(member, "location") orelse continue;
        const name = text(member, "locationName") orelse e.key_ptr.*;
        if (wire.eq(location, "uri")) {
            const encoded = try signing.encode(a, try scalar(a, value), wire.eq(name, "Key"));
            const plus = try std.fmt.allocPrint(a, "{{{s}+}}", .{name});
            const plain = try std.fmt.allocPrint(a, "{{{s}}}", .{name});
            path = try replace(a, path, plus, encoded);
            path = try replace(a, path, plain, encoded);
        } else if (wire.eq(location, "querystring")) try pairs.append(a, .{ .name = name, .value = try scalar(a, value) }) else if (wire.eq(location, "header")) {
            var val: []const u8 = undefined;
            if (value == .array) {
                var buf: Io.Writer.Allocating = .init(a);
                for (value.array.items, 0..) |v, i| {
                    if (i > 0) try buf.writer.writeByte(',');
                    try buf.writer.writeAll(try scalar(a, v));
                }
                val = buf.written();
            } else val = try scalar(a, value);
            try wire.safe(val);
            try headers.append(a, .{ .name = name, .value = val });
        } else if (wire.eq(location, "headers")) {
            var it = value.object.iterator();
            while (it.next()) |v| try headers.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}{s}", .{ name, v.key_ptr.* }), .value = try scalar(a, v.value_ptr.*) });
        }
    }
    if (std.mem.indexOfScalar(u8, path, '{') != null) return error.InvalidInput;
    const conn = try connection(a, ctx, r, config, alias_name);
    var host: ?[]const u8 = null;
    if (wire.eq(conn.bucket_lookup, "dns") and text(input, "Bucket") != null) {
        const bucket = text(input, "Bucket") orelse return error.InvalidInput;
        const uri = try std.Uri.parse(conn.endpoint);
        const h = switch (uri.host.?) {
            .raw => |v| v,
            .percent_encoded => |v| v,
        };
        if (std.mem.indexOfScalar(u8, h, ':') != null) return error.InvalidInput;
        host = if (uri.port) |p| try std.fmt.allocPrint(a, "{s}.{s}:{d}", .{ bucket, h, p }) else try std.fmt.allocPrint(a, "{s}.{s}", .{ bucket, h });
        const prefix = try std.fmt.allocPrint(a, "/{s}", .{try signing.encode(a, bucket, false)});
        if (!std.mem.startsWith(u8, path, prefix)) return error.InvalidInput;
        path = if (path.len == prefix.len) "/" else path[prefix.len..];
    }
    var body: []const u8 = "";
    if (text(s, "payload")) |payload| {
        if (get(input, payload)) |value| {
            const member = get(get(s, "members").?, payload).?;
            const typ = text(try shape(m, member), "type").?;
            if (wire.eq(typ, "string")) body = value.string else if (wire.eq(typ, "blob")) {
                const len = try std.base64.standard.Decoder.calcSizeForSlice(value.string);
                const decoded = try a.alloc(u8, len);
                try std.base64.standard.Decoder.decode(decoded, value.string);
                body = decoded;
            } else {
                var buf: Io.Writer.Allocating = .init(a);
                try node(a, m, &buf.writer, text(member, "locationName") orelse payload, member, value, 0);
                body = buf.written();
                try headers.append(a, .{ .name = "content-type", .value = "application/xml" });
            }
        }
    } else if (!wire.eq(method, "GET") and !wire.eq(method, "HEAD") and !wire.eq(method, "DELETE")) {
        var buf: Io.Writer.Allocating = .init(a);
        try node(a, m, &buf.writer, text(ref, "locationName") orelse text(ref, "shape").?, ref, input, 0);
        body = buf.written();
    }
    try headers.appendSlice(a, r.headers.items);
    if (r.flags.contains("--dry-run")) return wire.output(a, json, quiet, "request-plan", .{ .operation = op, .method = method, .path = path, .query = pairs.items, .mutating = !wire.eq(method, "GET") and !wire.eq(method, "HEAD"), .body_bytes = body.len });
    const event_stream = wire.eq(op, "select-object-content");
    const binary = event_stream or wire.eq(op, "get-object-torrent") or wire.eq(op, "get-object-annotation") or wire.eq(op, "get-object");
    if (binary and !r.values.contains("--output")) return error.InvalidInput;
    if (!binary and r.values.contains("--output")) return error.InvalidInput;
    const reply = try wire.send(a, ctx, .{ .connection = conn, .method = method, .path = path, .host = host, .query = pairs.items, .headers = headers.items, .body = body, .body_file = r.values.get("--body"), .output = r.values.get("--output"), .overwrite = r.flags.contains("--overwrite"), .event_stream = event_stream, .md5 = get(spec, "httpChecksum") != null });
    if (try wire.check(a, json, reply)) |err| return err;
    var result: V = .null;
    if (reply.body.len > 0) {
        if (reply.body[0] == '<') {
            const root = xml.parse(a, reply.body) catch return error.InvalidResponse;
            if (wire.eq(root.name, "Error")) return wire.failure(a, json, "S3_ERROR", "operation returned an embedded error; no retry", 1);
            result = try xml.toJson(a, root);
            if (get(spec, "output")) |output_ref| {
                const output_shape = try shape(m, output_ref);
                if (text(output_shape, "payload")) |payload| {
                    const value = try normalize(a, m, get(get(output_shape, "members").?, payload).?, result, 0);
                    result = .{ .object = .{} };
                    try result.object.put(a, payload, value);
                } else result = try normalize(a, m, output_ref, result, 0);
            }
        } else {
            result = (std.json.parseFromSlice(V, a, reply.body, .{}) catch return error.InvalidResponse).value;
        }
    }
    if (get(spec, "output")) |out_ref| {
        const out_shape = try shape(m, out_ref);
        var fields = get(out_shape, "members").?.object.iterator();
        while (fields.next()) |field| {
            const location = text(field.value_ptr.*, "location") orelse continue;
            if (wire.eq(location, "headers")) {
                const prefix = text(field.value_ptr.*, "locationName") orelse return error.InvalidResponse;
                const values = try wire.headerMap(a, reply.headers, prefix);
                if (result != .object) result = .{ .object = .{} };
                try result.object.put(a, field.key_ptr.*, values);
                continue;
            }
            if (!wire.eq(location, "header")) continue;
            if (wire.header(reply.headers, text(field.value_ptr.*, "locationName") orelse field.key_ptr.*)) |value| {
                if (result != .object) result = .{ .object = .{} };
                try result.object.put(a, field.key_ptr.*, try normalize(a, m, field.value_ptr.*, .{ .string = value }, 0));
            }
        }
    }
    if (wire.eq(op, "delete-objects")) if (get(result, "Errors")) |errors| {
        if (errors == .array and errors.array.items.len > 0) return wire.failure(a, json, "PARTIAL_DELETE", "one or more deletions failed; no automatic retry", 1);
    };
    if (wire.eq(op, "copy-object") or wire.eq(op, "upload-part-copy") or wire.eq(op, "complete-multipart-upload")) {
        const copy_result = get(result, "CopyObjectResult") orelse get(result, "CopyPartResult") orelse result;
        if (text(copy_result, "ETag") == null) return error.InvalidResponse;
    }
    // Keep data.metadata stable when legacy object commands delegate to this client.
    const metadata = get(result, "Metadata") orelse V{ .object = .{} };
    return wire.output(a, json, quiet, "s3api", .{ .operation = op, .status_code = reply.status, .result = result, .metadata = metadata, .bytes_written = reply.bytes, .headers = .{ .etag = wire.header(reply.headers, "etag"), .version_id = wire.header(reply.headers, "x-amz-version-id"), .delete_marker = wire.header(reply.headers, "x-amz-delete-marker") } });
}
fn replace(a: A, source: []const u8, needle: []const u8, value: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, source, needle) orelse return source;
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ source[0..at], value, source[at + needle.len ..] });
}
pub const help =
    \\Pending validation: model-driven S3 commands. Inputs follow the pinned AWS shapes.
    \\s3api OP ALIAS --input-json FILE [--body FILE] [--output FILE] [--yes|--dry-run]
    \\High-level configuration: COMMAND ALIAS/BUCKET[/KEY] [--file CONFIG_JSON]
    \\Model fields also accept --kebab-case-name VALUE; nested values use JSON strings.
    \\--generate-input-skeleton lists all modeled fields; unknown fields are rejected.
    \\Writes require --yes; --dry-run validates and prints a redacted request plan.
    \\Binary replies require --output FILE; existing output needs --overwrite.
    \\New operations are connected, not integration-tested; backend support varies.
    \\
;
