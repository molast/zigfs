const std = @import("std");
const aliases = @import("alias.zig");
const api = @import("s3api.zig");
const signing = @import("signing.zig");
const xml = @import("xml.zig");
const A = std.mem.Allocator;
const V = std.json.Value;
const Io = std.Io;
const Map = std.StringHashMapUnmanaged([]const u8);

pub fn wanted(action: []const u8) bool {
    return eq(action, "object share") or eq(action, "share post") or eq(action, "object post");
}
pub fn isFlag(n: []const u8) bool {
    return eq(n, "--yes") or eq(n, "--insecure");
}
pub fn isValueOption(n: []const u8) bool {
    for ([_][]const u8{ "--method", "--expire", "--credential-expiration", "--version-id", "--operation", "--upload-id", "--part-number", "--policy-file", "--fields-file", "--field", "--file", "--header", "-H", "--endpoint", "--region", "--bucket-lookup", "--ca-cert", "--connect-timeout", "--timeout" }) |v| if (eq(v, n)) return true;
    return false;
}
fn eq(l: []const u8, r: []const u8) bool {
    return std.mem.eql(u8, l, r);
}
fn put(a: A, value: *V, key: []const u8, text: []const u8) !void {
    try value.object.put(a, key, .{ .string = text });
}
fn str(v: V, key: []const u8) ![]const u8 {
    if (v != .object) return error.InvalidInput;
    const val = v.object.get(key) orelse return error.InvalidInput;
    if (val != .string) return error.InvalidInput;
    return val.string;
}
fn safe(s: []const u8) !void {
    for (s) |c| if (c < 32 or c == 127) return error.InvalidInput;
}
fn fieldName(s: []const u8) !void {
    if (s.len == 0 or s.len > 256) return error.InvalidInput;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.InvalidInput;
}
fn duration(s: []const u8) !u64 {
    if (s.len == 0) return error.InvalidInput;
    var digits = s;
    var scale: u64 = 1;
    switch (s[s.len - 1]) {
        's' => {
            digits = s[0 .. s.len - 1];
        },
        'm' => {
            digits = s[0 .. s.len - 1];
            scale = 60;
        },
        'h' => {
            digits = s[0 .. s.len - 1];
            scale = 3600;
        },
        'd' => {
            digits = s[0 .. s.len - 1];
            scale = 86400;
        },
        else => {},
    }
    const n = std.fmt.parseInt(u64, digits, 10) catch return error.InvalidInput;
    const result = std.math.mul(u64, n, scale) catch return error.InvalidInput;
    if (result == 0 or result > 604800) return error.InvalidInput;
    return result;
}
fn readJson(a: A, io: Io, path: []const u8) !V {
    const f = try Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false });
    defer f.close(io);
    const stat = try f.stat(io);
    if (stat.kind != .file or stat.size > 256 * 1024) return error.InvalidInput;
    const bytes = try a.alloc(u8, @intCast(stat.size));
    if (try f.readPositionalAll(io, bytes, 0) != bytes.len) return error.InvalidInput;
    return (std.json.parseFromSlice(V, a, bytes, .{}) catch return error.InvalidInput).value;
}
fn output(a: A, json: bool, action: []const u8, data: anytype) !api.Output {
    return .{ .stdout = try std.fmt.allocPrint(a, "{s}\n", .{try std.json.Stringify.valueAlloc(a, .{ .schema_version = 1, .type = action, .status = "success", .data = data }, .{ .whitespace = if (json) .minified else .indent_2 })}) };
}
fn fail(a: A, json: bool, code: []const u8, n: u8, status: c_long) !api.Output {
    return .{ .exit_code = n, .stderr = try std.fmt.allocPrint(a, "{s}\n", .{try std.json.Stringify.valueAlloc(a, .{ .schema_version = 1, .type = "error", .status = "error", .@"error" = .{ .code = code, .message = "POST did not complete successfully; inspect target before retrying; form credentials and server messages omitted", .http_status = status } }, .{ .whitespace = if (json) .minified else .indent_2 })}) };
}
const Target = struct { url: []const u8, host: []const u8, path: []const u8 };
fn target(a: A, conn: aliases.Alias, bucket: []const u8, key: ?[]const u8) !Target {
    const uri = try std.Uri.parse(conn.endpoint);
    const host = switch (uri.host.?) {
        .raw => |v| v,
        .percent_encoded => |v| v,
    };
    const dns = eq(conn.bucket_lookup, "dns");
    if (dns and (std.mem.indexOfScalar(u8, host, ':') != null or std.mem.indexOfScalar(u8, host, '[') != null)) return error.InvalidInput;
    const authority = if (dns) try std.fmt.allocPrint(a, "{s}.{s}", .{ bucket, host }) else host;
    const h = if (uri.port) |port| try std.fmt.allocPrint(a, "{s}:{d}", .{ authority, port }) else authority;
    const raw = if (key) |k| if (dns) try std.fmt.allocPrint(a, "/{s}", .{k}) else try std.fmt.allocPrint(a, "/{s}/{s}", .{ bucket, k }) else if (dns) "/" else try std.fmt.allocPrint(a, "/{s}", .{bucket});
    const path = try signing.encode(a, raw, true);
    return .{ .url = try std.fmt.allocPrint(a, "{s}://{s}{s}", .{ uri.scheme, h, path }), .host = h, .path = path };
}
fn number(values: Map, n: []const u8) !?u32 {
    return if (values.get(n)) |v| std.fmt.parseInt(u32, v, 10) catch return error.InvalidInput else null;
}

