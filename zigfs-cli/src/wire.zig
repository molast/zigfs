//! Shared bounded HTTP transport for the pending-validation command batch.
const std = @import("std");
const aliases = @import("alias.zig");
const signing = @import("signing.zig");
const A = std.mem.Allocator;
const Io = std.Io;
const V = std.json.Value;
pub const Output = struct { exit_code: u8 = 0, stdout: []const u8 = "", stderr: []const u8 = "" };
const ReadFn = *const fn (?*anyopaque, [*]u8, usize) callconv(.c) usize;
const WriteFn = *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) c_int;
extern fn zc_http([*:0]const u8, [*:0]const u8, [*]const [*:0]const u8, usize, [*:0]const u8, c_int, c_long, c_long, i64, c_int, i64, ?ReadFn, ?WriteFn, ?*anyopaque, [*]u8, usize, *usize, [*]u8, usize, *usize, *c_long) c_int;
pub const Request = struct {
    connection: aliases.Alias,
    method: []const u8,
    path: []const u8,
    query: []const signing.Pair = &.{},
    headers: []const signing.Header = &.{},
    body: []const u8 = "",
    body_file: ?[]const u8 = null,
    output: ?[]const u8 = null,
    overwrite: bool = false,
    signed: bool = true,
    bearer: ?[]const u8 = null,
    host: ?[]const u8 = null,
    md5: bool = false,
    event_stream: bool = false,
};
pub const Reply = struct { status: c_long, headers: []const u8, body: []const u8, bytes: u64, transport: c_int };
const Transfer = struct {
    io: Io,
    bytes: []const u8,
    source: ?Io.File = null,
    sink: ?Io.File = null,
    size: u64 = 0,
    offset: u64 = 0,
    written: u64 = 0,
    failed: bool = false,
    decoder: ?@import("event_stream.zig").Decoder = null,
    fn read(raw: ?*anyopaque, b: [*]u8, cap: usize) callconv(.c) usize {
        const t: *@This() = @ptrCast(@alignCast(raw.?));
        const n: usize = @intCast(@min(cap, t.size - t.offset));
        if (t.source) |f| {
            const got = f.readPositionalAll(t.io, b[0..n], t.offset) catch {
                t.failed = true;
                return std.math.maxInt(usize);
            };
            if (got != n) {
                t.failed = true;
                return std.math.maxInt(usize);
            }
        } else @memcpy(b[0..n], t.bytes[@intCast(t.offset)..][0..n]);
        t.offset += n;
        return n;
    }
    fn write(raw: ?*anyopaque, b: [*]const u8, n: usize) callconv(.c) c_int {
        const t: *@This() = @ptrCast(@alignCast(raw.?));
        if (t.decoder) |*decoder| {
            decoder.feed(t.io, t.sink.?, b[0..n]) catch {
                t.failed = true;
                return 1;
            };
            t.written = decoder.written;
            return 0;
        }
        t.sink.?.writeStreamingAll(t.io, b[0..n]) catch {
            t.failed = true;
            return 1;
        };
        t.written += n;
        return 0;
    }
};
pub fn send(a: A, ctx: aliases.Context, r: Request) !Reply {
    const uri = try std.Uri.parse(r.connection.endpoint);
    const raw_host = switch (uri.host.?) {
        .raw => |v| v,
        .percent_encoded => |v| v,
    };
    const host = r.host orelse if (uri.port) |port| try std.fmt.allocPrint(a, "{s}:{d}", .{ raw_host, port }) else raw_host;
    const query = try signing.query(a, r.query);
    const url = try std.fmt.allocPrintSentinel(a, "{s}://{s}{s}{s}{s}", .{ uri.scheme, host, r.path, if (query.len > 0) "?" else "", query }, 0);
    var t: Transfer = .{ .io = ctx.io, .bytes = r.body, .size = r.body.len };
    if (r.event_stream) t.decoder = .{ .allocator = a };
    defer if (t.decoder) |*d| d.pending.deinit(a);
    defer if (t.source) |f| f.close(ctx.io);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var md5 = std.crypto.hash.Md5.init(.{});
    if (r.body_file) |path| {
        if (r.body.len != 0) return error.InvalidInput;
        t.source = try Io.Dir.cwd().openFile(ctx.io, path, .{ .follow_symlinks = false });
        const stat = try t.source.?.stat(ctx.io);
        if (stat.kind != .file or stat.size > 5 * 1024 * 1024 * 1024 * 1024) return error.InvalidInput;
        t.size = stat.size;
        var buf: [65536]u8 = undefined;
        var offset: u64 = 0;
        while (offset < t.size) {
            const n = try t.source.?.readPositionalAll(ctx.io, buf[0..@intCast(@min(buf.len, t.size - offset))], offset);
            if (n == 0) return error.InvalidInput;
            hash.update(buf[0..n]);
            md5.update(buf[0..n]);
            offset += n;
        }
    } else {
        hash.update(r.body);
        md5.update(r.body);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    var hs: std.ArrayList(signing.Header) = .empty;
    try hs.appendSlice(a, r.headers);
    for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, "x-amz-sdk-checksum-algorithm")) {
        if (eq(h.value, "SHA256")) {
            if (!hasHeader(hs.items, "x-amz-checksum-sha256")) {
                const encoded = try a.alloc(u8, 44);
                _ = std.base64.standard.Encoder.encode(encoded, &digest);
                try hs.append(a, .{ .name = "x-amz-checksum-sha256", .value = encoded });
            }
        } else {
            const name = try std.fmt.allocPrint(a, "x-amz-checksum-{s}", .{try std.ascii.allocLowerString(a, h.value)});
            if (!hasHeader(hs.items, name)) return error.UnsupportedOperation;
        }
    };
    if (r.md5 and !hasHeader(hs.items, "content-md5")) {
        var d: [16]u8 = undefined;
        md5.final(&d);
        const encoded = try a.alloc(u8, 24);
        _ = std.base64.standard.Encoder.encode(encoded, &d);
        try hs.append(a, .{ .name = "content-md5", .value = encoded });
    }
    var wire: std.ArrayList([*:0]const u8) = .empty;
    if (r.signed) {
        if (r.connection.access_key.len == 0) return error.CredentialsRequired;
        const date = try signing.timestamp(a, @intCast(Io.Clock.real.now(ctx.io).toSeconds()));
        try hs.appendSlice(a, &.{ .{ .name = "host", .value = host }, .{ .name = "x-amz-date", .value = date }, .{ .name = "x-amz-content-sha256", .value = &hex } });
        if (r.connection.session_token.len > 0) try hs.append(a, .{ .name = "x-amz-security-token", .value = r.connection.session_token });
        const signed = try signing.sign(a, r.method, r.path, query, hs.items, &hex, date, r.connection.region, r.connection.access_key, r.connection.secret_key);
        hs.items = signed.headers;
        try wire.append(a, try std.fmt.allocPrintSentinel(a, "Authorization: {s}", .{signed.authorization}, 0));
    } else if (r.bearer) |token| {
        try safe(token);
        try wire.append(a, try std.fmt.allocPrintSentinel(a, "Authorization: Bearer {s}", .{token}, 0));
    }
    for (hs.items) |h| {
        try safe(h.name);
        try safe(h.value);
        try wire.append(a, try std.fmt.allocPrintSentinel(a, "{s}: {s}", .{ h.name, h.value }, 0));
    }
    try wire.append(a, "Expect:");
    var atomic: ?Io.File.Atomic = null;
    defer if (atomic) |*f| f.deinit(ctx.io);
    if (r.output) |path| {
        if (eq(path, "-")) return error.InvalidInput;
        atomic = try Io.Dir.cwd().createFileAtomic(ctx.io, path, .{ .replace = r.overwrite, .permissions = @fromBackingInt(0o600) });
        t.sink = atomic.?.file;
    }
    const headers = try a.alloc(u8, 64 * 1024);
    const body = try a.alloc(u8, 4 * 1024 * 1024);
    var hn: usize = 0;
    var bn: usize = 0;
    var status: c_long = 0;
    const has_body = eq(r.method, "PUT") or eq(r.method, "POST") or eq(r.method, "PATCH");
    const result = zc_http(url, try a.dupeSentinel(u8, r.method, 0), wire.items.ptr, wire.items.len, try a.dupeSentinel(u8, r.connection.ca_cert, 0), @intFromBool(r.connection.insecure), @as(c_long, r.connection.connect_timeout) * 1000, @as(c_long, r.connection.timeout) * 1000, 0, @intFromBool(has_body), @intCast(t.size), if (has_body) Transfer.read else null, if (r.output != null) Transfer.write else null, &t, headers.ptr, headers.len, &hn, body.ptr, body.len, &bn, &status);
    if (status >= 200 and status < 300) {
        if (t.decoder) |d| if (!d.complete()) {
            t.failed = true;
        };
    }
    if (result == 0 and !t.failed and status >= 200 and status < 300) {
        if (atomic) |*f| {
            try f.file.sync(ctx.io);
            if (r.overwrite) try f.replace(ctx.io) else try f.link(ctx.io);
        }
    }
    return .{ .status = status, .headers = headers[0..hn], .body = body[0..bn], .bytes = t.written, .transport = if (t.failed and result == 0) -2 else result };
}
pub fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}
pub fn safe(s: []const u8) !void {
    for (s) |c| if (c < 32 or c == 127) return error.InvalidInput;
}
fn hasHeader(hs: []const signing.Header, name: []const u8) bool {
    for (hs) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
    return false;
}
pub fn header(bytes: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, bytes, "\r\n");
    var value: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "HTTP/")) {
            value = null;
            continue;
        }
        const at = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..at], name)) value = std.mem.trim(u8, line[at + 1 ..], " \t");
    }
    return value;
}
/// Collect a prefixed header map from the final HTTP response block only.
/// Keys are lowercased, matching S3 metadata semantics and the legacy CLI output.
pub fn headerMap(a: A, bytes: []const u8, prefix: []const u8) !V {
    var result: V = .{ .object = .{} };
    var lines = std.mem.splitSequence(u8, bytes, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "HTTP/")) {
            result.object.clearRetainingCapacity();
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (colon <= prefix.len or !std.ascii.eqlIgnoreCase(line[0..prefix.len], prefix)) continue;
        const key = try std.ascii.allocLowerString(a, line[prefix.len..colon]);
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        try result.object.put(a, key, .{ .string = value });
    }
    return result;
}
pub fn failure(a: A, json: bool, code: []const u8, message: []const u8, n: u8) !Output {
    return .{ .exit_code = n, .stderr = try std.fmt.allocPrint(a, "{s}\n", .{try std.json.Stringify.valueAlloc(a, .{ .schema_version = 1, .type = "error", .status = "error", .@"error" = .{ .code = code, .message = message } }, .{ .whitespace = if (json) .minified else .indent_2 })}) };
}
pub fn check(a: A, json: bool, r: Reply) !?Output {
    if (r.transport != 0) return try failure(a, json, "NETWORK_ERROR", "request failed; mutation outcome may be unknown; no automatic retry", if (r.transport == 42) 130 else 3);
    if (r.status >= 200 and r.status < 300) return null;
    if (r.status == 409) {
        if (std.json.parseFromSlice(V, a, r.body, .{})) |parsed| {
            const value = parsed.value;
            if (value == .object) {
                if (value.object.get("code")) |code| {
                    if (code == .string and eq(code.string, "CursorExpired")) {
                        return try failure(a, json, "CURSOR_EXPIRED", "event cursor expired or server restarted; explicit restart without cursor required; events may have been lost", 6);
                    }
                }
            }
        } else |_| {}
    }
    if (r.status == 404) {
        if (@import("xml.zig").parse(a, r.body)) |root| {
            if (@import("xml.zig").child(root, "Code")) |code| {
                if (eq(code, "NoSuchLifecycleConfiguration") or eq(code, "NoSuchTagSet")) {
                    return try failure(a, json, "NO_CONFIGURATION", "requested bucket configuration is absent", 5);
                }
            }
        } else |_| {}
    }

    return try failure(a, json, "REMOTE_ERROR", "remote rejected request; response body omitted; no automatic retry", if (r.status == 401 or r.status == 403) 4 else if (r.status == 404) 5 else if (r.status == 409 or r.status == 412 or (r.status >= 300 and r.status < 400)) 6 else if (r.status == 501) 7 else 1);
}
pub fn output(a: A, json: bool, quiet: bool, kind: []const u8, data: anytype) !Output {
    if (quiet and !json) return .{};
    return .{ .stdout = try std.fmt.allocPrint(a, "{s}\n", .{try std.json.Stringify.valueAlloc(a, .{ .schema_version = 1, .type = kind, .status = "success", .data = data }, .{ .whitespace = if (json) .minified else .indent_2 })}) };
}
/// Read an explicitly supplied JSON payload, with bounded stdin support.
pub fn readInputJson(a: A, io: Io, path: []const u8) !V {
    if (!eq(path, "-")) return readJson(a, io, path);
    var bytes: std.ArrayList(u8) = .empty;
    var buffer: [8192]u8 = undefined;
    while (true) {
        const count = Io.File.stdin().readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };
        if (count == 0) break;
        if (bytes.items.len + count > 4 * 1024 * 1024) return error.InvalidInput;
        try bytes.appendSlice(a, buffer[0..count]);
    }
    return (std.json.parseFromSlice(V, a, bytes.items, .{}) catch return error.InvalidInput).value;
}
pub fn readJson(a: A, io: Io, path: []const u8) !V {
    const f = try Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false });
    defer f.close(io);
    const stat = try f.stat(io);
    if (stat.kind != .file or stat.size > 4 * 1024 * 1024) return error.InvalidInput;
    const b = try a.alloc(u8, @intCast(stat.size));
    if (try f.readPositionalAll(io, b, 0) != b.len) return error.InvalidInput;
    return (std.json.parseFromSlice(V, a, b, .{}) catch return error.InvalidInput).value;
}
