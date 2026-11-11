const std = @import("std");
const Application = @import("../application/mod.zig").Application;
const schema = @import("../application/audit_schema.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    actor: []const u8 = "anonymous",
    action: []const u8,
    target: []const u8,
    request: schema.Request = .{},
    identity: schema.Identity = .{},
    resource_override: ?schema.Resource = null,

    pub fn capture(self: *Context, request: *std.http.Server.Request, peer: std.Io.net.IpAddress) !void {
        const a = self.allocator;
        self.request.method = @tagName(request.head.method);
        self.request.path = self.target;
        self.request.protocol = if (request.head.version == .@"HTTP/1.1") "HTTP/1.1" else "HTTP/1.0";
        const address = try std.fmt.allocPrint(a, "{f}", .{peer});
        self.request.source_ip = if (address[0] == '[') address[1..std.mem.indexOfScalar(u8, address, ']').?] else address[0..std.mem.lastIndexOfScalar(u8, address, ':').?];
        // No trusted-proxy configuration exists: never trust client-supplied forwarding headers.
        var headers = request.iterateHeaders();
        while (headers.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "user-agent")) {
            self.request.user_agent = try a.dupe(u8, header.value[0..@min(header.value.len, 1024)]);
        };
        if (std.mem.indexOfScalar(u8, request.head.target, '?')) |start| {
            var parameters = std.mem.splitScalar(u8, request.head.target[start + 1 ..], '&');
            while (parameters.next()) |parameter| {
                const equal = std.mem.indexOfScalar(u8, parameter, '=') orelse continue;
                inline for (@typeInfo(schema.Query).@"struct".field_names) |name| {
                    if (std.mem.eql(u8, parameter[0..equal], name) and parameter.len - equal <= 2049) @field(self.request.query, name) = try schema.decode(a, parameter[equal + 1 ..]);
                }
            }
        }
    }
    pub fn identify(self: *Context, actor: []const u8) !void {
        self.actor = try self.allocator.dupe(u8, actor);
        self.identity.principal_name = self.actor;
        self.identity.auth_type = "internal";
    }
    pub fn authenticate(self: *Context, auth_type: []const u8, principal_id: ?[]const u8, access_key_id: ?[]const u8) !void {
        self.identity.auth_type = auth_type;
        self.identity.principal_id = if (principal_id) |id| try self.allocator.dupe(u8, id) else null;
        self.identity.access_key_id = if (access_key_id) |id| try self.allocator.dupe(u8, id) else null;
    }
    pub fn setResource(self: *Context, value: schema.Resource) !void {
        self.resource_override = try schema.cloneResource(self.allocator, value);
    }
    pub fn operation(self: *Context, action: []const u8, target: []const u8) !void {
        self.action = try self.allocator.dupe(u8, action);
        self.target = try self.allocator.dupe(u8, target);
    }
    pub fn finish(self: *Context, app: *Application, request_id: []const u8, status: std.http.Status, duration_ms: u64) void {
        const a = self.allocator;
        const now = std.Io.Clock.real.now(app.io.?);
        const seconds = now.toSeconds();
        var date_buffer: [24]u8 = undefined;
        const event_time = @import("../common/time.zig").formatIso8601Milliseconds(@intCast(now.toMilliseconds()), &date_buffer) catch return;
        const id = @import("../common/id.zig").randomV4(app.io.?) catch return;
        const event_id = std.fmt.allocPrint(a, "evt_{s}", .{std.fmt.bytesToHex(id, .lower)}) catch return;
        const spec = schema.classify(self.action, self.request.method, self.request.path);
        const response_status = schema.statusName(@intCast(@backingInt(status)));
        const denied = std.mem.eql(u8, response_status, "denied");
        const resource = self.resource_override orelse (schema.resourceFor(a, self.target, spec, self.request.query) catch return);
        var buffer: [32]u8 = undefined;
        const outcome = std.fmt.bufPrint(&buffer, "{s}:{d}", .{ if (@backingInt(status) < 400) "success" else "failure", @backingInt(status) }) catch return;
        self.request.request_id = request_id;
        app.recordAudit(.{
            .event_id = event_id,
            .event_time = event_time,
            .event_category = if (denied) "security" else spec.category,
            .event_type = if (denied) "security_event" else if (std.mem.eql(u8, spec.service, "s3") or std.mem.eql(u8, spec.service, "sts")) "api_request" else "admin_action",
            .event_action = spec.name,
            .request = self.request,
            .identity = self.identity,
            .resource = resource,
            .operation = .{ .name = spec.name, .service = spec.service, .is_read_only = spec.is_read_only },
            .response = .{ .status = response_status, .http_status = @intCast(@backingInt(status)), .duration_ms = duration_ms },
            .metadata = .{ .region = app.config.s3_region },
            .timestamp_unix_seconds = seconds,
            .request_id = request_id,
            .actor = self.actor,
            .action = self.action,
            .target = self.target,
            .outcome = outcome,
        });
    }
};