pub fn execute(a: A, ctx: aliases.Context, action: []const u8, args: []const []const u8, config: ?[]const u8, json: bool, quiet: bool) anyerror!api.Output {
    _ = quiet; // Sharing is an explicit request to output a bearer capability.
    var values: Map = .empty;
    var headers: std.ArrayList(signing.Header) = .empty;
    var fields: V = .{ .object = .{} };
    var operand: ?[]const u8 = null;
    var yes = false;
    var insecure = false;
    var ended = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!ended and eq(arg, "--")) {
            ended = true;
            continue;
        }
        if (!ended and std.mem.startsWith(u8, arg, "-")) {
            const split = std.mem.indexOfScalar(u8, arg, '=');
            const n = if (split) |at| arg[0..at] else arg;
            if (isFlag(n)) {
                if (split != null or (eq(n, "--yes") and yes) or (eq(n, "--insecure") and insecure)) return error.InvalidInput;
                if (eq(n, "--yes")) yes = true else insecure = true;
                continue;
            }
            if (!isValueOption(n)) return error.InvalidInput;
            const v = if (split) |at| arg[at + 1 ..] else blk: {
                i += 1;
                if (i == args.len) return error.InvalidInput;
                break :blk args[i];
            };
            if (v.len == 0) return error.InvalidInput;
            try safe(v);
            if (eq(n, "--header") or eq(n, "-H")) {
                const at = std.mem.indexOfScalar(u8, v, ':') orelse return error.InvalidInput;
                const name = try std.ascii.allocLowerString(a, v[0..at]);
                try fieldName(name);
                if (eq(name, "host") or eq(name, "authorization") or eq(name, "content-length") or eq(name, "transfer-encoding") or eq(name, "connection") or std.mem.startsWith(u8, name, "x-amz-date") or eq(name, "x-amz-security-token") or eq(name, "x-amz-content-sha256")) return error.InvalidInput;
                try headers.append(a, .{ .name = name, .value = std.mem.trim(u8, v[at + 1 ..], " \t") });
            } else if (eq(n, "--field")) {
                const at = std.mem.indexOfScalar(u8, v, '=') orelse return error.InvalidInput;
                try fieldName(v[0..at]);
                if (fields.object.contains(v[0..at])) return error.InvalidInput;
                try put(a, &fields, v[0..at], v[at + 1 ..]);
            } else {
                if (values.contains(n)) return error.InvalidInput;
                try values.put(a, n, v);
            }
        } else {
            if (operand != null) return error.InvalidInput;
            operand = arg;
        }
    }
    const remote = operand orelse return error.InvalidInput;
    try safe(remote);
    const slash = std.mem.indexOfScalar(u8, remote, '/') orelse return error.InvalidInput;
    const rest = remote[slash + 1 ..];
    const sep = std.mem.indexOfScalar(u8, rest, '/');
    const bucket = if (sep) |at| rest[0..at] else rest;
    const key: ?[]const u8 = if (sep) |at| rest[at + 1 ..] else null;
    if (bucket.len < 3 or bucket.len > 63) return error.InvalidInput;
    for (bucket) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '.') return error.InvalidInput;
    const post = eq(action, "share post");
    const upload = eq(action, "object post");
    if (post or upload) {
        if (key != null and key.?.len != 0) return error.InvalidInput;
    } else if (key == null or key.?.len == 0 or key.?.len > 1024) return error.InvalidInput;
    var vit = values.iterator();
    while (vit.next()) |entry| {
        const n = entry.key_ptr.*;
        const common = eq(n, "--endpoint") or eq(n, "--region") or eq(n, "--bucket-lookup");
        const allowed = if (upload) common or eq(n, "--fields-file") or eq(n, "--file") or eq(n, "--ca-cert") or eq(n, "--connect-timeout") or eq(n, "--timeout") else common or eq(n, "--expire") or eq(n, "--credential-expiration") or (if (post) eq(n, "--policy-file") else eq(n, "--method") or eq(n, "--operation") or eq(n, "--upload-id") or eq(n, "--part-number") or eq(n, "--version-id"));
        if (!allowed) return error.InvalidInput;
    }
    if ((!upload and (yes or insecure)) or ((post or upload) and headers.items.len != 0) or (!post and fields.object.count() != 0)) return error.InvalidInput;
    const conn = try aliases.connection(a, ctx, config, remote[0..slash], .{ .endpoint = values.get("--endpoint"), .region = values.get("--region"), .bucket_lookup = values.get("--bucket-lookup"), .insecure = if (insecure) true else null, .ca_cert = values.get("--ca-cert"), .connect_timeout = try number(values, "--connect-timeout"), .timeout = try number(values, "--timeout") });
    const t = try target(a, conn, bucket, if (post or upload) null else key);
    if (upload) {
        if (!yes) return error.ConfirmationRequired;
        return postUpload(a, ctx, conn, t, values, json);
    }
    if (conn.access_key.len == 0 or conn.secret_key.len == 0) return error.CredentialsRequired;
    const now: u64 = @intCast(Io.Clock.real.now(ctx.io).toSeconds());
    const expire = try duration(values.get("--expire") orelse "1h");
    const expiry = std.math.add(u64, now, expire) catch return error.InvalidInput;
    const credential_expiry = values.get("--credential-expiration") orelse ctx.env.get("ZC_CREDENTIAL_EXPIRATION");
    if (conn.session_token.len > 0 and credential_expiry == null) return error.InvalidInput;
    if (credential_expiry) |v| {
        const end = std.fmt.parseInt(u64, v, 10) catch return error.InvalidInput;
        if (end <= now or expiry > end) return error.InvalidInput;
    }
    const date = try signing.timestamp(a, now);
    const scope = try std.fmt.allocPrint(a, "{s}/{s}/s3/aws4_request", .{ date[0..8], conn.region });
    if (post) return postShare(a, ctx, conn, t, bucket, values, &fields, date, scope, expiry, json);
    var method = values.get("--method") orelse "GET";
    var pairs: std.ArrayList(signing.Pair) = .empty;
    if (values.get("--operation")) |op| {
        const expected: []const u8 = if (eq(op, "create-multipart-upload") or eq(op, "complete-multipart-upload")) "POST" else if (eq(op, "upload-part")) "PUT" else if (eq(op, "list-parts")) "GET" else if (eq(op, "abort-multipart-upload")) "DELETE" else return error.InvalidInput;
        if (values.get("--method")) |m| if (!eq(m, expected)) return error.InvalidInput;
        method = expected;
        if (values.contains("--version-id")) return error.InvalidInput;
        if (eq(op, "create-multipart-upload")) {
            if (values.contains("--upload-id") or values.contains("--part-number")) return error.InvalidInput;
            try pairs.append(a, .{ .name = "uploads", .value = "" });
        } else {
            try pairs.append(a, .{ .name = "uploadId", .value = values.get("--upload-id") orelse return error.InvalidInput });
            if (eq(op, "upload-part")) {
                const part = try number(values, "--part-number") orelse return error.InvalidInput;
                if (part == 0 or part > 10000) return error.InvalidInput;
                try pairs.append(a, .{ .name = "partNumber", .value = try std.fmt.allocPrint(a, "{d}", .{part}) });
            } else if (values.contains("--part-number")) return error.InvalidInput;
        }
    } else {
        if (!eq(method, "GET") and !eq(method, "PUT") and !eq(method, "DELETE") and !eq(method, "HEAD")) return error.InvalidInput;
        if (values.contains("--upload-id") or values.contains("--part-number")) return error.InvalidInput;
        if (values.get("--version-id")) |v| {
            if (eq(method, "PUT")) return error.InvalidInput;
            try pairs.append(a, .{ .name = "versionId", .value = v });
        }
    }
    try headers.append(a, .{ .name = "host", .value = t.host });
    const first = try signing.sign(a, method, t.path, "", headers.items, "UNSIGNED-PAYLOAD", date, conn.region, conn.access_key, conn.secret_key);
    var names: std.Io.Writer.Allocating = .init(a);
    var required: V = .{ .object = .{} };
    for (first.headers, 0..) |h, n| {
        if (n > 0) try names.writer.writeByte(';');
        try names.writer.writeAll(h.name);
        try put(a, &required, h.name, h.value);
    }
    try pairs.appendSlice(a, &.{ .{ .name = "X-Amz-Algorithm", .value = "AWS4-HMAC-SHA256" }, .{ .name = "X-Amz-Credential", .value = try std.fmt.allocPrint(a, "{s}/{s}", .{ conn.access_key, scope }) }, .{ .name = "X-Amz-Date", .value = date }, .{ .name = "X-Amz-Expires", .value = try std.fmt.allocPrint(a, "{d}", .{expire}) }, .{ .name = "X-Amz-SignedHeaders", .value = names.written() } });
    if (conn.session_token.len > 0) try pairs.append(a, .{ .name = "X-Amz-Security-Token", .value = conn.session_token });
    const query = try signing.query(a, pairs.items);
    const signed = try signing.sign(a, method, t.path, query, headers.items, "UNSIGNED-PAYLOAD", date, conn.region, conn.access_key, conn.secret_key);
    const signature = signed.authorization[signed.authorization.len - 64 ..];
    return output(a, json, "share", .{ .url = try std.fmt.allocPrint(a, "{s}?{s}&X-Amz-Signature={s}", .{ t.url, query, signature }), .method = method, .headers = required, .expires_at = expiry, .expires_in = expire });
}

