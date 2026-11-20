//! Outbound HTTP/TCP in Zig; Mbed TLS owns TLS and client authentication.
//! The C ABI borrows all request buffers until return. Channel handles own their connection.
const std = @import("std");
const Io = std.Io;
// Layout matches bridge.h; keep the C ABI probe and adapters in sync.
const Request = extern struct {
    url: [*:0]const u8,
    method: [*:0]const u8,
    headers: [*]const [*:0]const u8,
    header_count: usize,
    ca: [*:0]const u8,
    certificate: [*:0]const u8,
    key: [*:0]const u8,
    insecure: c_int,
    has_body: c_int,
    truncate_response: c_int,
    connect_ms: i64,
    timeout_ms: i64,
    rate_limit: i64,
    body_size: i64,
    read: ?*const fn (?*anyopaque, [*]u8, usize) callconv(.c) usize,
    write: ?*const fn (?*anyopaque, [*]const u8, usize) callconv(.c) c_int,
    progress: ?*const fn (?*anyopaque, i64, i64, i64, i64) callconv(.c) c_int,
    context: ?*anyopaque,
    response_headers: [*]u8,
    response_body: [*]u8,
    header_capacity: usize,
    body_capacity: usize,
    header_length: usize,
    body_length: usize,
    uploaded: i64,
    downloaded: i64,
    status: c_long,
};
const allocator = std.heap.page_allocator;
const chunk_size = 64 * 1024;
const head_limit = 64 * 1024;
var base_io: Io = undefined;
var network_io: Io = undefined;
var network_vtable: Io.VTable = undefined;
var pool_mutex: Io.Mutex = .init;
var idle: [32]?*Connection = @splat(null);
var system_roots: std.crypto.Certificate.Bundle = .empty;
var system_roots_lock: Io.RwLock = .init;
var system_roots_loaded = false;
threadlocal var active: ?*RequestState = null;

// A process-lifetime I/O executor serves foreign C callers and independent Zig
// allocators. No application-owned allocator or Io is retained by this module.
var executor: Io.Threaded = undefined;
var initialized = std.atomic.Value(u8).init(0);
fn ensureInitialized() !void {
    if (initialized.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
        executor = Io.Threaded.init(allocator, .{});
        base_io = executor.io();
        network_vtable = base_io.vtable.*;
        network_vtable.operate = operate;
        network_io = .{ .userdata = base_io.userdata, .vtable = &network_vtable };
        initialized.store(if (ztls_init() == 0) 2 else 3, .release);
    }
    while (initialized.load(.acquire) == 1) std.atomic.spinLoopHint();
    if (initialized.load(.acquire) != 2) return error.TlsInitializationFailed;
}

extern fn ztls_init() c_int;
extern fn ztls_new(
    connection: *Connection,
    hostname: [*:0]const u8,
    roots: [*]const u8,
    roots_length: usize,
    certificate: [*:0]const u8,
    key: [*:0]const u8,
    insecure: c_int,
    require_ca: c_int,
    result: *c_int,
) ?*anyopaque;
extern fn ztls_free(?*anyopaque) void;
extern fn ztls_read(*anyopaque, [*]u8, usize) c_int;
extern fn ztls_write(*anyopaque, [*]const u8, usize) c_int;

fn now() i64 {
    return Io.Clock.awake.now(base_io).toMilliseconds();
}

const RequestState = struct {
    input: *Request,
    deadline: i64,
    total_deadline: i64,
    last_progress: i64 = 0,
    response_size: i64 = -1,
    failure: c_int = 0,
    require_ca: bool = false,
    channel: bool = false,

    fn check(self: *RequestState) !void {
        if (now() >= self.deadline) {
            self.failure = 28;
            return error.Timeout;
        }
        if (now() - self.last_progress >= 100) {
            self.last_progress = now();
            if (self.input.progress) |callback| {
                if (callback(
                    self.input.context,
                    self.response_size,
                    self.input.downloaded,
                    self.input.body_size,
                    self.input.uploaded,
                ) != 0) {
                    self.failure = 42;
                    return error.Canceled;
                }
            }
        }
    }

    fn pace(self: *RequestState, start: i64, count: i64) !void {
        if (self.input.rate_limit <= 0) return self.check();
        const target = start + @as(i64, @intCast(@divTrunc(@as(i128, count) * 1000, self.input.rate_limit)));
        while (now() < target) {
            try self.check();
            try Io.sleep(base_io, .fromMilliseconds(@min(50, @max(1, target - now()))), .awake);
        }
        try self.check();
    }
};

