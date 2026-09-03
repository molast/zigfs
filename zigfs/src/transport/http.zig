const std = @import("std");
const Application = @import("../application/mod.zig").Application;
const Config = @import("../config.zig").Config;
const management_session = @import("../auth/management_session.zig");
const request_id = @import("../common/request_id.zig");
const recovery = @import("../metadata/recovery.zig");
const s3 = @import("s3.zig");

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
    application: *Application,
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

const metrics_prefix =
    "# HELP zigfs_up Whether the ZigFS process is running.\n" ++
    "# TYPE zigfs_up gauge\n" ++
    "zigfs_up 1\n" ++
    "# HELP zigfs_ready Whether ZigFS storage initialization completed.\n" ++
    "# TYPE zigfs_ready gauge\n";

pub fn serve(
    io: std.Io,
    application: *Application,
) !void {
    const config = application.config;
    const api_address = try std.Io.net.IpAddress.parseLiteral(config.api_address);
    var api_listener = try api_address.listen(io, .{ .reuse_address = true });
    defer api_listener.deinit(io);

    var api_context: ListenerContext = .{
        .io = io,
        .kind = .api,
        .config = config,
        .application = application,
    };
    std.log.info("ZigFS API listening on http://{s}", .{config.api_address});

    if (!config.metrics_enabled) {
        std.log.info("Prometheus metrics listener disabled", .{});
        return serveLoop(&api_listener, &api_context);
    }

    const metrics_address = try std.Io.net.IpAddress.parseLiteral(config.metrics_address);
    var metrics_listener = try metrics_address.listen(io, .{ .reuse_address = true });
    defer metrics_listener.deinit(io);

    var metrics_context: ListenerContext = .{
        .io = io,
        .kind = .metrics,
        .config = config,
        .application = application,
    };
    var listeners: std.Io.Group = .init;
    defer listeners.cancel(io);

    std.log.info("Prometheus metrics listening on http://{s}{s}", .{ config.metrics_address, metrics_path });
    listeners.async(io, serveLoopBackground, .{ &metrics_listener, &metrics_context });
    return serveLoop(&api_listener, &api_context);
}

fn serveLoopBackground(listener: *std.Io.net.Server, context: *ListenerContext) void {
    serveLoop(listener, context) catch |err| {
        if (err == error.Canceled) return;
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
        if (!request.head.keep_alive) return;
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
        .ready => serveReadiness(request, context.application.recoveryState().*, current_request_id),
        .metrics => serveMetrics(request, context.application.recoveryState().*, current_request_id),
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
        .s3 => s3.serveRequest(request, context.application, current_request_id),
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

fn serveReadiness(
    request: *std.http.Server.Request,
    state: recovery.State,
    current_request_id: []const u8,
) !std.http.Status {
    var body_buffer: [256]u8 = undefined;
    const body = if (state.isReady())
        "{\"status\":\"ready\"}\n"
    else
        try std.fmt.bufPrint(
            &body_buffer,
            "{{\"status\":\"not_ready\",\"recovery\":\"{s}\",\"reason\":\"{s}\"}}\n",
            .{ @tagName(state.status), @tagName(state.failure) },
        );
    return respondReadOnlyStatus(
        request,
        body,
        readinessHttpStatus(state),
        "application/json; charset=utf-8",
        current_request_id,
    );
}

fn serveMetrics(
    request: *std.http.Server.Request,
    state: recovery.State,
    current_request_id: []const u8,
) !std.http.Status {
    var body_buffer: [512]u8 = undefined;
    const body = try metricsBody(state, &body_buffer);
    return respondReadOnly(
        request,
        body,
        "text/plain; version=0.0.4; charset=utf-8",
        current_request_id,
    );
}

fn readinessHttpStatus(state: recovery.State) std.http.Status {
    return if (state.isReady()) .ok else .service_unavailable;
}

fn metricsBody(state: recovery.State, buffer: *[512]u8) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        metrics_prefix ++ "zigfs_ready {d}\n",
        .{@intFromBool(state.isReady())},
    );
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
    return respondReadOnlyStatus(
        request,
        body,
        .ok,
        content_type,
        current_request_id,
    );
}

