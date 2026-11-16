const std = @import("std");
const builtin = @import("builtin");
const aliases = @import("alias.zig");
const signing = @import("signing.zig");
const xml = @import("xml.zig");
const A = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;
const max_control = 4 * 1024 * 1024;
const ReadFn = *const fn (?*anyopaque, [*]u8, usize) callconv(.c) usize;
const WriteFn = *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) c_int;
extern fn zc_http([*:0]const u8, [*:0]const u8, [*]const [*:0]const u8, usize, [*:0]const u8, c_int, c_long, c_long, c_int, i64, ?ReadFn, ?WriteFn, ?*anyopaque, [*]u8, usize, *usize, [*]u8, usize, *usize, *c_long) c_int;
pub const Output = struct { exit_code: u8 = 0, stdout: []const u8 = "", stderr: []const u8 = "" };

pub const Operation = enum { @"create-bucket", @"list-buckets", @"head-bucket", @"get-bucket-location", @"list-objects-v2", @"head-object", @"get-object", @"put-object" };
pub fn isFlag(name: []const u8) bool {
    for ([_][]const u8{ "--insecure", "--yes", "--generate-input-skeleton" }) |f| if (eq(f, name)) return true;
    return false;
}
pub fn isValueOption(name: []const u8) bool {
    for ([_][]const u8{ "--input-json", "--body", "--output", "--region", "--endpoint", "--bucket-lookup", "--ca-cert", "--connect-timeout", "--timeout", "--retry-attempts", "--header", "-H" }) |f| if (eq(f, name)) return true;
    return false;
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn isObject(op: Operation) bool {
    return op == .@"head-object" or op == .@"get-object" or op == .@"put-object";
}
fn allowed(op: Operation, field: []const u8) bool {
    if (eq(field, "Bucket")) return op != .@"list-buckets";
    if (eq(field, "ExpectedBucketOwner")) return op != .@"list-buckets" and op != .@"create-bucket";
    if (op == .@"create-bucket") return eq(field, "CreateBucketConfiguration");
    if (eq(field, "Key")) return isObject(op);
    if (eq(field, "RequestPayer")) return isObject(op) or op == .@"list-objects-v2";
    if (op == .@"list-buckets") return in(field, &.{ "Prefix", "ContinuationToken", "MaxBuckets", "BucketRegion" });
    if (op == .@"list-objects-v2") return in(field, &.{ "Prefix", "Delimiter", "ContinuationToken", "StartAfter", "MaxKeys", "EncodingType", "FetchOwner" });
    if (op == .@"head-object" or op == .@"get-object") return in(field, &.{ "VersionId", "Range", "IfMatch", "IfNoneMatch", "IfModifiedSince", "IfUnmodifiedSince", "PartNumber", "ChecksumMode" });
    if (op == .@"put-object") return in(field, &.{ "Body", "ContentType", "CacheControl", "ContentDisposition", "ContentEncoding", "ContentLanguage", "Metadata", "IfMatch", "IfNoneMatch" });
    return false;
}
fn in(value: []const u8, list: []const []const u8) bool {
    for (list) |v| if (eq(value, v)) return true;
    return false;
}
fn get(input: Value, key: []const u8) ?Value {
    return input.object.get(key);
}
fn string(input: Value, key: []const u8) ?[]const u8 {
    const value = get(input, key) orelse return null;
    return if (value == .string) value.string else null;
}
fn safeValue(value: []const u8) !void {
    for (value) |c| if (c == '\r' or c == '\n' or c == 0 or c == 127) return error.InvalidInput;
}
fn validateInput(op: Operation, input: Value) !void {
    if (input != .object) return error.InvalidInput;
    var it = input.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (!allowed(op, key)) return error.UnknownInputField;
        if (in(key, &.{ "MaxKeys", "MaxBuckets", "PartNumber" })) {
            const max: i64 = if (eq(key, "MaxBuckets") or eq(key, "PartNumber")) 10000 else 1000;
            if (value != .integer or value.integer < 1 or value.integer > max) return error.InvalidInput;
        } else if (eq(key, "FetchOwner")) {
            if (value != .bool) return error.InvalidInput;
        } else if (eq(key, "CreateBucketConfiguration")) {
            if (value != .object or value.object.count() != 1) return error.InvalidInput;
            const location = value.object.get("LocationConstraint") orelse return error.UnknownInputField;
            if (location != .string or location.string.len == 0) return error.InvalidInput;
            try safeValue(location.string);
        } else if (eq(key, "Metadata")) {
            if (value != .object) return error.InvalidInput;
            var metadata = value.object.iterator();
            while (metadata.next()) |m| {
                if (m.value_ptr.* != .string or m.key_ptr.len == 0) return error.InvalidInput;
                for (m.key_ptr.*) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return error.InvalidInput;
                try safeValue(m.value_ptr.string);
            }
        } else {
            if (value != .string) return error.InvalidInput;
            try safeValue(value.string);
        }
    }
    if (op != .@"list-buckets") {
        const bucket = string(input, "Bucket") orelse return error.InvalidInput;
        if (bucket.len < 3 or bucket.len > 63 or !std.ascii.isAlphanumeric(bucket[0]) or !std.ascii.isAlphanumeric(bucket[bucket.len - 1])) return error.InvalidInput;
        for (bucket) |c| if (!(c >= 'a' and c <= 'z') and !std.ascii.isDigit(c) and c != '-' and c != '.') return error.InvalidInput;
    }
    if (isObject(op)) {
        const key = string(input, "Key") orelse return error.InvalidInput;
        if (key.len == 0 or key.len > 1024) return error.InvalidInput;
    }
    if (string(input, "VersionId")) |v| if (v.len == 0) return error.InvalidInput;
    if (string(input, "RequestPayer")) |v| if (!eq(v, "requester")) return error.InvalidInput;
    if (string(input, "EncodingType")) |v| if (!eq(v, "url")) return error.InvalidInput;
    if (string(input, "ChecksumMode")) |v| if (!eq(v, "ENABLED")) return error.InvalidInput;
}
const Args = struct {
    alias_name: ?[]const u8 = null,
    values: std.StringHashMapUnmanaged([]const u8) = .empty,
    flags: std.StringHashMapUnmanaged(void) = .empty,
    headers: std.ArrayList(signing.Header) = .empty,
};
fn parseArgs(a: A, args: []const []const u8) !Args {
    var r: Args = .{};
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
            const name = if (split) |n| arg[0..n] else arg;
            if (r.values.contains(name) or r.flags.contains(name)) return error.InvalidInput;
            if (isFlag(name)) {
                if (split != null) return error.InvalidInput;
                try r.flags.put(a, name, {});
            } else if (isValueOption(name)) {
                const v = if (split) |n| arg[n + 1 ..] else blk: {
                    i += 1;
                    if (i == args.len) return error.InvalidInput;
                    break :blk args[i];
                };
                if (v.len == 0) return error.InvalidInput;
                if (eq(name, "--header") or eq(name, "-H")) {
                    const colon = std.mem.indexOfScalar(u8, v, ':') orelse return error.InvalidInput;
                    const header_name = try std.ascii.allocLowerString(a, v[0..colon]);
                    if (!std.mem.startsWith(u8, header_name, "x-amz-") or in(header_name, &.{ "x-amz-date", "x-amz-content-sha256", "x-amz-security-token" })) return error.InvalidHeader;
                    try safeValue(v[colon + 1 ..]);
                    try r.headers.append(a, .{ .name = header_name, .value = v[colon + 1 ..] });
                } else try r.values.put(a, name, v);
            } else return error.InvalidInput;
        } else {
            if (r.alias_name != null) return error.InvalidInput;
            r.alias_name = arg;
        }
    }
    return r;
}
fn readInput(a: A, io: Io, path: []const u8) ![]const u8 {
    if (!eq(path, "-")) return Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
    var result: std.ArrayList(u8) = .empty;
    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = Io.File.stdin().readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        if (result.items.len + n > 1024 * 1024) return error.InvalidInput;
        try result.appendSlice(a, buffer[0..n]);
    }
    return result.items;
}
fn number(r: Args, key: []const u8) !?u32 {
    return if (r.values.get(key)) |v| std.fmt.parseInt(u32, v, 10) catch return error.InvalidInput else null;
}
fn pair(a: A, pairs: *std.ArrayList(signing.Pair), input: Value, key: []const u8, name: []const u8) !void {
    if (get(input, key)) |v| try pairs.append(a, .{ .name = name, .value = switch (v) {
        .string => v.string,
        .integer => try std.fmt.allocPrint(a, "{d}", .{v.integer}),
        .bool => if (v.bool) "true" else "false",
        else => return error.InvalidInput,
    } });
}
fn fieldHeader(a: A, headers: *std.ArrayList(signing.Header), input: Value, key: []const u8, name: []const u8) !void {
    if (string(input, key)) |v| try headers.append(a, .{ .name = name, .value = v });
}
const Transfer = struct {
    io: Io,
    input: ?Io.File = null,
    bytes: []const u8 = "",
    read_offset: u64 = 0,
    output: ?Io.File = null,
    stdout: bool = false,
    written: u64 = 0,
    failed: bool = false,
};
fn readBody(opaque_ctx: ?*anyopaque, buffer: [*]u8, capacity: usize) callconv(.c) usize {
    const t: *Transfer = @ptrCast(@alignCast(opaque_ctx.?));
    const n = if (t.input) |f| f.readPositionalAll(t.io, buffer[0..capacity], t.read_offset) catch {
        t.failed = true;
        return std.math.maxInt(usize);
    } else blk: {
        const n = @min(capacity, t.bytes.len - @as(usize, @intCast(t.read_offset)));
        @memcpy(buffer[0..n], t.bytes[@intCast(t.read_offset)..][0..n]);
        break :blk n;
    };
    t.read_offset += n;
    return n;
}
fn writeBody(opaque_ctx: ?*anyopaque, buffer: [*]const u8, length: usize) callconv(.c) c_int {
    const t: *Transfer = @ptrCast(@alignCast(opaque_ctx.?));
    if (t.stdout) Io.File.stdout().writeStreamingAll(t.io, buffer[0..length]) catch {
        t.failed = true;
        return 1;
    } else t.output.?.writePositionalAll(t.io, buffer[0..length], t.written) catch {
        t.failed = true;
        return 1;
    };
    t.written += length;
    return 0;
}
fn bodyHash(t: *Transfer) ![64]u8 {
    if (t.input == null) return signing.hash(t.bytes);
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [65536]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try t.input.?.readPositionalAll(t.io, &buffer, offset);
        if (n == 0) break;
        sha.update(buffer[0..n]);
        offset += n;
    }
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}
fn responseHeader(bytes: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, bytes, "\r\n");
    var result: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "HTTP/")) {
            result = null;
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], key)) result = std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return result;
}
fn safeId(value: ?[]const u8, connection: aliases.Alias) ?[]const u8 {
    const text = value orelse return null;
    if (text.len == 0 or text.len > 256) return null;
    for (text) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "-_/+=.", c) == null) return null;
    for ([_][]const u8{ connection.access_key, connection.secret_key, connection.session_token }) |secret| if (secret.len > 0 and std.mem.indexOf(u8, text, secret) != null) return null;
    return text;
}
fn errorCode(status: c_long, s3_code: []const u8) u8 {
    if (status == 401 or status == 403 or in(s3_code, &.{ "AccessDenied", "InvalidAccessKeyId", "SignatureDoesNotMatch", "ExpiredToken", "InvalidToken", "RequestTimeTooSkewed" })) return 4;
    if (status == 404 or in(s3_code, &.{ "NoSuchKey", "NoSuchBucket", "NoSuchVersion" })) return 5;
    if (status == 409 or status == 412 or status == 304) return 6;
    if (status == 501 or eq(s3_code, "NotImplemented")) return 7;
    if (status == 408 or status == 429 or status >= 500) return 3;
    if (status >= 300 and status < 400) return 6;
    return 1;
}
fn failure(a: A, json: bool, code: []const u8, message: []const u8, exit_code: u8, status: c_long, request_id: ?[]const u8, attempts: u32) !Output {
    const text = if (json) try std.json.Stringify.valueAlloc(a, .{ .schema_version = 1, .type = "error", .status = "error", .@"error" = .{ .code = code, .message = message, .status_code = status, .request_id = request_id, .attempts = attempts } }, .{}) else try std.fmt.allocPrint(a, "zc: {s}: {s} (HTTP {d}, attempts {d})", .{ code, message, status, attempts });
    return .{ .exit_code = exit_code, .stderr = try std.fmt.allocPrint(a, "{s}\n", .{text}) };
}
fn skeleton(a: A, op: Operation) ![]const u8 {
    var object: std.json.ObjectMap = .{};
    if (op != .@"list-buckets") try object.put(a, "Bucket", .{ .string = "example-bucket" });
    if (isObject(op)) try object.put(a, "Key", .{ .string = "example.txt" });
    if (op == .@"list-objects-v2") {
        try object.put(a, "Prefix", .{ .string = "" });
        try object.put(a, "MaxKeys", .{ .integer = 1000 });
    }
    if (op == .@"put-object") try object.put(a, "ContentType", .{ .string = "application/octet-stream" });
    return std.json.Stringify.valueAlloc(a, Value{ .object = object }, .{ .whitespace = .indent_2 });
}
pub fn execute(a: A, ctx: aliases.Context, operation: []const u8, args: []const []const u8, config_path: ?[]const u8, json: bool, quiet: bool) anyerror!Output {
    const op = std.meta.stringToEnum(Operation, operation) orelse return error.UnsupportedOperation;
    const r = try parseArgs(a, args);
    if (r.flags.contains("--generate-input-skeleton")) {
        if (r.values.count() != 0 or r.headers.items.len != 0 or r.flags.count() != 1) return error.InvalidInput;
        return .{ .stdout = try std.fmt.allocPrint(a, "{s}\n", .{try skeleton(a, op)}) };
    }
    const input_bytes = if (r.values.get("--input-json")) |p| try readInput(a, ctx.io, p) else "{}";
    const input = (std.json.parseFromSlice(Value, a, input_bytes, .{ .allocate = .alloc_always }) catch return error.InvalidInput).value;
    try validateInput(op, input);
    if (op == .@"put-object" and !r.flags.contains("--yes")) return error.ConfirmationRequired;
    if (op != .@"put-object" and (r.values.contains("--body") or r.flags.contains("--yes"))) return error.InvalidInput;
    if (op != .@"get-object" and r.values.contains("--output")) return error.InvalidInput;
    const output_path = r.values.get("--output") orelse "-";
    const stdout = op == .@"get-object" and eq(output_path, "-");
    if (stdout and json) return error.RawOutputConflict;
    const retry_limit = (try number(r, "--retry-attempts")) orelse 3;
    if (retry_limit == 0 or retry_limit > 5) return error.InvalidInput;
    const connection = try aliases.connection(a, ctx, config_path, r.alias_name orelse return error.InvalidInput, .{ .endpoint = r.values.get("--endpoint"), .region = r.values.get("--region"), .bucket_lookup = r.values.get("--bucket-lookup"), .insecure = if (r.flags.contains("--insecure")) true else null, .ca_cert = r.values.get("--ca-cert"), .connect_timeout = try number(r, "--connect-timeout"), .timeout = try number(r, "--timeout") });
    const endpoint = try std.Uri.parse(connection.endpoint);
    const host = switch (endpoint.host.?) {
        .raw => |v| v,
        .percent_encoded => |v| v,
    };
    const bucket = string(input, "Bucket");
    // auto deliberately chooses portable path-style, not a potentially unsafe DNS guess.
    const dns = eq(connection.bucket_lookup, "dns") and bucket != null;
    if (dns and (std.mem.indexOfScalar(u8, host, ':') != null or std.mem.indexOfScalar(u8, host, '[') != null)) return error.InvalidInput;
    const authority = if (dns) try std.fmt.allocPrint(a, "{s}.{s}", .{ bucket.?, host }) else host;
    const host_header = if (endpoint.port) |port| try std.fmt.allocPrint(a, "{s}:{d}", .{ authority, port }) else authority;
    const raw_path = if (bucket) |b| if (string(input, "Key")) |key| if (dns) try std.fmt.allocPrint(a, "/{s}", .{key}) else try std.fmt.allocPrint(a, "/{s}/{s}", .{ b, key }) else if (dns) "/" else try std.fmt.allocPrint(a, "/{s}", .{b}) else "/";
    const path = try signing.encode(a, raw_path, true);
    var pairs: std.ArrayList(signing.Pair) = .empty;
    if (op == .@"get-bucket-location") try pairs.append(a, .{ .name = "location", .value = "" });
    if (op == .@"list-objects-v2") try pairs.append(a, .{ .name = "list-type", .value = "2" });
    inline for (.{ .{ "Prefix", "prefix" }, .{ "Delimiter", "delimiter" }, .{ "ContinuationToken", "continuation-token" }, .{ "MaxKeys", "max-keys" }, .{ "StartAfter", "start-after" }, .{ "EncodingType", "encoding-type" }, .{ "FetchOwner", "fetch-owner" }, .{ "MaxBuckets", "max-buckets" }, .{ "BucketRegion", "bucket-region" }, .{ "VersionId", "versionId" }, .{ "PartNumber", "partNumber" } }) |mapping| try pair(a, &pairs, input, mapping[0], mapping[1]);
    const query = try signing.query(a, pairs.items);
    const url = try std.fmt.allocPrintSentinel(a, "{s}://{s}{s}{s}{s}", .{ endpoint.scheme, host_header, path, if (query.len > 0) "?" else "", query }, 0);
    const method: [:0]const u8 = if (op == .@"put-object" or op == .@"create-bucket") "PUT" else if (op == .@"head-bucket" or op == .@"head-object") "HEAD" else "GET";
    var transfer: Transfer = .{ .io = ctx.io, .stdout = stdout };
    defer if (transfer.input) |f| f.close(ctx.io);
    var body_size: u64 = 0;
    if (op == .@"put-object") {
        if (r.values.get("--body")) |body_path| {
            if (get(input, "Body") != null or eq(body_path, "-")) return error.InvalidInput;
            transfer.input = try Io.Dir.cwd().openFile(ctx.io, body_path, .{});
            const stat = try transfer.input.?.stat(ctx.io);
            if (stat.kind != .file or stat.size > std.math.maxInt(i64)) return error.InvalidInput;
            body_size = stat.size;
        } else if (string(input, "Body")) |body| {
            const decoder = std.base64.standard.Decoder;
            const decoded = try a.alloc(u8, decoder.calcSizeForSlice(body) catch return error.InvalidInput);
            decoder.decode(decoded, body) catch return error.InvalidInput;
            transfer.bytes = decoded;
            body_size = decoded.len;
        } else return error.InvalidInput;
    }
    if (op == .@"create-bucket") {
        if (get(input, "CreateBucketConfiguration")) |configuration| {
            transfer.bytes = try xml.encode(a, .{ .name = "CreateBucketConfiguration", .text = "", .children = &.{.{ .name = "LocationConstraint", .text = configuration.object.get("LocationConstraint").?.string, .children = &.{} }} }, "http://s3.amazonaws.com/doc/2006-03-01/");
            body_size = transfer.bytes.len;
        }
    }
    const payload_hash = try bodyHash(&transfer);
    var atomic: ?Io.File.Atomic = null;
    defer if (atomic) |*f| f.deinit(ctx.io);
    if (op == .@"get-object" and !stdout) {
        // Refuse overwrite before making any network request.
        Io.Dir.cwd().access(ctx.io, output_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        if (Io.Dir.cwd().statFile(ctx.io, output_path, .{ .follow_symlinks = false })) |_| return error.PathAlreadyExists else |err| if (err != error.FileNotFound) return err;
        atomic = try Io.Dir.cwd().createFileAtomic(ctx.io, output_path, .{ .permissions = if (builtin.os.tag == .windows) .default_file else @fromBackingInt(@intCast(0o600)) });
        transfer.output = atomic.?.file;
    }
    const body_buffer = try a.alloc(u8, max_control);
    const header_buffer = try a.alloc(u8, 64 * 1024);
    const ca = try a.dupeSentinel(u8, connection.ca_cert, 0);
    const deadline = Io.Clock.awake.now(ctx.io).toMilliseconds() + @as(i64, connection.timeout) * 1000;
    var attempt: u32 = 0;
    while (true) {
        attempt += 1;
        var headers: std.ArrayList(signing.Header) = .empty;
        const date = try signing.timestamp(a, @intCast(Io.Clock.real.now(ctx.io).toSeconds()));
        try headers.appendSlice(a, &.{ .{ .name = "host", .value = host_header }, .{ .name = "x-amz-date", .value = date }, .{ .name = "x-amz-content-sha256", .value = &payload_hash } });
        if (connection.session_token.len > 0) try headers.append(a, .{ .name = "x-amz-security-token", .value = connection.session_token });
        inline for (.{ .{ "ExpectedBucketOwner", "x-amz-expected-bucket-owner" }, .{ "RequestPayer", "x-amz-request-payer" }, .{ "ChecksumMode", "x-amz-checksum-mode" }, .{ "Range", "range" }, .{ "IfMatch", "if-match" }, .{ "IfNoneMatch", "if-none-match" }, .{ "IfModifiedSince", "if-modified-since" }, .{ "IfUnmodifiedSince", "if-unmodified-since" }, .{ "ContentType", "content-type" }, .{ "CacheControl", "cache-control" }, .{ "ContentDisposition", "content-disposition" }, .{ "ContentEncoding", "content-encoding" }, .{ "ContentLanguage", "content-language" } }) |mapping| try fieldHeader(a, &headers, input, mapping[0], mapping[1]);
        if (get(input, "Metadata")) |metadata| {
            var it = metadata.object.iterator();
            while (it.next()) |m| try headers.append(a, .{ .name = try std.fmt.allocPrint(a, "x-amz-meta-{s}", .{m.key_ptr.*}), .value = m.value_ptr.string });
        }
        try headers.appendSlice(a, r.headers.items);
        const signed = try signing.sign(a, method, path, query, headers.items, &payload_hash, date, connection.region, connection.access_key, connection.secret_key);
        var wire: std.ArrayList([*:0]const u8) = .empty;
        for (signed.headers) |h| try wire.append(a, if (h.value.len == 0) try std.fmt.allocPrintSentinel(a, "{s};", .{h.name}, 0) else try std.fmt.allocPrintSentinel(a, "{s}: {s}", .{ h.name, h.value }, 0));
        try wire.append(a, try std.fmt.allocPrintSentinel(a, "Authorization: {s}", .{signed.authorization}, 0));
        try wire.append(a, "Expect:");
        var body_len: usize = 0;
        var header_len: usize = 0;
        var status: c_long = 0;
        const remaining = deadline - Io.Clock.awake.now(ctx.io).toMilliseconds();
        if (remaining <= 0) return failure(a, json, "NETWORK_ERROR", "request deadline exceeded", 3, 0, null, attempt - 1);
        const result = zc_http(url, method, wire.items.ptr, wire.items.len, ca, @intFromBool(connection.insecure), @intCast(@min(remaining, @as(i64, connection.connect_timeout) * 1000)), @intCast(remaining), @intFromBool(eq(method, "PUT")), @intCast(body_size), if (eq(method, "PUT")) readBody else null, if (op == .@"get-object") writeBody else null, &transfer, header_buffer.ptr, header_buffer.len, &header_len, body_buffer.ptr, body_buffer.len, &body_len, &status);
        const request_id = safeId(responseHeader(header_buffer[0..header_len], "x-amz-request-id"), connection);
        const transient = inResult(result, &.{ 5, 6, 7, 18, 28, 52, 55, 56 }) or result == 0 and (status == 408 or status == 429 or status == 500 or status == 502 or status == 503 or status == 504);
        if (transient and !eq(method, "PUT") and attempt < retry_limit and !transfer.failed and !(stdout and transfer.written != 0)) {
            const wait_ms: i64 = @as(i64, 100) << @intCast(attempt - 1);
            if (Io.Clock.awake.now(ctx.io).toMilliseconds() + wait_ms < deadline) {
                if (transfer.output) |file| try file.setLength(ctx.io, 0);
                transfer.written = 0;
                transfer.read_offset = 0;
                try Io.sleep(ctx.io, .fromMilliseconds(wait_ms), .awake);
                continue;
            }
        }
        if (transfer.failed) return failure(a, json, "IO_ERROR", "local transfer I/O failed", 1, status, request_id, attempt);
        if (result == -2) return failure(a, json, "INVALID_RESPONSE", "response exceeds the bounded control/header limit", 1, status, request_id, attempt);
        if (result != 0) return failure(a, json, if (inResult(result, &.{ 35, 51, 58, 60, 77, 83, 90, 91 })) "TLS_ERROR" else "NETWORK_ERROR", "connection or transfer failed; no credentials or raw diagnostics are logged", 3, status, request_id, attempt);
        if (status < 200 or status >= 300) {
            var code: []const u8 = "S3_ERROR";
            if (body_len > 0) {
                if (xml.parse(a, body_buffer[0..body_len])) |root| {
                    if (xml.child(root, "Code")) |server_code| if (in(server_code, &.{ "AccessDenied", "InvalidAccessKeyId", "SignatureDoesNotMatch", "ExpiredToken", "InvalidToken", "RequestTimeTooSkewed", "NoSuchKey", "NoSuchBucket", "NoSuchVersion", "PreconditionFailed", "NotImplemented", "SlowDown", "InternalError", "InvalidArgument" })) {
                        code = server_code;
                    };
                } else |_| {}
            }
            return failure(a, json, code, if (status >= 300 and status < 400) "redirect or conditional response; redirects are not followed" else "S3 request failed (server message redacted)", errorCode(status, code), status, request_id, attempt);
        }
        var decoded: Value = .null;
        const expected_root: ?[]const u8 = switch (op) {
            .@"list-buckets" => "ListAllMyBucketsResult",
            .@"list-objects-v2" => "ListBucketResult",
            .@"get-bucket-location" => "LocationConstraint",
            else => null,
        };
        if (expected_root != null and body_len == 0) return failure(a, json, "INVALID_RESPONSE", "missing S3 XML response", 1, status, request_id, attempt);
        if (body_len > 0) {
            const root = xml.parse(a, body_buffer[0..body_len]) catch return failure(a, json, "INVALID_RESPONSE", "invalid S3 XML response", 1, status, request_id, attempt);
            if (eq(root.name, "Error")) return failure(a, json, "S3_ERROR", "S3 returned an error inside a successful HTTP response", 1, status, request_id, attempt);
            if (expected_root) |expected| if (!eq(root.name, expected)) return failure(a, json, "INVALID_RESPONSE", "unexpected S3 XML root element", 1, status, request_id, attempt);
            decoded = try xml.toJson(a, root);
        }
        if (atomic) |*f| {
            try f.file.sync(ctx.io);
            try f.link(ctx.io);
        }
        if (stdout or quiet and !json) return .{};
        const data = .{ .operation = operation, .status_code = status, .request_id = request_id, .attempts = attempt, .result = decoded, .bytes_written = transfer.written, .headers = .{ .etag = responseHeader(header_buffer[0..header_len], "etag"), .version_id = responseHeader(header_buffer[0..header_len], "x-amz-version-id"), .content_length = responseHeader(header_buffer[0..header_len], "content-length"), .content_type = responseHeader(header_buffer[0..header_len], "content-type") } };
        const output = if (json) try std.json.Stringify.valueAlloc(a, .{ .schema_version = 1, .type = "s3api", .status = "success", .data = data }, .{}) else try std.json.Stringify.valueAlloc(a, data, .{ .whitespace = .indent_2 });
        return .{ .stdout = try std.fmt.allocPrint(a, "{s}\n", .{output}) };
    }
}
fn inResult(value: c_int, values: []const c_int) bool {
    for (values) |v| if (v == value) return true;
    return false;
}
pub const help =
    \\S3 protocol entry (only registered operations are available):
    \\  zc s3api OPERATION ALIAS [--input-json FILE|-] [OPTIONS]
    \\  zc s3api OPERATION --generate-input-skeleton
    \\Options: --endpoint URL --region REGION --bucket-lookup path|dns|auto
    \\  --ca-cert FILE --insecure --connect-timeout SECONDS --timeout SECONDS
    \\  --retry-attempts 1..5 (default 3; GET/HEAD only) -H x-amz-NAME:VALUE
    \\  --body FILE (put-object; regular file only) --yes (required for put-object)
    \\  --output FILE|- (get-object; refuses existing files; JSON requires FILE)
    \\Input is a JSON object using AWS field names; unknown fields are rejected.
    \\CreateBucketConfiguration accepts only LocationConstraint in this step.
    \\Bucket and Key are required where applicable. put-object also needs --body
    \\or base64 Body; both cannot be combined. JSON input is limited to 1 MiB.
    \\Read fields: VersionId, Range, IfMatch, IfNoneMatch, IfModifiedSince,
    \\  IfUnmodifiedSince, PartNumber, ChecksumMode; Get/Head only.
    \\ListObjectsV2 fields: Prefix, Delimiter, ContinuationToken, StartAfter,
    \\  MaxKeys (1..1000), EncodingType=url, FetchOwner. One page per request.
    \\ListBuckets fields: Prefix, ContinuationToken, MaxBuckets, BucketRegion.
    \\Put fields: ContentType, CacheControl, ContentDisposition, ContentEncoding,
    \\  ContentLanguage, Metadata, IfMatch, IfNoneMatch. VersionId is not a Put field.
    \\ExpectedBucketOwner applies except ListBuckets/CreateBucket; RequestPayer=requester
    \\applies to object operations/ListObjectsV2. Advanced fields await later steps.
    \\Redirects/proxies are disabled. TLS verification is on unless explicitly disabled.
    \\Timeout includes retries and transfer; PUT is never automatically retried.
    \\Example: zc s3api list-buckets local --json
    \\         zc s3api get-object local --input-json object.json --output saved.bin
    \\
;
test "request validation rejects unknown fields and invalid types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const invalid = (try std.json.parseFromSlice(Value, a, "{\"Bucket\":\"bucket\",\"Unknown\":true}", .{})).value;
    try std.testing.expectError(error.UnknownInputField, validateInput(.@"head-bucket", invalid));
    const valid = (try std.json.parseFromSlice(Value, a, "{\"Bucket\":\"bucket\",\"Key\":\"a//../中 +%\"}", .{})).value;
    try validateInput(.@"get-object", valid);
}
test {
    std.testing.refAllDecls(signing);
    std.testing.refAllDecls(xml);
}