// Keep the same pending operation across progress ticks: resubmitting writes
// after a timeout can lose track of bytes transmitted at the deadline boundary.
fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    const state = active orelse return base_io.vtable.operate(userdata, operation);
    switch (operation) {
        .net_read, .net_write => {},
        else => return base_io.vtable.operate(userdata, operation),
    }
    var storage: [1]Io.Operation.Storage = undefined;
    var batch: Io.Batch = .init(&storage);
    defer batch.cancel(base_io);
    batch.addAt(0, operation);
    while (true) {
        state.check() catch return error.Canceled;
        batch.awaitConcurrent(base_io, .{ .duration = .{
            .raw = .fromMilliseconds(@min(100, @max(1, state.deadline - now()))),
            .clock = .awake,
        } }) catch |err| switch (err) {
            error.Timeout => continue,
            else => return error.Canceled,
        };
        if (batch.next()) |completion| return completion.result;
    }
}

const Connection = struct {
    stream: Io.net.Stream,
    socket_reader: Io.net.Stream.Reader,
    socket_writer: Io.net.Stream.Writer,
    tls: ?*anyopaque = null,
    tls_reader: Io.Reader = undefined,
    tls_writer: Io.Writer = undefined,
    buffers: []u8,
    identity: [32]u8,
    last_used: i64,
    deadline: i64,

    fn reader(self: *Connection) *Io.Reader {
        return if (self.tls != null) &self.tls_reader else &self.socket_reader.interface;
    }

    fn writer(self: *Connection) *Io.Writer {
        return if (self.tls != null) &self.tls_writer else &self.socket_writer.interface;
    }

    fn flush(self: *Connection) !void {
        try self.writer().flush();
        try self.socket_writer.interface.flush();
    }

    fn destroy(self: *Connection) void {
        ztls_free(self.tls);
        self.stream.close(base_io);
        allocator.free(self.buffers);
        allocator.destroy(self);
    }

    fn tlsStream(reader_interface: *Io.Reader, output: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *Connection = @alignCast(@fieldParentPtr("tls_reader", reader_interface));
        const dest = limit.slice(try output.writableSliceGreedy(1));
        const count = ztls_read(self.tls.?, dest.ptr, @min(dest.len, std.math.maxInt(c_int)));
        if (count < 0) return error.ReadFailed;
        if (count == 0) return error.EndOfStream;
        output.advance(@intCast(count));
        return @intCast(count);
    }

    fn tlsDrain(writer_interface: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *Connection = @alignCast(@fieldParentPtr("tls_writer", writer_interface));
        _ = splat;
        // Partial writes are intentional; Writer retries the remaining vectors.
        var bytes: []const u8 = writer_interface.buffered();
        if (bytes.len == 0) {
            for (data) |part| {
                if (part.len != 0) {
                    bytes = part;
                    break;
                }
            }
        }
        if (bytes.len == 0) return 0;
        const count = ztls_write(self.tls.?, bytes.ptr, @min(bytes.len, 16 * 1024));
        if (count <= 0) return error.WriteFailed;
        return writer_interface.consume(@intCast(count));
    }
};

export fn znet_socket_read(connection: *Connection, buffer: [*]u8, capacity: usize) c_int {
    var slices = [_][]u8{buffer[0..@min(capacity, std.math.maxInt(c_int))]};
    const received = connection.stream.readWithControl(network_io, &slices, &.{}) catch return -1;
    const count = received.data_len;
    return @intCast(count);
}

export fn znet_socket_write(connection: *Connection, buffer: [*]const u8, length: usize) c_int {
    const slices = [_][]const u8{buffer[0..@min(length, std.math.maxInt(c_int))]};
    const result = network_io.operate(.{ .net_write = .{
        .socket_handle = connection.stream.socket.handle,
        .data = &slices,
    } }) catch return -1;
    return @intCast(result.net_write catch return -1);
}

