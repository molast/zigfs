const std = @import("std");
const Config = @import("../config.zig").Config;
const management_session = @import("../auth/management_session.zig");
const request_id = @import("../common/request_id.zig");

pub const health_live_path = "/health/live";
pub const health_ready_path = "/health/ready";
pub const metrics_path = "/metrics";

const ListenerKind = enum {
    api,
    metrics,
};

const ListenerContext = struct {
    io: std.Io,
    kind: ListenerKind,
    config: Config,
};

const Route = enum {
    live,
    ready,
    management_login,
    management_session,
    management,
    s3,
    metrics,
    not_found,
};

const metrics_body =
    "# HELP zigfs_up Whether the ZigFS process is running.\n" ++
    "# TYPE zigfs_up gauge\n" ++
    "zigfs_up 1\n" ++
    "# HELP zigfs_ready Whether ZigFS storage initialization completed.\n" ++
    "# TYPE zigfs_ready gauge\n" ++
    "zigfs_ready 1\n";

pub fn serve(io: std.Io, config: Config) !void {
    const api_address = try std.Io.net.IpAddress.parseLiteral(config.api_address);
    var api_listener = try api_address.listen(io, .{ .reuse_address = true });
    defer api_listener.deinit(io);

    var api_context: ListenerContext = .{ .io = io, .kind = .api, .config = config };
    std.log.info("ZigFS API listening on http://{s}", .{config.api_address});

    if (!config.metrics_enabled) {
        std.log.info("Prometheus metrics listener disabled", .{});
        return serveLoop(&api_listener, &api_context);
    }

    const metrics_address = try std.Io.net.IpAddress.parseLiteral(config.metrics_address);
    var metrics_listener = try metrics_address.listen(io, .{ .reuse_address = true });
    defer metrics_listener.deinit(io);

    var metrics_context: ListenerContext = .{ .io = io, .kind = .metrics, .config = config };
    var listeners: std.Io.Group = .init;
    defer listeners.cancel(io);

    std.log.info("Prometheus metrics listening on http://{s}{s}", .{ config.metrics_address, metrics_path });
    listeners.async(io, serveLoopBackground, .{ &metrics_listener, &metrics_context });
    return serveLoop(&api_listener, &api_context);
}

fn serveLoopBackground(listener: *std.Io.net.Server, context: *ListenerContext) void {
    serveLoop(listener, context) catch |err| {
        std.log.err("{t} listener stopped: {t}", .{ context.kind, err });
    };
}

fn serveLoop(listener: *std.Io.net.Server, context: *ListenerContext) !void {
    var connections: std.Io.Group = .init;
    defer connections.cancel(context.io);

    while (true) {
        const stream = try listener.accept(context.io);
        connections.async(context.io, serveConnection, .{ context, stream });
    }
}

fn serveConnection(context: *ListenerContext, stream: std.Io.net.Stream) void {
    const io = context.io;
    defer stream.close(io);

    var receive_buffer: [16 * 1024]u8 = undefined;
    var send_buffer: [16 * 1024]u8 = undefined;
    var connection_reader = stream.reader(io, &receive_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var server = std.http.Server.init(&connection_reader.interface, &connection_writer.interface);

    while (server.reader.state == .ready) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => {
                std.log.warn("closing invalid HTTP connection: {t}", .{err});
                return;
            },
        };

        const started: std.Io.Clock.Timestamp = .now(io, .awake);
        const path = requestPath(request.head.target);
        var request_id_buffer: [request_id.max_length]u8 = undefined;
        const current_request_id = resolveRequestId(&request, io, &request_id_buffer) catch |err| {
            std.log.warn("failed to create request ID for {s}: {t}", .{ path, err });
            return;
        };

        const status = serveRequest(&request, context, current_request_id) catch |err| {
            const duration_ms = started.untilNow(io).raw.toMilliseconds();
            std.log.warn(
                "http request failed method={s} path={s} request_id={s} duration_ms={d} error={t}",
                .{ @tagName(request.head.method), path, current_request_id, duration_ms, err },
            );
            return;
        };

        const duration_ms = started.untilNow(io).raw.toMilliseconds();
        std.log.info(
            "http request method={s} path={s} status={d} request_id={s} duration_ms={d}",
            .{ @tagName(request.head.method), path, @intFromEnum(status), current_request_id, duration_ms },
        );
    }
}

