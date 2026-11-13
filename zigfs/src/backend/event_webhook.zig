const std = @import("std");
const delivery = @import("../ports/event_delivery.zig");
const destinations = @import("../application/event_destinations.zig");

/// Configuration and data root are borrowed and must outlive a send call.
pub const Webhook = struct {
    config: destinations.Destination,
    root: std.Io.Dir,
    timeout_seconds: c_long = 10,

    pub fn sender(self: *Webhook) delivery.Sender {
        return .{ .context = self, .vtable = &.{ .send = send } };
    }
    fn send(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io, event: delivery.Event) delivery.Error!void {
        const self: *Webhook = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, self.config.type, "webhook")) return error.InvalidConfiguration;
        destinations.validate(self.config) catch return error.InvalidConfiguration;
        if (self.timeout_seconds < 1 or self.timeout_seconds > 60) return error.InvalidConfiguration;
        // The common event format is JSON. Reject headers/body that the C API cannot represent.
        if (!std.mem.eql(u8, event.content_type, "application/json") or std.mem.indexOfScalar(u8, event.payload, 0) != null or !validHeader(event.id)) return error.InvalidEvent;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const url = try a.dupeSentinel(u8, self.config.endpoint, 0);
        const body = try a.dupeSentinel(u8, event.payload, 0);
        const authorization = if (self.config.auth_token.len > 0) try std.fmt.allocPrintSentinel(a, "Authorization: {s}", .{self.config.auth_token}, 0) else try a.dupeSentinel(u8, "", 0);
        const event_header = try std.fmt.allocPrintSentinel(a, "X-ZigFS-Event-ID: {s}", .{event.id}, 0);
        const ca = try certificatePath(a, self.root, io, self.config.client_ca);
        const cert = try certificatePath(a, self.root, io, self.config.client_certificate);
        const key = try certificatePath(a, self.root, io, self.config.client_key);
        var buffer: [4096]u8 = undefined;
        var length: usize = 0;
        var status: c_long = 0;
        const result = zigfs_event_webhook(url, body.ptr, event.payload.len, authorization, event_header, ca, cert, key, @intFromBool(self.config.skip_tls_verify), self.timeout_seconds, &buffer, buffer.len, &length, &status);
        if (result != 0) return curlError(result);
        if (status >= 200 and status < 300) return;
        return statusError(status);
    }
};
fn validHeader(value: []const u8) bool {
    if (value.len == 0 or value.len > 256) return false;
    for (value) |c| if (c < 32 or c == 127) return false;
    return true;
}
pub fn certificatePath(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, value: []const u8) delivery.Error![:0]const u8 {
    if (value.len == 0) return try a.dupeSentinel(u8, "", 0);
    // Resolving symlinks here also prevents a relative setting from escaping data.
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const size = root.realPath(io, &root_buffer) catch return error.InvalidConfiguration;
    const resolved = root.realPathFileAlloc(io, value, a) catch return error.InvalidConfiguration;
    const prefix = std.mem.trimEnd(u8, root_buffer[0..size], "/");
    if (!std.mem.startsWith(u8, resolved, prefix) or resolved.len <= prefix.len or resolved[prefix.len] != '/') return error.InvalidConfiguration;
    return resolved;
}
pub fn statusError(status: c_long) delivery.Error {
    return switch (status) {
        401, 403 => error.AuthenticationFailed,
        408, 504 => error.Timeout,
        429 => error.RateLimited,
        500...503, 505...599 => error.Unavailable,
        else => error.Rejected,
    };
}
pub fn curlError(code: c_int) delivery.Error {
    return switch (code) {
        28 => error.Timeout,
        2, 3, 4, 43, 58, 60, 77, 82, 83, 90, 91 => error.InvalidConfiguration,
        67 => error.AuthenticationFailed,
        27 => error.OutOfMemory,
        else => error.Unavailable,
    };
}
extern fn zigfs_event_webhook([*:0]const u8, [*]const u8, usize, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, c_int, c_long, [*]u8, usize, *usize, *c_long) c_int;

test "webhook status failures preserve retry classification" {
    try std.testing.expectEqual(error.AuthenticationFailed, statusError(401));
    try std.testing.expectEqual(error.RateLimited, statusError(429));
    try std.testing.expectEqual(error.Rejected, statusError(302));
    try std.testing.expect(delivery.retryable(statusError(503)));
    try std.testing.expect(!delivery.retryable(curlError(60)));
}