fn takeConnection(identity: [32]u8) !?*Connection {
    try pool_mutex.lock(base_io);
    defer pool_mutex.unlock(base_io);
    for (&idle) |*slot| {
        const connection = slot.* orelse continue;
        if (now() - connection.last_used > 90_000) {
            connection.destroy();
            slot.* = null;
        } else if (std.mem.eql(u8, &identity, &connection.identity)) {
            slot.* = null;
            return connection;
        }
    }
    return null;
}

fn releaseConnection(connection: *Connection) void {
    pool_mutex.lockUncancelable(base_io);
    defer pool_mutex.unlock(base_io);
    connection.last_used = now();
    for (&idle) |*slot| {
        if (slot.* == null) {
            slot.* = connection;
            return;
        }
    }
    connection.destroy();
}

fn connectTask(host: Io.net.HostName, port: u16, done: *std.atomic.Value(bool)) anyerror!Io.net.Stream {
    defer done.store(true, .release);
    return host.connect(base_io, port, .{ .mode = .stream });
}

fn connect(state: *RequestState, host: Io.net.HostName, port: u16) !Io.net.Stream {
    var done = std.atomic.Value(bool).init(false);
    var future = try Io.concurrent(base_io, connectTask, .{ host, port, &done });
    while (!done.load(.acquire)) {
        state.check() catch |err| {
            if (future.cancel(base_io)) |stream| stream.close(base_io) else |_| {}
            return err;
        };
        Io.sleep(base_io, .fromMilliseconds(1), .awake) catch |err| {
            if (future.cancel(base_io)) |stream| stream.close(base_io) else |_| {}
            return err;
        };
    }
    return future.await(base_io);
}

fn parseCertificates(bundle: *std.crypto.Certificate.Bundle, pem: []const u8) !void {
    const begin = "-----BEGIN CERTIFICATE-----";
    const end = "-----END CERTIFICATE-----";
    const decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");
    var offset: usize = 0;
    while (std.mem.findPos(u8, pem, offset, begin)) |start| {
        const first = start + begin.len;
        const last = std.mem.findPos(u8, pem, first, end) orelse return error.InvalidCertificate;
        const encoded = std.mem.trim(u8, pem[first..last], " \t\r\n");
        const decoded_start: u32 = @intCast(bundle.bytes.items.len);
        try bundle.bytes.ensureUnusedCapacity(allocator, encoded.len);
        const count = try decoder.decode(bundle.bytes.allocatedSlice()[decoded_start..], encoded);
        bundle.bytes.items.len += count;
        try bundle.parseCert(allocator, decoded_start, Io.Clock.real.now(base_io).toSeconds());
        offset = last + end.len;
    }
    if (bundle.map.count() == 0) return error.InvalidCertificate;
}

fn loadSystemRoots() !void {
    try system_roots_lock.lock(base_io);
    defer system_roots_lock.unlock(base_io);
    if (system_roots_loaded) return;
    try system_roots.rescan(allocator, base_io, Io.Clock.real.now(base_io));
    system_roots_loaded = true;
}