fn respondReadOnlyStatus(
    request: *std.http.Server.Request,
    body: []const u8,
    status: std.http.Status,
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

    return respond(request, body, status, content_type, current_request_id, null);
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

test "readiness status and metric reflect recovery state" {
    const ready: recovery.State = .{ .status = .ready };
    try std.testing.expectEqual(std.http.Status.ok, readinessHttpStatus(ready));
    var buffer: [512]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, try metricsBody(ready, &buffer), "zigfs_ready 1\n"));

    const required: recovery.State = .{
        .status = .recovery_required,
        .failure = .corrupt_record,
    };
    try std.testing.expectEqual(
        std.http.Status.service_unavailable,
        readinessHttpStatus(required),
    );
    try std.testing.expect(std.mem.endsWith(
        u8,
        try metricsBody(required, &buffer),
        "zigfs_ready 0\n",
    ));
}

const TestHttpResponse = struct {
    bytes: []u8,
    status: std.http.Status,
    body: []const u8,
    header_bytes: []const u8,

    fn deinit(self: TestHttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }

    fn header(self: TestHttpResponse, name: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, self.header_bytes, "\r\n");
        _ = lines.next();
        while (lines.next()) |line| {
            const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(line[0..separator], name)) continue;
            return std.mem.trim(u8, line[separator + 1 ..], " \t");
        }
        return null;
    }
};

const TestSignedRequest = struct {
    method: std.http.Method,
    target: []const u8,
    access_key: []const u8,
    secret_key: []const u8,
    body: []const u8 = "",
    extra_headers: []const std.http.Header = &.{},
    payload_hash_override: ?[]const u8 = null,
    timestamp: ?i64 = null,
    corrupt_signature: bool = false,
};

fn sendTestSignedRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    address: std.Io.net.IpAddress,
    options: TestSignedRequest,
) !TestHttpResponse {
    const host = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{address.getPort()});
    defer allocator.free(host);
    var date_buffer: [16]u8 = undefined;
    const timestamp = options.timestamp orelse std.Io.Clock.real.now(io).toSeconds();
    const amz_date = try @import("../common/time.zig").formatAmzDate(timestamp, &date_buffer);
    var payload_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(options.body, &payload_digest, .{});
    const computed_payload_hash = std.fmt.bytesToHex(payload_digest, .lower);
    const payload_hash = options.payload_hash_override orelse &computed_payload_hash;
    const query_start = std.mem.indexOfScalar(u8, options.target, '?') orelse options.target.len;
    const canonical_uri = options.target[0..query_start];
    const canonical_query = if (query_start < options.target.len)
        options.target[query_start + 1 ..]
    else
        "";
    const signed_headers = "host;x-amz-content-sha256;x-amz-date";
    const canonical = try std.fmt.allocPrint(
        allocator,
        "{s}\n{s}\n{s}\nhost:{s}\nx-amz-content-sha256:{s}\nx-amz-date:{s}\n\n{s}\n{s}",
        .{
            @tagName(options.method),
            canonical_uri,
            canonical_query,
            host,
            payload_hash,
            amz_date,
            signed_headers,
            payload_hash,
        },
    );
    defer allocator.free(canonical);
    var canonical_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical, &canonical_digest, .{});
    const canonical_hash = std.fmt.bytesToHex(canonical_digest, .lower);
    const scope_date = amz_date[0..8];
    const scope = try std.fmt.allocPrint(
        allocator,
        "{s}/us-east-1/s3/aws4_request",
        .{scope_date},
    );
    defer allocator.free(scope);
    const string_to_sign = try std.fmt.allocPrint(
        allocator,
        "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}",
        .{ amz_date, scope, &canonical_hash },
    );
    defer allocator.free(string_to_sign);

    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    const prefixed_secret = try std.fmt.allocPrint(allocator, "AWS4{s}", .{options.secret_key});
    defer {
        std.crypto.secureZero(u8, prefixed_secret);
        allocator.free(prefixed_secret);
    }
    var date_key: [32]u8 = undefined;
    var region_key: [32]u8 = undefined;
    var service_key: [32]u8 = undefined;
    var signing_key: [32]u8 = undefined;
    defer {
        std.crypto.secureZero(u8, &date_key);
        std.crypto.secureZero(u8, &region_key);
        std.crypto.secureZero(u8, &service_key);
        std.crypto.secureZero(u8, &signing_key);
    }
    HmacSha256.create(&date_key, scope_date, prefixed_secret);
    HmacSha256.create(&region_key, "us-east-1", &date_key);
    HmacSha256.create(&service_key, "s3", &region_key);
    HmacSha256.create(&signing_key, "aws4_request", &service_key);
    var signature: [32]u8 = undefined;
    HmacSha256.create(&signature, string_to_sign, &signing_key);
    var signature_hex = std.fmt.bytesToHex(signature, .lower);
    if (options.corrupt_signature) {
        signature_hex[0] = if (signature_hex[0] == '0') '1' else '0';
    }
    const authorization = try std.fmt.allocPrint(
        allocator,
        "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}",
        .{ options.access_key, scope, signed_headers, &signature_hex },
    );
    defer allocator.free(authorization);

    var request_bytes: std.Io.Writer.Allocating = .init(allocator);
    defer request_bytes.deinit();
    const writer = &request_bytes.writer;
    try writer.print(
        "{s} {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n" ++
            "X-Amz-Date: {s}\r\nX-Amz-Content-Sha256: {s}\r\nAuthorization: {s}\r\n" ++
            "Content-Length: {d}\r\n",
        .{
            @tagName(options.method),
            options.target,
            host,
            amz_date,
            payload_hash,
            authorization,
            options.body.len,
        },
    );
    for (options.extra_headers) |header| {
        try writer.print("{s}: {s}\r\n", .{ header.name, header.value });
    }
    try writer.writeAll("\r\n");
    try writer.writeAll(options.body);
    return sendTestRawRequest(allocator, io, address, request_bytes.written());
}