fn iso(a: A, stamp: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}-{s}-{s}T{s}:{s}:{s}Z", .{ stamp[0..4], stamp[4..6], stamp[6..8], stamp[9..11], stamp[11..13], stamp[13..15] });
}
fn condition(a: A, list: *V, name: []const u8, value: []const u8) !void {
    var c: V = .{ .object = .{} };
    try put(a, &c, name, value);
    try list.array.append(c);
}
fn reserved(name: []const u8) bool {
    return eq(name, "policy") or eq(name, "file") or eq(name, "bucket") or eq(name, "x-amz-algorithm") or eq(name, "x-amz-credential") or eq(name, "x-amz-date") or eq(name, "x-amz-signature") or eq(name, "x-amz-security-token");
}
fn policyField(name: []const u8) bool {
    return eq(name, "key") or eq(name, "Content-Type") or eq(name, "success_action_status") or eq(name, "Content-MD5") or eq(name, "x-amz-checksum-crc64nvme") or std.mem.startsWith(u8, name, "x-amz-meta-");
}
fn postShare(a: A, ctx: aliases.Context, conn: aliases.Alias, t: Target, bucket: []const u8, values: Map, fields: *V, date: []const u8, scope: []const u8, expiry: u64, json: bool) !api.Output {
    const policy = try readJson(a, ctx.io, values.get("--policy-file") orelse return error.InvalidInput);
    if (policy != .object or policy.object.count() != 1) return error.InvalidInput;
    var conditions = policy.object.get("conditions") orelse return error.InvalidInput;
    if (conditions != .array or conditions.array.items.len == 0 or conditions.array.items.len > 100) return error.InvalidInput;
    var covered: std.StringHashMapUnmanaged(void) = .empty;
    var length_seen = false;
    var key_seen = false;
    var fit = fields.object.iterator();
    while (fit.next()) |e| {
        if (!policyField(e.key_ptr.*) or reserved(e.key_ptr.*) or e.value_ptr.string.len > 65536) return error.InvalidInput;
    }
    for (conditions.array.items) |c| {
        if (c == .object) {
            if (c.object.count() == 0) return error.InvalidInput;
            var it = c.object.iterator();
            while (it.next()) |e| {
                const name = e.key_ptr.*;
                if (!policyField(name) or reserved(name) or e.value_ptr.* != .string) return error.InvalidInput;
                try fieldName(name);
                try safe(e.value_ptr.string);
                if (fields.object.get(name)) |v| {
                    if (!eq(v.string, e.value_ptr.string)) return error.InvalidInput;
                } else try put(a, fields, name, e.value_ptr.string);
                try covered.put(a, name, {});
                if (eq(name, "key")) key_seen = true;
            }
        } else if (c == .array and c.array.items.len == 3) {
            const items = c.array.items;
            if (items[0] != .string) return error.InvalidInput;
            if (eq(items[0].string, "content-length-range")) {
                if (length_seen or items[1] != .integer or items[2] != .integer or items[1].integer < 0 or items[2].integer < items[1].integer or items[2].integer > 5 * 1024 * 1024 * 1024 * 1024) return error.InvalidInput;
                length_seen = true;
                continue;
            }
            if ((!eq(items[0].string, "eq") and !eq(items[0].string, "starts-with")) or items[1] != .string or items[2] != .string or items[1].string.len < 2 or items[1].string[0] != '$') return error.InvalidInput;
            const name = items[1].string[1..];
            if (!policyField(name) or reserved(name)) return error.InvalidInput;
            try safe(items[2].string);
            if (eq(items[0].string, "eq") and !fields.object.contains(name)) try put(a, fields, name, items[2].string);
            const value = try str(fields.*, name);
            if (if (eq(items[0].string, "eq")) !eq(value, items[2].string) else !std.mem.startsWith(u8, value, items[2].string)) return error.InvalidInput;
            if (eq(name, "Content-Type") and std.mem.indexOfScalar(u8, value, ',') != null) return error.InvalidInput;
            try covered.put(a, name, {});
            if (eq(name, "key")) key_seen = true;
        } else return error.InvalidInput;
    }
    if (!length_seen or !key_seen) return error.InvalidInput;
    fit = fields.object.iterator();
    while (fit.next()) |e| {
        if (!covered.contains(e.key_ptr.*) or e.value_ptr.string.len > 65536) return error.InvalidInput;
        try safe(e.value_ptr.string);
    }
    const key = try str(fields.*, "key");
    if (key.len == 0 or key.len > 1024 or std.mem.indexOf(u8, key, "${") != null) return error.InvalidInput;
    if (fields.object.get("success_action_status")) |s| if (!eq(s.string, "200") and !eq(s.string, "201") and !eq(s.string, "204")) return error.InvalidInput;
    const credential = try std.fmt.allocPrint(a, "{s}/{s}", .{ conn.access_key, scope });
    try condition(a, &conditions, "bucket", bucket);
    for ([_]signing.Pair{ .{ .name = "x-amz-algorithm", .value = "AWS4-HMAC-SHA256" }, .{ .name = "x-amz-credential", .value = credential }, .{ .name = "x-amz-date", .value = date } }) |pair| {
        try condition(a, &conditions, pair.name, pair.value);
        try put(a, fields, pair.name, pair.value);
    }
    if (conn.session_token.len > 0) {
        try condition(a, &conditions, "x-amz-security-token", conn.session_token);
        try put(a, fields, "x-amz-security-token", conn.session_token);
    }
    const expiration = try iso(a, try signing.timestamp(a, expiry));
    const bytes = try std.json.Stringify.valueAlloc(a, .{ .expiration = expiration, .conditions = conditions }, .{});
    if (bytes.len > 48 * 1024 or fields.object.count() > 120) return error.InvalidInput;
    const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    try put(a, fields, "policy", encoded);
    const signature = try signing.policySignature(a, encoded, date, conn.region, conn.secret_key);
    try put(a, fields, "x-amz-signature", try a.dupe(u8, &signature));
    return output(a, json, "share post", .{ .url = t.url, .method = "POST", .fields = fields.*, .expires_at = expiry });
}