fn acquire(state: *RequestState, uri: std.Uri) !*Connection {
    var host_buffer: [Io.net.HostName.max_len]u8 = undefined;
    const host = try Io.net.HostName.fromUri(uri, &host_buffer);
    const secure = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    const port = uri.port orelse @as(u16, if (secure) 443 else 80);
    const ca_path = std.mem.span(state.input.ca);
    const pem = if (ca_path.len == 0) null else Io.Dir.cwd().readFileAlloc(base_io, ca_path, allocator, .limited(16 * 1024 * 1024)) catch {
        state.failure = 60;
        return error.InvalidCertificate;
    };
    defer if (pem) |bytes| allocator.free(bytes);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(host.bytes);
    hash.update(std.mem.asBytes(&port));
    hash.update(&.{ @intFromBool(secure), @intFromBool(state.input.insecure != 0) });
    if (pem) |bytes| hash.update(bytes);
    // Pool identity and the TLS handshake consume the same material snapshot.
    // This prevents a certificate rotation between hashing and loading a key.
    var credentials: [2]?[:0]u8 = @splat(null);
    defer for (credentials) |material| {
        if (material) |bytes| {
            std.crypto.secureZero(u8, bytes);
            allocator.free(bytes);
        }
    };
    for ([_][*:0]const u8{ state.input.certificate, state.input.key }, 0..) |path, index| {
        const name = std.mem.span(path);
        if (name.len == 0) continue;
        const material = Io.Dir.cwd().readFileAlloc(base_io, name, allocator, .limited(16 * 1024 * 1024)) catch {
            state.failure = 60;
            return error.InvalidCertificate;
        };
        defer {
            std.crypto.secureZero(u8, material);
            allocator.free(material);
        }
        credentials[index] = try allocator.dupeSentinel(u8, material, 0);
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, material.len, .big);
        hash.update(&length);
        hash.update(material);
    }
    const identity = hash.finalResult();
    if (!state.channel) {
        if (try takeConnection(identity)) |existing| return existing;
    }
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(allocator);

    if (secure and (state.input.insecure == 0 or pem != null)) {
        if (pem) |bytes| {
            parseCertificates(&bundle, bytes) catch {
                state.failure = 60;
                return error.InvalidCertificate;
            };
        } else {
            loadSystemRoots() catch {
                state.failure = 60;
                return error.InvalidCertificate;
            };
        }
    }
    const stream = try connect(state, host, port);
    errdefer stream.close(base_io);
    const connection = try allocator.create(Connection);
    errdefer allocator.destroy(connection);
    const buffers = try allocator.alloc(u8, head_limit * 2 + chunk_size * 2);
    errdefer allocator.free(buffers);
    connection.* = .{
        .stream = stream,
        .socket_reader = stream.reader(network_io, buffers[0..head_limit]),
        .socket_writer = stream.writer(network_io, buffers[head_limit..][0..chunk_size]),
        .buffers = buffers,
        .identity = identity,
        .last_used = now(),
        .deadline = state.total_deadline,
    };
    connection.tls_reader = .{
        .seek = 0,
        .end = 0,
        .buffer = buffers[head_limit + chunk_size ..][0..head_limit],
        .vtable = &.{ .stream = Connection.tlsStream },
    };
    connection.tls_writer = .{
        .buffer = buffers[2 * head_limit + chunk_size ..][0..chunk_size],
        .vtable = &.{ .drain = Connection.tlsDrain },
    };
    if (secure) {
        var encoded_roots: std.ArrayList(u8) = .empty;
        defer encoded_roots.deinit(allocator);
        if (state.input.insecure == 0 or pem != null) {
            const roots = if (pem != null) &bundle else &system_roots;
            var entries = roots.map.valueIterator();
            while (entries.next()) |index| {
                const cert = try std.crypto.Certificate.der.Element.parse(roots.bytes.items, index.*);
                const bytes = roots.bytes.items[index.*..cert.slice.end];
                var length: [4]u8 = undefined;
                std.mem.writeInt(u32, &length, @intCast(bytes.len), .big);
                try encoded_roots.appendSlice(allocator, &length);
                try encoded_roots.appendSlice(allocator, bytes);
            }
        }
        const hostname = try allocator.dupeSentinel(u8, host.bytes, 0);
        defer allocator.free(hostname);
        var result: c_int = 0;
        connection.tls = ztls_new(
            connection,
            hostname,
            encoded_roots.items.ptr,
            encoded_roots.items.len,
            if (credentials[0]) |bytes| bytes.ptr else "",
            if (credentials[1]) |bytes| bytes.ptr else "",
            state.input.insecure,
            @intFromBool(state.require_ca),
            &result,
        ) orelse {
            if (state.failure == 0) state.failure = result;
            return error.TlsHandshakeFailed;
        };
    }
    return connection;
}

fn sendHeaders(connection: *Connection, input: *Request, uri: std.Uri) !void {
    const writer = connection.writer();
    try writer.print("{s} ", .{std.mem.span(input.method)});
    try uri.writeToStream(writer, .{ .path = true, .query = true });
    try writer.writeAll(" HTTP/1.1\r\n");
    var has_host = false;
    for (input.headers[0..input.header_count]) |pointer| {
        const line = std.mem.span(pointer);
        if (line.len == 0) continue;
        const colon = std.mem.findScalar(u8, line, ':');
        const split = colon orelse blk: {
            if (!std.mem.endsWith(u8, line, ";")) return error.InvalidHeader;
            break :blk line.len - 1;
        };
        const name = line[0..split];
        const value = std.mem.trim(u8, line[split + 1 ..], " \t");
        if (name.len == 0 or std.mem.findAny(u8, line, "\r\n") != null) return error.InvalidHeader;
        if (std.ascii.eqlIgnoreCase(name, "Host")) has_host = true;
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) continue;
        if (colon != null and value.len == 0) continue;
        try writer.print("{s}: {s}\r\n", .{ name, value });
    }
    if (!has_host) {
        try writer.writeAll("Host: ");
        try uri.writeToStream(writer, .{ .authority = true });
        try writer.writeAll("\r\n");
    }
    if (input.has_body != 0) try writer.print("Content-Length: {d}\r\n", .{input.body_size});
    try writer.writeAll("\r\n");
}