fn sendTestUnsignedRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    address: std.Io.net.IpAddress,
    method: std.http.Method,
    target: []const u8,
) !TestHttpResponse {
    const request_bytes = try std.fmt.allocPrint(
        allocator,
        "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n",
        .{ @tagName(method), target, address.getPort() },
    );
    defer allocator.free(request_bytes);
    return sendTestRawRequest(allocator, io, address, request_bytes);
}

fn sendTestRawRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    address: std.Io.net.IpAddress,
    request_bytes: []const u8,
) !TestHttpResponse {
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var receive_buffer: [16 * 1024]u8 = undefined;
    var send_buffer: [16 * 1024]u8 = undefined;
    var stream_reader = stream.reader(io, &receive_buffer);
    var stream_writer = stream.writer(io, &send_buffer);
    try stream_writer.interface.writeAll(request_bytes);
    try stream_writer.interface.flush();
    const bytes = try stream_reader.interface.allocRemaining(allocator, .limited(2 * 1024 * 1024));
    errdefer allocator.free(bytes);
    const head_end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return error.InvalidHttpResponse;
    const first_line_end = std.mem.indexOf(u8, bytes[0..head_end], "\r\n") orelse {
        return error.InvalidHttpResponse;
    };
    const first_line = bytes[0..first_line_end];
    if (first_line.len < 12 or !std.mem.startsWith(u8, first_line, "HTTP/1.1 ")) {
        return error.InvalidHttpResponse;
    }
    const status_code = std.fmt.parseInt(u10, first_line[9..12], 10) catch {
        return error.InvalidHttpResponse;
    };
    return .{
        .bytes = bytes,
        .status = @enumFromInt(status_code),
        .header_bytes = bytes[0..head_end],
        .body = bytes[head_end + 4 ..],
    };
}