fn serveRequest(
    request: *std.http.Server.Request,
    context: *const ListenerContext,
    current_request_id: []const u8,
) !std.http.Status {
    const path = requestPath(request.head.target);
    const route = classifyRoute(context.kind, path);

    return switch (route) {
        .live => respondReadOnly(
            request,
            "{\"status\":\"ok\"}\n",
            "application/json; charset=utf-8",
            current_request_id,
        ),
        .ready => respondReadOnly(
            request,
            "{\"status\":\"ready\"}\n",
            "application/json; charset=utf-8",
            current_request_id,
        ),
        .metrics => respondReadOnly(
            request,
            metrics_body,
            "text/plain; version=0.0.4; charset=utf-8",
            current_request_id,
        ),
        .management_login => serveManagementLogin(request, context, current_request_id),
        .management_session => serveManagementSession(request, context, current_request_id),
        .management => if (managementTokenExpiration(request, context)) |_|
            respond(
                request,
                "{\"code\":\"NotImplemented\",\"message\":\"management API is not implemented yet\"}\n",
                .not_implemented,
                "application/json; charset=utf-8",
                current_request_id,
                null,
            )
        else
            respondUnauthorized(request, current_request_id),
        .s3 => respond(
            request,
            "S3 API is not implemented yet\n",
            .not_implemented,
            "text/plain; charset=utf-8",
            current_request_id,
            null,
        ),
        .not_found => respond(
            request,
            "not found\n",
            .not_found,
            "text/plain; charset=utf-8",
            current_request_id,
            null,
        ),
    };
}

fn serveManagementLogin(
    request: *std.http.Server.Request,
    context: *const ListenerContext,
    current_request_id: []const u8,
) !std.http.Status {
    if (request.head.method != .POST) {
        return respond(
            request,
            "method not allowed\n",
            .method_not_allowed,
            "text/plain; charset=utf-8",
            current_request_id,
            "POST",
        );
    }

    var read_buffer: [4096]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&read_buffer);
    const body = body_reader.allocRemaining(std.heap.smp_allocator, .limited(4096)) catch |err| switch (err) {
        error.StreamTooLong => return respond(
            request,
            "{\"code\":\"PayloadTooLarge\",\"message\":\"login request is too large\"}\n",
            .payload_too_large,
            "application/json; charset=utf-8",
            current_request_id,
            null,
        ),
        else => return err,
    };
    defer std.heap.smp_allocator.free(body);

    const LoginRequest = struct {
        username: []const u8,
        password: []const u8,
    };
    const parsed = std.json.parseFromSlice(LoginRequest, std.heap.smp_allocator, body, .{}) catch {
        return respond(
            request,
            "{\"code\":\"InvalidRequest\",\"message\":\"valid username and password are required\"}\n",
            .bad_request,
            "application/json; charset=utf-8",
            current_request_id,
            null,
        );
    };
    defer parsed.deinit();

    const config = context.config;
    if (!management_session.authenticate(
        config.admin_username,
        config.admin_password,
        parsed.value.username,
        parsed.value.password,
    )) {
        return respondUnauthorized(request, current_request_id);
    }

    const now = std.Io.Clock.real.now(context.io).toSeconds();
    const issued = try management_session.issue(
        context.io,
        config.admin_session_secret,
        config.admin_session_ttl_seconds,
        now,
    );
    var response_buffer: [512]u8 = undefined;
    const response_body = try std.fmt.bufPrint(
        &response_buffer,
        "{{\"token\":\"{s}\",\"token_type\":\"Bearer\",\"username\":\"{s}\",\"expires_at\":{d}}}\n",
        .{ issued.value(), config.admin_username, issued.expires_at_unix_seconds },
    );
    return respond(
        request,
        response_body,
        .ok,
        "application/json; charset=utf-8",
        current_request_id,
        null,
    );
}

fn serveManagementSession(
    request: *std.http.Server.Request,
    context: *const ListenerContext,
    current_request_id: []const u8,
) !std.http.Status {
    if (request.head.method != .GET) {
        return respond(
            request,
            "method not allowed\n",
            .method_not_allowed,
            "text/plain; charset=utf-8",
            current_request_id,
            "GET",
        );
    }
    const expires_at = managementTokenExpiration(request, context) orelse {
        return respondUnauthorized(request, current_request_id);
    };

    var response_buffer: [256]u8 = undefined;
    const response_body = try std.fmt.bufPrint(
        &response_buffer,
        "{{\"authenticated\":true,\"username\":\"{s}\",\"expires_at\":{d}}}\n",
        .{ context.config.admin_username, expires_at },
    );
    return respond(
        request,
        response_body,
        .ok,
        "application/json; charset=utf-8",
        current_request_id,
        null,
    );
}