const ReadFn = *const fn (?*anyopaque, [*]u8, usize) callconv(.c) usize;
const WriteFn = *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) c_int;
extern fn zc_http([*:0]const u8, [*:0]const u8, [*]const [*:0]const u8, usize, [*:0]const u8, c_int, c_long, c_long, i64, c_int, i64, ?ReadFn, ?WriteFn, ?*anyopaque, [*]u8, usize, *usize, [*]u8, usize, *usize, *c_long) c_int;
const Form = struct {
    io: Io,
    file: Io.File,
    prefix: []const u8,
    suffix: []const u8,
    size: u64,
    offset: u64 = 0,
    failed: bool = false,
    fn read(raw: ?*anyopaque, out: [*]u8, cap: usize) callconv(.c) usize {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        const total = self.prefix.len + self.size + self.suffix.len;
        if (self.offset >= total) return 0;
        var n: usize = 0;
        if (self.offset < self.prefix.len) {
            const at: usize = @intCast(self.offset);
            n = @min(cap, self.prefix.len - at);
            @memcpy(out[0..n], self.prefix[at..][0..n]);
        } else if (self.offset < self.prefix.len + self.size) {
            const at = self.offset - self.prefix.len;
            n = @intCast(@min(cap, self.size - at));
            const got = self.file.readPositionalAll(self.io, out[0..n], at) catch {
                self.failed = true;
                return std.math.maxInt(usize);
            };
            if (got != n) {
                self.failed = true;
                return std.math.maxInt(usize);
            }
        } else {
            const at: usize = @intCast(self.offset - self.prefix.len - self.size);
            n = @min(cap, self.suffix.len - at);
            @memcpy(out[0..n], self.suffix[at..][0..n]);
        }
        self.offset += n;
        return n;
    }
};
fn postUpload(a: A, ctx: aliases.Context, conn: aliases.Alias, t: Target, values: Map, json: bool) !api.Output {
    var document = try readJson(a, ctx.io, values.get("--fields-file") orelse return error.InvalidInput);
    // Accept either a plain fields object or the exact share-post JSON envelope.
    if (document == .object and document.object.contains("data")) {
        const data = document.object.get("data").?;
        if (!eq(try str(data, "url"), t.url) or !eq(try str(data, "method"), "POST")) return error.InvalidInput;
        document = data.object.get("fields") orelse return error.InvalidInput;
    }
    if (document != .object or document.object.count() > 128) return error.InvalidInput;
    for ([_][]const u8{ "key", "policy", "x-amz-algorithm", "x-amz-credential", "x-amz-date", "x-amz-signature" }) |name| {
        const v = try str(document, name);
        if (v.len == 0) return error.InvalidInput;
    }
    if (!eq(try str(document, "x-amz-algorithm"), "AWS4-HMAC-SHA256")) return error.InvalidInput;
    const expected: c_long = if (document.object.get("success_action_status")) |v| blk: {
        if (v != .string) return error.InvalidInput;
        break :blk std.fmt.parseInt(c_long, v.string, 10) catch return error.InvalidInput;
    } else 204;
    if (expected != 200 and expected != 201 and expected != 204) return error.InvalidInput;
    const source = values.get("--file") orelse return error.InvalidInput;
    const file = try Io.Dir.cwd().openFile(ctx.io, source, .{ .follow_symlinks = false });
    defer file.close(ctx.io);
    const stat = try file.stat(ctx.io);
    if (stat.kind != .file or stat.size > 5 * 1024 * 1024 * 1024 * 1024) return error.InvalidInput;
    var random: [24]u8 = undefined;
    Io.random(ctx.io, &random);
    const boundary = try std.fmt.allocPrint(a, "zc-{s}", .{std.fmt.bytesToHex(random, .lower)});
    var prefix: std.Io.Writer.Allocating = .init(a);
    var it = document.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        try fieldName(name);
        if (v != .string or v.string.len > 65536 or eq(name, "file") or eq(name, "success_action_redirect")) return error.InvalidInput;
        try safe(v.string);
        try prefix.writer.print("--{s}\r\nContent-Disposition: form-data; name=\"{s}\"\r\n\r\n{s}\r\n", .{ boundary, name, v.string });
    }
    // A fixed filename avoids path/header injection. Literal keys only in this step.
    if (std.mem.indexOf(u8, try str(document, "key"), "${") != null) return error.InvalidInput;
    try prefix.writer.print("--{s}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"upload.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n", .{boundary});
    const suffix = try std.fmt.allocPrint(a, "\r\n--{s}--\r\n", .{boundary});
    var form: Form = .{ .io = ctx.io, .file = file, .prefix = prefix.written(), .suffix = suffix, .size = stat.size };
    const hs = [_][*:0]const u8{ try std.fmt.allocPrintSentinel(a, "Content-Type: multipart/form-data; boundary={s}", .{boundary}, 0), "Expect:" };
    const response_headers = try a.alloc(u8, 64 * 1024);
    const response = try a.alloc(u8, 1024 * 1024);
    var hn: usize = 0;
    var bn: usize = 0;
    var status: c_long = 0;
    const result = zc_http(try a.dupeSentinel(u8, t.url, 0), "POST", &hs, hs.len, try a.dupeSentinel(u8, conn.ca_cert, 0), @intFromBool(conn.insecure), @as(c_long, conn.connect_timeout) * 1000, @as(c_long, conn.timeout) * 1000, 0, 1, @intCast(prefix.written().len + stat.size + suffix.len), Form.read, null, &form, response_headers.ptr, response_headers.len, &hn, response.ptr, response.len, &bn, &status);
    if (result != 0 or form.failed) return fail(a, json, "POST_TRANSPORT_ERROR", 3, status);
    if (status != 200 and status != 201 and status != 204) return fail(a, json, "POST_REJECTED", if (status == 401 or status == 403) 4 else if (status == 404) 5 else if (status == 409 or status == 412) 6 else 1, status);

    if (status != expected) return fail(a, json, "INVALID_POST_RESPONSE", 1, status);
    if (status == 201) {
        const root = xml.parse(a, response[0..bn]) catch return fail(a, json, "INVALID_POST_RESPONSE", 1, status);
        const etag: []const u8 = xml.child(root, "ETag") orelse "";
        if (!eq(root.name, "PostResponse") or etag.len == 0 or !eq(xml.child(root, "Key") orelse "", try str(document, "key"))) return fail(a, json, "INVALID_POST_RESPONSE", 1, status);
    } else if (bn != 0) return fail(a, json, "INVALID_POST_RESPONSE", 1, status);
    return output(a, json, "object post", .{ .http_status = status, .bytes_uploaded = stat.size });
}

