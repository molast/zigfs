const std = @import("std");
const delivery = @import("../ports/event_delivery.zig");

pub const Binding = struct { destination_name: []const u8, sender: delivery.Sender };
pub const Error = delivery.Error || error{DestinationNotRegistered};

/// Runtime composition binds Webhook/MQTT/future adapters to destination names.
/// This dispatcher borrows the immutable bindings and adapter instances. Their
/// owner must keep them alive throughout delivery, including configuration reloads.
/// Configuration persistence never registers a sender or initiates delivery.
pub const Dispatcher = struct {
    bindings: []const Binding,

    pub fn init(bindings: []const Binding) error{InvalidBinding}!Dispatcher {
        for (bindings, 0..) |binding, i| {
            if (binding.destination_name.len == 0) return error.InvalidBinding;
            for (bindings[0..i]) |previous| if (std.mem.eql(u8, previous.destination_name, binding.destination_name)) return error.InvalidBinding;
        }
        return .{ .bindings = bindings };
    }

    pub fn deliver(self: Dispatcher, a: std.mem.Allocator, io: std.Io, destination_name: []const u8, event: delivery.Event) Error!void {
        for (self.bindings) |binding| {
            if (std.mem.eql(u8, binding.destination_name, destination_name)) return binding.sender.send(a, io, event);
        }
        // Never treat an unsupported/unregistered destination as successfully sent.
        return error.DestinationNotRegistered;
    }
};

test "dispatcher uses the same delivery contract for independent adapters and preserves failures" {
    const Fake = struct {
        calls: usize = 0,
        failure: ?delivery.Error = null,
        last_id: []const u8 = "",
        fn send(ctx: *anyopaque, _: std.mem.Allocator, _: std.Io, event: delivery.Event) delivery.Error!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            self.last_id = event.id;
            if (self.failure) |err| return err;
        }
        fn sender(self: *@This()) delivery.Sender {
            return .{ .context = self, .vtable = &.{ .send = send } };
        }
    };
    var webhook = Fake{};
    var mqtt = Fake{ .failure = error.Unavailable };
    const bindings = [_]Binding{
        .{ .destination_name = "WEBHOOK_1", .sender = webhook.sender() },
        .{ .destination_name = "MQTT_1", .sender = mqtt.sender() },
    };
    const dispatcher = try Dispatcher.init(&bindings);
    const event: delivery.Event = .{ .id = "event-1", .payload = "{\"Records\":[]}" };
    try dispatcher.deliver(std.testing.allocator, std.testing.io, "WEBHOOK_1", event);
    try std.testing.expectEqual(@as(usize, 1), webhook.calls);
    try std.testing.expectEqual(@as(usize, 0), mqtt.calls);
    try std.testing.expectError(error.Unavailable, dispatcher.deliver(std.testing.allocator, std.testing.io, "MQTT_1", event));
    try std.testing.expectEqualStrings(event.id, mqtt.last_id);
    try std.testing.expect(delivery.retryable(error.Unavailable));
    try std.testing.expect(!delivery.retryable(error.AuthenticationFailed));
    try std.testing.expectError(error.DestinationNotRegistered, dispatcher.deliver(std.testing.allocator, std.testing.io, "KAFKA_1", event));
    try std.testing.expectError(error.InvalidEvent, dispatcher.deliver(std.testing.allocator, std.testing.io, "WEBHOOK_1", .{ .id = "", .payload = "{}" }));
    try std.testing.expectEqual(@as(usize, 1), webhook.calls);
    try std.testing.expectError(error.InvalidBinding, Dispatcher.init(&.{ bindings[0], bindings[0] }));
}