fn sendBody(connection: *Connection, state: *RequestState) !void {
    const input = state.input;
    var buffer: [chunk_size]u8 = undefined;
    const upload_start = now();
    while (input.uploaded < input.body_size and input.has_body != 0) {
        try state.check();
        const capacity: usize = @intCast(@min(buffer.len, input.body_size - input.uploaded));
        const count = input.read.?(input.context, &buffer, capacity);
        if (count == 0 or count > capacity) return error.CallbackBounds;
        try connection.writer().writeAll(buffer[0..count]);
        input.uploaded += @intCast(count);
        try state.pace(upload_start, input.uploaded);
    }
    try connection.flush();
}

fn perform(state: *RequestState) !void {
    const input = state.input;
    const uri = try std.Uri.parse(std.mem.span(input.url));
    if ((!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) or
        uri.user != null or uri.password != null) return error.InvalidUri;
    const connection = try acquire(state, uri);
    var reusable = false;
    defer if (reusable) releaseConnection(connection) else connection.destroy();
    state.deadline = state.total_deadline;
    try state.check();
    try sendHeaders(connection, input, uri);
    // A server can reject a signed request before consuming its body. Preserve
    // its HTTP error response even when that causes the upload write to fail.
    const upload_error: ?anyerror = blk: {
        sendBody(connection, state) catch |err| switch (err) {
            error.WriteFailed => break :blk err,
            else => return err,
        };
        break :blk null;
    };
    if (state.failure != 0) return error.Canceled;
    var buffer: [chunk_size]u8 = undefined;
    var reader: std.http.Reader = .{
        .in = connection.reader(),
        .interface = undefined,
        .state = .ready,
        .max_head_len = head_limit,
    };
    var head: std.http.Client.Response.Head = undefined;
    while (true) {
        const bytes = try reader.receiveHead();
        head = try std.http.Client.Response.Head.parse(bytes);
        const status = @backingInt(head.status);
        if (status >= 100 and status < 200 and status != 101) continue;
        input.status = @intCast(status);
        if (input.header_capacity > 0) {
            if (bytes.len > input.header_capacity) return error.CallbackBounds;
            @memcpy(input.response_headers[0..bytes.len], bytes);
            input.header_length = bytes.len;
        }
        break;
    }
    if (upload_error) |err| {
        if (input.status < 400) return err;
    }
    const bodiless = std.mem.eql(u8, std.mem.span(input.method), "HEAD") or
        input.status == 204 or input.status == 304;
    const body_length = if (bodiless) @as(?u64, 0) else head.content_length;
    state.response_size = if (body_length) |length| @intCast(@min(length, std.math.maxInt(i64))) else -1;
    const body = reader.bodyReader(&.{}, if (bodiless) .none else head.transfer_encoding, body_length);
    const download_start = now();
    while (true) {
        try state.check();
        var slices = [_][]u8{&buffer};
        const count = body.readVec(&slices) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return error.TruncatedResponse,
        };
        if (count == 0) continue;
        input.downloaded += @intCast(count);
        if (input.write != null and input.status >= 200 and input.status < 300) {
            if (input.write.?(input.context, &buffer, count) != 0) return error.CallbackBounds;
        } else {
            const available = input.body_capacity - input.body_length;
            if (count > available and input.truncate_response == 0) return error.CallbackBounds;
            const retained = @min(count, available);
            if (retained > 0) @memcpy(input.response_body[input.body_length..][0..retained], buffer[0..retained]);
            input.body_length += retained;
        }
        try state.pace(download_start, input.downloaded);
    }
    if (body_length) |length| {
        if (input.downloaded != length) return error.TruncatedResponse;
    }
    reusable = upload_error == null and head.keep_alive and reader.state == .ready and input.status != 101;
    state.last_progress = 0;
    try state.check();
}