fn managementTokenExpiration(
    request: *const std.http.Server.Request,
    context: *const ListenerContext,
) ?i64 {
    const prefix = "Bearer ";
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "authorization")) continue;
        if (!std.mem.startsWith(u8, header.value, prefix)) return null;
        return management_session.validate(
            context.config.admin_session_secret,
            header.value[prefix.len..],
            std.Io.Clock.real.now(context.io).toSeconds(),
        );
    }
    return null;
}

fn respondUnauthorized(
    request: *std.http.Server.Request,
    current_request_id: []const u8,
) !std.http.Status {
    return respond(
        request,
        "{\"code\":\"Unauthorized\",\"message\":\"valid ZigFS administrator credentials are required\"}\n",
        .unauthorized,
        "application/json; charset=utf-8",
        current_request_id,
        null,
    );
}

fn respondReadOnly(
    request: *std.http.Server.Request,
    body: []const u8,
    content_type: []const u8,
    current_request_id: []const u8,
) !std.http.Status {
    if (request.head.method != .GET and request.head.method != .HEAD) {
        return respond(
            request,
            "method not allowed\n",
            .method_not_allowed,
            "text/plain; charset=utf-8",
            current_request_id,
            "GET, HEAD",
        );
    }

    return respond(request, body, .ok, content_type, current_request_id, null);
}

fn respond(
    request: *std.http.Server.Request,
    body: []const u8,
    status: std.http.Status,
    content_type: []const u8,
    current_request_id: []const u8,
    allow: ?[]const u8,
) !std.http.Status {
    if (allow) |allow_value| {
        const headers = [_]std.http.Header{
            .{ .name = "content-type", .value = content_type },
            .{ .name = "cache-control", .value = "no-store" },
            .{ .name = "x-request-id", .value = current_request_id },
            .{ .name = "allow", .value = allow_value },
        };
        try request.respond(body, .{ .status = status, .extra_headers = &headers });
        return status;
    }

    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "x-request-id", .value = current_request_id },
    };
    try request.respond(body, .{ .status = status, .extra_headers = &headers });
    return status;
}

fn resolveRequestId(
    request: *const std.http.Server.Request,
    io: std.Io,
    buffer: *[request_id.max_length]u8,
) std.Io.RandomSecureError![]const u8 {
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-request-id") and request_id.isValid(header.value)) {
            @memcpy(buffer[0..header.value.len], header.value);
            return buffer[0..header.value.len];
        }
    }

    const generated = try request_id.generate(io);
    @memcpy(buffer[0..generated.len], &generated);
    return buffer[0..generated.len];
}

fn requestPath(target: []const u8) []const u8 {
    const query_start = std.mem.findScalar(u8, target, '?') orelse target.len;
    return target[0..query_start];
}

fn classifyRoute(kind: ListenerKind, path: []const u8) Route {
    return switch (kind) {
        .api => if (std.mem.eql(u8, path, health_live_path))
            .live
        else if (std.mem.eql(u8, path, health_ready_path))
            .ready
        else if (std.mem.eql(u8, path, "/_admin/v1/auth/login"))
            .management_login
        else if (std.mem.eql(u8, path, "/_admin/v1/auth/session"))
            .management_session
        else if (std.mem.eql(u8, path, "/_admin/v1") or
            std.mem.startsWith(u8, path, "/_admin/v1/"))
            .management
        else
            .s3,
        .metrics => if (std.mem.eql(u8, path, metrics_path)) .metrics else .not_found,
    };
}

test "route classification isolates API and metrics listeners" {
    try std.testing.expectEqual(.live, classifyRoute(.api, "/health/live"));
    try std.testing.expectEqual(.ready, classifyRoute(.api, "/health/ready"));
    try std.testing.expectEqual(.management_login, classifyRoute(.api, "/_admin/v1/auth/login"));
    try std.testing.expectEqual(.management_session, classifyRoute(.api, "/_admin/v1/auth/session"));
    try std.testing.expectEqual(.management, classifyRoute(.api, "/_admin/v1/system"));
    try std.testing.expectEqual(.s3, classifyRoute(.api, "/bucket/object"));
    try std.testing.expectEqual(.metrics, classifyRoute(.metrics, "/metrics"));
    try std.testing.expectEqual(.not_found, classifyRoute(.metrics, "/health/ready"));
}

test "request path excludes query parameters" {
    try std.testing.expectEqualStrings("/health/ready", requestPath("/health/ready?probe=1"));
}
