const std = @import("std");
const config = @import("../application/event_destinations.zig");
const delivery = @import("../ports/event_delivery.zig");
const dispatcher = @import("../application/event_dispatcher.zig");
const Webhook = @import("event_webhook.zig").Webhook;
const mqtt = @import("event_mqtt.zig");

/// This is the only protocol selection point. Preparing adapters performs no I/O.
pub const Adapter = union(enum) {
    webhook: Webhook,
    mqtt: mqtt.Mqtt,

    pub fn init(destination: config.Destination, root: std.Io.Dir, timeout_seconds: c_long) delivery.Error!Adapter {
        config.validate(destination) catch return error.InvalidConfiguration;
        if (timeout_seconds < 1 or timeout_seconds > 60) return error.InvalidConfiguration;
        if (std.mem.eql(u8, destination.type, "webhook")) return .{ .webhook = .{ .config = destination, .root = root, .timeout_seconds = timeout_seconds } };
        if (std.mem.eql(u8, destination.type, "mqtt")) return .{ .mqtt = .{ .config = destination, .root = root, .timeout_seconds = timeout_seconds } };
        return error.InvalidConfiguration;
    }
    pub fn sender(self: *Adapter) delivery.Sender {
        return switch (self.*) {
            .webhook => |*value| value.sender(),
            .mqtt => |*value| value.sender(),
        };
    }
};

pub const Policy = struct {
    queue_limit: u32,
    queue_directory: []const u8,
    retry_interval_ms: u64,
};
/// Snapshot of configured adapters. Configuration strings and root are borrowed;
/// the caller must retain them until deinit and await in-flight sends before reload.
pub const Targets = struct {
    allocator: std.mem.Allocator,
    adapters: []Adapter,
    bindings: []dispatcher.Binding,
    policies: []Policy,
    dispatch: dispatcher.Dispatcher,

    pub fn init(a: std.mem.Allocator, root: std.Io.Dir, destinations: []const config.Destination, timeout_seconds: c_long) !Targets {
        const adapters = try a.alloc(Adapter, destinations.len);
        errdefer a.free(adapters);
        const bindings = try a.alloc(dispatcher.Binding, destinations.len);
        errdefer a.free(bindings);
        const policies = try a.alloc(Policy, destinations.len);
        errdefer a.free(policies);
        for (destinations, 0..) |destination, i| {
            adapters[i] = try Adapter.init(destination, root, timeout_seconds);
            bindings[i] = .{ .destination_name = destination.name, .sender = adapters[i].sender() };
            policies[i] = .{ .queue_limit = destination.queue_limit, .queue_directory = destination.queue_directory, .retry_interval_ms = if (std.mem.eql(u8, destination.type, "mqtt")) try mqtt.durationMs(destination.reconnect_interval) else 1000 };
        }
        return .{ .allocator = a, .adapters = adapters, .bindings = bindings, .policies = policies, .dispatch = try dispatcher.Dispatcher.init(bindings) };
    }
    pub fn deinit(self: Targets) void {
        self.allocator.free(self.adapters);
        self.allocator.free(self.bindings);
        self.allocator.free(self.policies);
    }
    pub fn deliver(self: Targets, a: std.mem.Allocator, io: std.Io, name: []const u8, event: delivery.Event) dispatcher.Error!void {
        return self.dispatch.deliver(a, io, name, event);
    }
    pub fn policy(self: Targets, name: []const u8) ?Policy {
        for (self.bindings, 0..) |binding, i| if (std.mem.eql(u8, binding.destination_name, name)) return self.policies[i];
        return null;
    }
};

test "preparing both transports requires no connections and retains common queue policy" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const targets = try Targets.init(std.testing.allocator, dir.dir, &.{
        .{ .name = "HTTP", .endpoint = "http://127.0.0.1:1/events" },
        .{ .name = "MQTT", .type = "mqtt", .broker = "tcp://127.0.0.1:1", .topic = "events", .reconnect_interval = "2s", .queue_directory = "events/MQTT", .queue_limit = 3 },
    }, 1);
    defer targets.deinit();
    try std.testing.expectEqual(@as(u64, 2000), targets.policy("MQTT").?.retry_interval_ms);
    try std.testing.expectEqual(@as(u32, 3), targets.policy("MQTT").?.queue_limit);
    try std.testing.expect(targets.policy("MISSING") == null);
    try std.testing.expectError(error.DestinationNotRegistered, targets.deliver(std.testing.allocator, std.testing.io, "MISSING", .{ .id = "one", .payload = "{}" }));
}
