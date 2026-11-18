const std = @import("std");
const zigfs = @import("zigfs");

/// Isolated conformance runner. Not included in the server or normal install.
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.InvalidArguments;
    var root = try std.Io.Dir.cwd().openDir(init.io, args[1], .{});
    defer root.close(init.io);
    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], a, .limited(1024 * 1024));
    const Input = struct { destination: zigfs.application.event_destinations.Destination, event: zigfs.ports.event_delivery.Event, timeout_seconds: c_long = 2, expected_error: []const u8 = "" };
    const input = try std.json.parseFromSlice(Input, a, data, .{});
    const targets = try zigfs.backend.event_targets.Targets.init(a, root, &.{input.value.destination}, input.value.timeout_seconds);
    defer targets.deinit();
    targets.deliver(a, init.io, input.value.destination.name, input.value.event) catch |err| {
        if (std.mem.eql(u8, @errorName(err), input.value.expected_error)) return;
        std.debug.print("unexpected delivery result: {s}\n", .{@errorName(err)});
        return error.UnexpectedDeliveryResult;
    };
    if (input.value.expected_error.len > 0) return error.ExpectedDeliveryFailure;
}
