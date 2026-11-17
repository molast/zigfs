//! Independent bearer-authenticated Management API client. No data-directory access.
const std = @import("std");
const aliases = @import("alias.zig");
const wire = @import("wire.zig");
const modeled = @import("modeled.zig");
const signing = @import("signing.zig");
const A = std.mem.Allocator;
const V = std.json.Value;
const Io = std.Io;
fn sessionPath(a: A, ctx: aliases.Context, config: ?[]const u8, endpoint: []const u8) ![]const u8 {
    const path = try aliases.configPath(a, ctx.env, config);
    const dir = try std.fmt.allocPrint(a, "{s}.sessions", .{path});
    try Io.Dir.cwd().createDirPath(ctx.io, dir);
    return std.fmt.allocPrint(a, "{s}/{s}.json", .{ dir, signing.hash(endpoint) });
}
fn privateJson(a: A, ctx: aliases.Context, path: []const u8) !V {
    const stat = try Io.Dir.cwd().statFile(ctx.io, path, .{});
    if (@backingInt(stat.permissions) & 0o077 != 0) return error.InsecurePermissions;
    return wire.readJson(a, ctx.io, path);
}
fn save(a: A, ctx: aliases.Context, path: []const u8, data: V) !void {
    var file = try Io.Dir.cwd().createFileAtomic(ctx.io, path, .{ .replace = true, .permissions = @fromBackingInt(0o600) });
    defer file.deinit(ctx.io);
    try file.file.writeStreamingAll(ctx.io, try std.json.Stringify.valueAlloc(a, data, .{}));
    try file.file.sync(ctx.io);
    try file.replace(ctx.io);
}
fn sensitive(name: []const u8) bool {
    var lower: [256]u8 = undefined;
    if (name.len > lower.len) return true;
    for (name, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    const n = lower[0..name.len];
    for ([_][]const u8{ "secret", "password", "token", "private_key", "authorization", "credential" }) |part| if (std.mem.indexOf(u8, n, part) != null) return true;
    return false;
}
fn redact(v: *V) void {
    if (v.* == .object) {
        var it = v.object.iterator();
        while (it.next()) |e| {
            if (sensitive(e.key_ptr.*)) e.value_ptr.* = .{ .string = "[REDACTED]" } else redact(e.value_ptr);
        }
    } else if (v.* == .array) for (v.array.items) |*item| redact(item);
}
fn reference(model: V, schema: V) !V {
    if (modeled.text(schema, "$ref")) |ref| {
        if (!std.mem.startsWith(u8, ref, "#/")) return error.InvalidInput;
        var path = std.mem.splitScalar(u8, ref[2..], '/');
        var current = model;
        while (path.next()) |part| current = modeled.get(current, part) orelse return error.InvalidInput;
        return current;
    }
    return schema;
}
fn validate(model: V, schema_ref: V, value: V, depth: usize, partial: bool) anyerror!void {
    if (depth > 32) return error.InvalidInput;
    const s = try reference(model, schema_ref);
    if (modeled.get(s, "allOf")) |list| {
        for (list.array.items) |child| try validate(model, child, value, depth + 1, partial);
        return;
    }
    const typ = modeled.text(s, "type") orelse return;
    if (wire.eq(typ, "object")) {
        if (value != .object) return error.InvalidInput;
        if (!partial) if (modeled.get(s, "required")) |required| for (required.array.items) |key| if (!value.object.contains(key.string)) return error.InvalidInput;
        var it = value.object.iterator();
        while (it.next()) |entry| {
            if (modeled.get(modeled.get(s, "properties") orelse .null, entry.key_ptr.*)) |field| try validate(model, field, entry.value_ptr.*, depth + 1, false) else if (modeled.get(s, "additionalProperties")) |additional| {
                if (additional == .bool and !additional.bool) return error.UnknownInputField;
                if (additional == .object) try validate(model, additional, entry.value_ptr.*, depth + 1, false);
            }
        }
    } else if (wire.eq(typ, "array")) {
        if (value != .array or value.array.items.len > 100000) return error.InvalidInput;
        if (modeled.get(s, "items")) |items| for (value.array.items) |item| try validate(model, items, item, depth + 1, false);
    } else if (wire.eq(typ, "string")) {
        if (value != .string) return error.InvalidInput;
    } else if (wire.eq(typ, "integer")) {
        if (value != .integer) return error.InvalidInput;
    } else if (wire.eq(typ, "number")) {
        if (value != .integer and value != .float) return error.InvalidInput;
    } else if (wire.eq(typ, "boolean")) {
        if (value != .bool) return error.InvalidInput;
    }
    if (modeled.get(s, "enum")) |en| {
        var found = false;
        for (en.array.items) |v| if (v == .string and value == .string and wire.eq(v.string, value.string)) {
            found = true;
            break;
        };
        if (!found) return error.InvalidInput;
    }
}
pub fn execute(a: A, ctx: aliases.Context, action: []const u8, args: []const []const u8, config: ?[]const u8, json: bool, quiet: bool) anyerror!wire.Output {
    return executeBody(a, ctx, action, args, config, json, quiet, null);
}
pub fn executeBody(a: A, ctx: aliases.Context, action: []const u8, args: []const []const u8, config: ?[]const u8, json: bool, quiet: bool, supplied: ?V) anyerror!wire.Output {
    const r = try modeled.parse(a, args);
    var flags = r.flags.keyIterator();
    while (flags.next()) |flag| {
        if (!wire.eq(flag.*, "--yes") and !wire.eq(flag.*, "--dry-run") and !wire.eq(flag.*, "--overwrite") and !wire.eq(flag.*, "--insecure")) return error.InvalidInput;
    }
    if (r.headers.items.len != 0) return error.InvalidInput;
    if (r.values.contains("--output") and !std.mem.endsWith(u8, action, " download")) return error.InvalidInput;
    const routes = (try std.json.parseFromSlice(V, a, @embedFile("models/management-routes.json"), .{})).value;
    var route: ?V = null;
    for (routes.array.items) |entry| if (wire.eq(modeled.text(entry, "command").?, action)) {
        route = entry;
        break;
    };
    const spec = route orelse return error.UnsupportedOperation;
    if (r.operands.items.len == 0) return error.InvalidInput;
    var conn = try modeled.connection(a, ctx, r, config, r.operands.items[0]);
    const endpoint = r.values.get("--management-endpoint") orelse if (conn.management_endpoint.len > 0) conn.management_endpoint else return error.InvalidEndpoint;
    const uri = std.Uri.parse(endpoint) catch return error.InvalidEndpoint;
    if ((!wire.eq(uri.scheme, "http") and !wire.eq(uri.scheme, "https")) or uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null or (!uri.path.isEmpty() and !wire.eq(uri.path.percent_encoded, "/"))) return error.InvalidEndpoint;
    conn.endpoint = endpoint;
    var path = modeled.text(spec, "path").?;
    const method = modeled.text(spec, "method").?;
    const params = modeled.get(spec, "parameters").?.array.items;
    if (r.operands.items.len != params.len + 1) return error.InvalidInput;
    for (params, 0..) |name, i| {
        const encoded = try signing.encode(a, r.operands.items[i + 1], false);
        const placeholder = try std.fmt.allocPrint(a, "{{{s}}}", .{name.string});
        const at = std.mem.indexOf(u8, path, placeholder) orelse return error.InvalidInput;
        path = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ path[0..at], encoded, path[at + placeholder.len ..] });
    }
    if (r.values.contains("--file") and r.values.contains("--input-json")) return error.InvalidInput;
    var body: V = supplied orelse .null;
    if (r.values.get("--file") orelse r.values.get("--input-json")) |file| body = try wire.readInputJson(a, ctx.io, file);
    const op = modeled.get(spec, "operation").?;
    const model = (try std.json.parseFromSlice(V, a, @embedFile("models/management.json"), .{})).value;
    if (modeled.get(op, "requestBody")) |request_ref| {
        const request = try reference(model, request_ref);
        if (modeled.get(modeled.get(modeled.get(request, "content") orelse .null, "application/json") orelse .null, "schema")) |schema| {
            if (body == .null and (modeled.get(request, "required") orelse V{ .bool = false }).bool) return error.InvalidInput;
            if (body != .null) try validate(model, schema, body, 0, wire.eq(method, "PATCH"));
        }
    }
    if (!wire.eq(method, "GET") and !wire.eq(action, "admin auth login") and !r.flags.contains("--yes") and !r.flags.contains("--dry-run")) return error.ConfirmationRequired;
    var pairs: std.ArrayList(signing.Pair) = .empty;
    var options = r.values.iterator();
    while (options.next()) |entry| {
        const n = entry.key_ptr.*;
        if (wire.eq(n, "--endpoint") or wire.eq(n, "--region") or wire.eq(n, "--bucket-lookup") or wire.eq(n, "--file") or wire.eq(n, "--input-json") or wire.eq(n, "--management-endpoint") or wire.eq(n, "--token-file") or wire.eq(n, "--output") or wire.eq(n, "--ca-cert") or wire.eq(n, "--timeout") or wire.eq(n, "--connect-timeout")) continue;
        const list = modeled.get(op, "parameters") orelse V{ .array = std.array_list.Managed(V).init(a) };
        var found = false;
        for (list.array.items) |p_ref| {
            const p = try reference(model, p_ref);
            if (!wire.eq(modeled.text(p, "in") orelse "", "query")) continue;
            const name = modeled.text(p, "name").?;
            const flag = try std.fmt.allocPrint(a, "--{s}", .{name});
            if (wire.eq(n, flag)) {
                try wire.safe(entry.value_ptr.*);
                try pairs.append(a, .{ .name = name, .value = entry.value_ptr.* });
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidInput;
    }
    if (r.flags.contains("--dry-run")) return wire.output(a, json, quiet, "management-plan", .{ .method = method, .path = path, .query = pairs.items, .body_supplied = body != .null });
    const login = wire.eq(action, "admin auth login");
    const callback = wire.eq(action, "admin auth oidc callback");
    const public = login or callback or wire.eq(action, "admin auth oidc start") or wire.eq(action, "admin auth oidc providers") or wire.eq(action, "admin auth oidc web-identity");
    const session_path = try sessionPath(a, ctx, config, endpoint);
    var token: ?[]const u8 = null;
    if (!public) {
        const session = try privateJson(a, ctx, r.values.get("--token-file") orelse session_path);
        if (modeled.text(session, "endpoint")) |saved| if (!wire.eq(saved, endpoint)) return error.InvalidInput;
        token = modeled.text(session, "token") orelse return error.CredentialsRequired;
        if (modeled.get(session, "expires_at_unix_seconds")) |end| if (end == .integer and end.integer <= Io.Clock.real.now(ctx.io).toSeconds()) return error.CredentialsRequired;
    }
    const reply = try wire.send(a, ctx, .{ .connection = conn, .method = method, .path = path, .query = pairs.items, .headers = &.{.{ .name = "content-type", .value = "application/json" }}, .body = if (body == .null) "" else try std.json.Stringify.valueAlloc(a, body, .{}), .signed = false, .bearer = token, .output = r.values.get("--output"), .overwrite = r.flags.contains("--overwrite") });
    if (try wire.check(a, json, reply)) |err| return err;
    var data: V = if (reply.body.len > 0) (std.json.parseFromSlice(V, a, reply.body, .{}) catch return error.InvalidResponse).value else .null;
    if (login or callback or wire.eq(action, "admin auth oidc refresh")) {
        if (modeled.text(data, "token")) |session_token| {
            var session: V = .{ .object = .{} };
            try modeled.put(a, &session, "endpoint", endpoint);
            try modeled.put(a, &session, "token", session_token);
            if (modeled.get(data, "expires_at") orelse modeled.get(data, "expires_at_unix_seconds")) |expiry| try session.object.put(a, "expires_at_unix_seconds", expiry);
            try save(a, ctx, session_path, session);
        }
    }
    if (wire.eq(action, "admin auth logout") or wire.eq(action, "admin auth oidc logout")) {
        Io.Dir.cwd().deleteFile(ctx.io, session_path) catch |err| if (err != error.FileNotFound) return err;
    }
    // Explicit credential creation returns one-time credentials. Read/config output is redacted.
    const one_time = wire.eq(method, "POST") and (std.mem.indexOf(u8, path, "access-keys") != null or wire.eq(action, "admin role-session create") or wire.eq(action, "admin auth oidc web-identity"));
    if (!one_time) redact(&data);
    return wire.output(a, json, quiet, action, .{ .status_code = reply.status, .result = data, .bytes_written = reply.bytes });
}
pub fn describe(a: A, action: []const u8) ![]const u8 {
    const routes = (try std.json.parseFromSlice(V, a, @embedFile("models/management-routes.json"), .{})).value;
    for (routes.array.items) |entry| if (wire.eq(modeled.text(entry, "command").?, action)) {
        return std.fmt.allocPrint(a, "Endpoint: {s} {s}\nPath arguments (after ALIAS): {s}\nRequest contract: {s}\n", .{ modeled.text(entry, "method").?, modeled.text(entry, "path").?, try std.json.Stringify.valueAlloc(a, modeled.get(entry, "parameters").?, .{}), try std.json.Stringify.valueAlloc(a, modeled.get(entry, "operation").?, .{}) });
    };
    return "";
}
pub const help =
    \\Management commands: COMMAND ALIAS [PATH_ARGUMENTS] [--file REQUEST_JSON] [--yes]
    \\Requires alias management_endpoint or --management-endpoint URL, separate from S3.
    \\admin auth login ALIAS --file LOGIN_JSON stores an owner-only bearer session.
    \\admin auth session/logout use that session; --token-file accepts owner-only JSON.
    \\OIDC start/callback/refresh/logout expose explicit protocol steps, not a simulated login.
    \\JSON request bodies follow the repository OpenAPI; endpoint path arguments are positional.
    \\Query options use --exact_query_name VALUE. Writes require --yes; --dry-run previews.
    \\--output FILE streams downloads atomically. No automatic retries or redirects.
    \\Read/configuration secrets are redacted; explicit credential creation returns secrets once.
    \\Connected, pending verification. No local data directory access.
    \\
;