test "S3 HTTP authenticates and serves Bucket Object and List V2 operations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/data",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(data_root);
    const config: Config = .{ .data_root = data_root, .metrics_enabled = false };
    var application = Application.init(config);
    defer application.deinit(std.testing.io);
    try application.initialize(std.testing.io);
    var credential = try application.credentialService().?.create("tenant-a", .all);
    defer credential.deinit(application.allocator);
    var read_only = try application.credentialService().?.create("tenant-read", .read_only);
    defer read_only.deinit(application.allocator);

    const loopback: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try loopback.listen(std.testing.io, .{ .reuse_address = true });
    defer listener.deinit(std.testing.io);
    var context: ListenerContext = .{
        .io = std.testing.io,
        .kind = .api,
        .config = config,
        .application = &application,
    };
    var server_tasks: std.Io.Group = .init;
    defer server_tasks.cancel(std.testing.io);
    server_tasks.async(std.testing.io, serveLoopBackground, .{ &listener, &context });
    const address = listener.socket.address;

    const unsigned = try sendTestUnsignedRequest(
        std.testing.allocator,
        std.testing.io,
        address,
        .GET,
        "/",
    );
    defer unsigned.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.forbidden, unsigned.status);
    try std.testing.expect(std.mem.indexOf(u8, unsigned.body, "<Code>AccessDenied</Code>") != null);
    try std.testing.expect(std.mem.indexOf(u8, unsigned.body, "<Resource>/</Resource>") != null);

    const invalid = try sendTestSignedRequest(
        std.testing.allocator,
        std.testing.io,
        address,
        .{
            .method = .GET,
            .target = "/",
            .access_key = credential.credential.access_key,
            .secret_key = &credential.secret_key,
            .corrupt_signature = true,
        },
    );
    defer invalid.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.forbidden, invalid.status);
    try std.testing.expect(std.mem.indexOf(u8, invalid.body, "<Code>SignatureDoesNotMatch</Code>") != null);

    const unknown = try sendTestSignedRequest(
        std.testing.allocator,
        std.testing.io,
        address,
        .{
            .method = .GET,
            .target = "/",
            .access_key = "ZF000000000000000000",
            .secret_key = "0000000000000000000000000000000000000000",
        },
    );
    defer unknown.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.forbidden, unknown.status);
    try std.testing.expect(std.mem.indexOf(u8, unknown.body, "<Code>InvalidAccessKeyId</Code>") != null);

    const expired = try sendTestSignedRequest(
        std.testing.allocator,
        std.testing.io,
        address,
        .{
            .method = .GET,
            .target = "/",
            .access_key = credential.credential.access_key,
            .secret_key = &credential.secret_key,
            .timestamp = 1_369_353_600,
        },
    );
    defer expired.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.forbidden, expired.status);
    try std.testing.expect(std.mem.indexOf(u8, expired.body, "<Code>RequestTimeTooSkewed</Code>") != null);

    const denied = try sendTestSignedRequest(
        std.testing.allocator,
        std.testing.io,
        address,
        .{
            .method = .PUT,
            .target = "/project-assets",
            .access_key = read_only.credential.access_key,
            .secret_key = &read_only.secret_key,
        },
    );
    defer denied.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.forbidden, denied.status);
    try std.testing.expect(std.mem.indexOf(u8, denied.body, "<Code>AccessDenied</Code>") != null);

    const create_bucket = try sendTestSignedRequest(
        std.testing.allocator,
        std.testing.io,
        address,
        .{
            .method = .PUT,
            .target = "/project-assets",
            .access_key = credential.credential.access_key,
            .secret_key = &credential.secret_key,
        },
    );
    defer create_bucket.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, create_bucket.status);
    try std.testing.expectEqualStrings("/project-assets", create_bucket.header("location").?);

    const list_buckets = try sendTestSignedRequest(
        std.testing.allocator,
        std.testing.io,
        address,
        .{
            .method = .GET,
            .target = "/",
            .access_key = credential.credential.access_key,
            .secret_key = &credential.secret_key,
        },
    );
    defer list_buckets.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, list_buckets.status);
    try std.testing.expect(std.mem.indexOf(u8, list_buckets.body, "<Name>project-assets</Name>") != null);

    const head_bucket = try sendTestSignedRequest(
        std.testing.allocator,
        std.testing.io,
        address,
        .{
            .method = .HEAD,
            .target = "/project-assets",
            .access_key = credential.credential.access_key,
            .secret_key = &credential.secret_key,
        },
    );
    defer head_bucket.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, head_bucket.status);
    try std.testing.expectEqual(@as(usize, 0), head_bucket.body.len);

    const object_body = "hello from ZigFS";
    var object_md5: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(object_body, &object_md5, .{});
    var object_md5_base64_buffer: [24]u8 = undefined;
    const object_md5_base64 = std.base64.standard.Encoder.encode(
        &object_md5_base64_buffer,
        &object_md5,
    );
    const put_headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "text/plain" },
        .{ .name = "Content-MD5", .value = object_md5_base64 },
    };
    const put_object = try sendTestSignedRequest(
        std.testing.allocator,
        std.testing.io,
        address,
        .{
            .method = .PUT,
            .target = "/project-assets/folder/hello.txt",
            .access_key = credential.credential.access_key,
            .secret_key = &credential.secret_key,
            .body = object_body,
            .extra_headers = &put_headers,
        },
    );
    defer put_object.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, put_object.status);
    try std.testing.expect(put_object.header("etag") != null);

    const bad_digest_headers = [_]std.http.Header{.{
        .name = "Content-MD5",
        .value = "AAAAAAAAAAAAAAAAAAAAAA==",
    }};
    const bad_digest = try sendTestSignedRequest(
        std.testing.allocator,
        std.testing.io,
        address,
        .{
            .method = .PUT,
            .target = "/project-assets/bad.txt",
            .access_key = credential.credential.access_key,
            .secret_key = &credential.secret_key,
            .body = object_body,
            .extra_headers = &bad_digest_headers,
        },
    );
    defer bad_digest.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.bad_request, bad_digest.status);
    try std.testing.expect(std.mem.indexOf(u8, bad_digest.body, "<Code>BadDigest</Code>") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        bad_digest.body,
        "<Resource>/project-assets/bad.txt</Resource>",
    ) != null);

    const sha_mismatch = try sendTestSignedRequest(
        std.testing.allocator,
        std.testing.io,
        address,
        .{
            .method = .PUT,
            .target = "/project-assets/sha-mismatch.txt",
            .access_key = credential.credential.access_key,
            .secret_key = &credential.secret_key,
            .body = object_body,
            .payload_hash_override = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        },
    );
    defer sha_mismatch.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.bad_request, sha_mismatch.status);
    try std.testing.expect(std.mem.indexOf(
        u8,
        sha_mismatch.body,
        "<Code>XAmzContentSHA256Mismatch</Code>",
    ) != null);

    const duplicate_digest_headers = [_]std.http.Header{
        .{ .name = "Content-MD5", .value = object_md5_base64 },
        .{ .name = "Content-MD5", .value = object_md5_base64 },
    };
    const duplicate_digest = try sendTestSignedRequest(
        std.testing.allocator,
        std.testing.io,
        address,
        .{
            .method = .PUT,
            .target = "/project-assets/duplicate.txt",
            .access_key = credential.credential.access_key,
            .secret_key = &credential.secret_key,
            .body = object_body,
            .extra_headers = &duplicate_digest_headers,
        },
    );
    defer duplicate_digest.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.bad_request, duplicate_digest.status);
    try std.testing.expect(std.mem.indexOf(u8, duplicate_digest.body, "<Code>InvalidDigest</Code>") != null);

    const get_object = try sendTestSignedRequest(
        std.testing.allocator,
        std.testing.io,
        address,
        .{
            .method = .GET,
            .target = "/project-assets/folder/hello.txt",
            .access_key = credential.credential.access_key,
            .secret_key = &credential.secret_key,
        },
    );
    defer get_object.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, get_object.status);
    try std.testing.expectEqualStrings(object_body, get_object.body);
    try std.testing.expectEqualStrings("text/plain", get_object.header("content-type").?);
    try std.testing.expectEqual(
        @as(u64, object_body.len),
        try std.fmt.parseInt(u64, get_object.header("content-length").?, 10),
    );

    const head_object = try sendTestSignedRequest(
        std.testing.allocator,
        std.testing.io,
        address,
        .{
            .method = .HEAD,
            .target = "/project-assets/folder/hello.txt",
            .access_key = credential.credential.access_key,
            .secret_key = &credential.secret_key,
        },
    );
    defer head_object.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, head_object.status);
    try std.testing.expectEqual(@as(usize, 0), head_object.body.len);
    try std.testing.expectEqual(
        @as(u64, object_body.len),
        try std.fmt.parseInt(u64, head_object.header("content-length").?, 10),
    );

    const range_headers = [_]std.http.Header{.{ .name = "Range", .value = "bytes=0-3" }};
    const range = try sendTestSignedRequest(
        std.testing.allocator,
        std.testing.io,
        address,
        .{
            .method = .GET,
            .target = "/project-assets/folder/hello.txt",
            .access_key = credential.credential.access_key,
            .secret_key = &credential.secret_key,
            .extra_headers = &range_headers,
        },
    );
    defer range.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.not_implemented, range.status);
    try std.testing.expect(std.mem.indexOf(u8, range.body, "<Code>NotImplemented</Code>") != null);

    const second_put = try sendTestSignedRequest(
        std.testing.allocator,
        std.testing.io,
        address,
        .{
            .method = .PUT,
            .target = "/project-assets/folder/a%26%3C.txt",
            .access_key = credential.credential.access_key,
            .secret_key = &credential.secret_key,
            .body = "special",
        },
    );
    defer second_put.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, second_put.status);

    const first_page = try sendTestSignedRequest(
        std.testing.allocator,
        std.testing.io,
        address,
        .{
            .method = .GET,
            .target = "/project-assets?list-type=2&max-keys=1",
            .access_key = credential.credential.access_key,
            .secret_key = &credential.secret_key,
        },
    );
    defer first_page.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, first_page.status);
    try std.testing.expect(std.mem.indexOf(u8, first_page.body, "<IsTruncated>true</IsTruncated>") != null);
    const token_start_tag = "<NextContinuationToken>";
    const token_end_tag = "</NextContinuationToken>";
    const token_start = (std.mem.indexOf(u8, first_page.body, token_start_tag) orelse {
        return error.MissingContinuationToken;
    }) + token_start_tag.len;
    const token_end_relative = std.mem.indexOf(u8, first_page.body[token_start..], token_end_tag) orelse {
        return error.MissingContinuationToken;
    };
    const continuation_token = first_page.body[token_start .. token_start + token_end_relative];
    const second_page_target = try std.fmt.allocPrint(
        std.testing.allocator,
        "/project-assets?continuation-token={s}&list-type=2&max-keys=1",
        .{continuation_token},
    );
    defer std.testing.allocator.free(second_page_target);
    const second_page = try sendTestSignedRequest(
        std.testing.allocator,
        std.testing.io,
        address,
        .{
            .method = .GET,
            .target = second_page_target,
            .access_key = credential.credential.access_key,
            .secret_key = &credential.secret_key,
        },
    );
    defer second_page.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, second_page.status);
    try std.testing.expect(std.mem.indexOf(u8, second_page.body, "<IsTruncated>false</IsTruncated>") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_page.body, "<Key>folder/hello.txt</Key>") != null);

    const list_objects = try sendTestSignedRequest(
        std.testing.allocator,
        std.testing.io,
        address,
        .{
            .method = .GET,
            .target = "/project-assets?encoding-type=url&list-type=2",
            .access_key = credential.credential.access_key,
            .secret_key = &credential.secret_key,
        },
    );
    defer list_objects.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, list_objects.status);
    try std.testing.expect(std.mem.indexOf(u8, list_objects.body, "<Key>folder/a%26%3C.txt</Key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_objects.body, "<Key>folder/hello.txt</Key>") != null);

    const bucket_not_empty = try sendTestSignedRequest(
        std.testing.allocator,
        std.testing.io,
        address,
        .{
            .method = .DELETE,
            .target = "/project-assets",
            .access_key = credential.credential.access_key,
            .secret_key = &credential.secret_key,
        },
    );
    defer bucket_not_empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.conflict, bucket_not_empty.status);
    try std.testing.expect(std.mem.indexOf(u8, bucket_not_empty.body, "<Code>BucketNotEmpty</Code>") != null);

    const object_targets = [_][]const u8{
        "/project-assets/folder/hello.txt",
        "/project-assets/folder/a%26%3C.txt",
    };
    for (object_targets) |target| {
        const deleted = try sendTestSignedRequest(
            std.testing.allocator,
            std.testing.io,
            address,
            .{
                .method = .DELETE,
                .target = target,
                .access_key = credential.credential.access_key,
                .secret_key = &credential.secret_key,
            },
        );
        defer deleted.deinit(std.testing.allocator);
        try std.testing.expectEqual(std.http.Status.no_content, deleted.status);
    }

    const missing = try sendTestSignedRequest(
        std.testing.allocator,
        std.testing.io,
        address,
        .{
            .method = .HEAD,
            .target = "/project-assets/folder/hello.txt",
            .access_key = credential.credential.access_key,
            .secret_key = &credential.secret_key,
        },
    );
    defer missing.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.not_found, missing.status);
    try std.testing.expectEqual(@as(usize, 0), missing.body.len);

    const delete_bucket = try sendTestSignedRequest(
        std.testing.allocator,
        std.testing.io,
        address,
        .{
            .method = .DELETE,
            .target = "/project-assets",
            .access_key = credential.credential.access_key,
            .secret_key = &credential.secret_key,
        },
    );
    defer delete_bucket.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.no_content, delete_bucket.status);

    const disabled = try application.credentialService().?.update(
        credential.credential.access_key,
        .{ .enabled = false },
    );
    disabled.deinit(application.allocator);
    const disabled_request = try sendTestSignedRequest(
        std.testing.allocator,
        std.testing.io,
        address,
        .{
            .method = .GET,
            .target = "/",
            .access_key = credential.credential.access_key,
            .secret_key = &credential.secret_key,
        },
    );
    defer disabled_request.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.forbidden, disabled_request.status);
    try std.testing.expect(std.mem.indexOf(u8, disabled_request.body, "<Code>AccessDenied</Code>") != null);
}