export fn znet_http(input: *Request) c_int {
    input.status = 0;
    input.header_length = 0;
    input.body_length = 0;
    input.uploaded = 0;
    input.downloaded = 0;
    if (input.timeout_ms <= 0 or input.connect_ms <= 0 or input.body_size < 0 or
        (input.has_body != 0 and input.body_size > 0 and input.read == null)) return 3;
    ensureInitialized() catch return 35;
    const start = now();
    var state: RequestState = .{
        .input = input,
        .deadline = start + @min(input.timeout_ms, input.connect_ms),
        .total_deadline = start + input.timeout_ms,
    };
    active = &state;
    defer active = null;
    perform(&state) catch |err| {
        if (state.failure != 0) return state.failure;
        return switch (err) {
            error.CallbackBounds, error.HttpHeadersOversize => -2,
            error.TruncatedResponse, error.HttpRequestTruncated => 18,
            error.HttpConnectionClosing => 52,
            error.UnknownHostName, error.NameServerFailure => 6,
            error.InvalidUri, error.InvalidHeader, error.UriMissingHost, error.InvalidFormat, error.InvalidPort => 3,
            error.Timeout => 28,
            error.Canceled => 42,
            else => 7,
        };
    };
    return 0;
}

fn channelRequest(timeout_ms: i64) Request {
    var request = std.mem.zeroes(Request);
    request.url = "";
    request.method = "";
    request.ca = "";
    request.certificate = "";
    request.key = "";
    request.timeout_ms = timeout_ms;
    request.connect_ms = timeout_ms;
    return request;
}

export fn znet_open(address: [*:0]const u8, ca: [*:0]const u8, certificate: [*:0]const u8, key: [*:0]const u8, policy: c_int, trust_leaf: c_int, timeout: c_long, result: *c_int) usize {
    result.* = 3;
    if (timeout <= 0 or timeout > 86400 or policy < 0 or policy > 2) return 0;
    ensureInitialized() catch {
        result.* = 35;
        return 0;
    };
    var request = channelRequest(@as(i64, timeout) * 1000);
    request.ca = ca;
    request.certificate = certificate;
    request.key = key;
    request.insecure = @intFromBool(policy == 2);
    const uri = std.Uri.parse(std.mem.span(address)) catch return 0;
    if ((!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) or uri.user != null) return 0;
    const deadline = now() + request.timeout_ms;
    var state: RequestState = .{
        .input = &request,
        .deadline = deadline,
        .total_deadline = deadline,
        .require_ca = trust_leaf == 0,
        .channel = true,
    };
    active = &state;
    defer active = null;
    const connection = acquire(&state, uri) catch {
        result.* = if (state.failure != 0) state.failure else 7;
        return 0;
    };
    result.* = 0;
    return @intFromPtr(connection);
}

export fn znet_read(handle: usize, buffer: [*]u8, capacity: usize, used: *usize) c_int {
    used.* = 0;
    if (handle == 0 or capacity == 0) return 3;
    const connection: *Connection = @ptrFromInt(handle);
    var request = channelRequest(1);
    var state: RequestState = .{ .input = &request, .deadline = connection.deadline, .total_deadline = connection.deadline };
    active = &state;
    defer active = null;
    state.check() catch return state.failure;
    var slices = [_][]u8{buffer[0..capacity]};
    used.* = connection.reader().readVec(&slices) catch |err| {
        if (state.failure != 0) return state.failure;
        return if (err == error.EndOfStream) 52 else 7;
    };
    return 0;
}

export fn znet_write(handle: usize, buffer: [*]const u8, length: usize) c_int {
    if (handle == 0) return 3;
    const connection: *Connection = @ptrFromInt(handle);
    var request = channelRequest(1);
    var state: RequestState = .{ .input = &request, .deadline = connection.deadline, .total_deadline = connection.deadline };
    active = &state;
    defer active = null;
    state.check() catch return state.failure;
    connection.writer().writeAll(buffer[0..length]) catch return if (state.failure != 0) state.failure else 7;
    connection.flush() catch return if (state.failure != 0) state.failure else 7;
    return 0;
}

export fn znet_close(handle: usize) void {
    if (handle == 0) return;
    const connection: *Connection = @ptrFromInt(handle);
    connection.destroy();
}