pub const help =
    \\zc share OBJECT [--method GET|PUT|DELETE|HEAD] [--expire 1h] [--version-id ID]
    \\zc share OBJECT --operation create-multipart-upload|upload-part|list-parts|complete-multipart-upload|abort-multipart-upload
    \\  [--upload-id ID] [--part-number 1..10000] [--header 'Name: value']
    \\zc share post ALIAS/BUCKET --policy-file JSON [--field key=value] [--expire 1h]
    \\zc object post ALIAS/BUCKET --file FILE --fields-file JSON --yes
    \\Expire: positive seconds or s/m/h/d, at most 7d; default 1h.
    \\Session credentials require --credential-expiration UNIX_SECONDS or ZC_CREDENTIAL_EXPIRATION.
    \\Requested expiry must not exceed credential expiry. Signing is offline.
    \\Policy input: {"conditions":[{"key":"path"},["content-length-range",0,1048576]]}
    \\Expiration and auth fields are generated. eq/starts-with require matching fields;
    \\key and content-length-range are mandatory; key filename substitution is unsupported.
    \\Share output intentionally contains bearer URLs/fields; keep it private.
    \\POST streams multipart/form-data, never retries or follows redirects; output omits fields.
    \\--endpoint/--region/--bucket-lookup override alias settings. POST supports TLS/timeouts.
    \\
;

test "share duration bounds" {
    try std.testing.expectEqual(@as(u64, 86400), try duration("24h"));
    try std.testing.expectEqual(@as(u64, 604800), try duration("7d"));
    try std.testing.expectError(error.InvalidInput, duration("8d"));
    try std.testing.expectError(error.InvalidInput, duration("0"));
    try std.testing.expectError(error.InvalidInput, duration("18446744073709551615d"));
}
