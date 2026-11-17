const std = @import("std");
const metadata = @import("metadata_engine");
const count = 3;

const Controller = struct {
    root: std.Io.Dir,
    io: std.Io,
    scenario: []const u8,
    collecting: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    acknowledged: [count]std.Io.Event = @splat(.unset),
    appended: usize = 0,

    fn pause(self: *Controller) noreturn {
        var file = self.root.createFile(self.io, "READY", .{}) catch std.process.exit(91);
        file.writeStreamingAll(self.io, self.scenario) catch std.process.exit(92);
        file.sync(self.io) catch std.process.exit(93);
        file.close(self.io);
        while (true) self.io.sleep(.fromSeconds(1), .awake) catch {};
    }

    fn engineHook(context: *anyopaque, point: metadata.Point) void {
        const self: *Controller = @ptrCast(@alignCast(context));
        if (point == .after_append) {
            self.appended += 1;
            if (std.mem.eql(u8, self.scenario, "append-1") and self.appended == 1) self.pause();
            if (std.mem.eql(u8, self.scenario, "append-2") and self.appended == 2) self.pause();
        }
        if (point == .before_sync and std.mem.eql(u8, self.scenario, "before-sync")) self.pause();
        if (point == .after_sync and std.mem.eql(u8, self.scenario, "after-sync")) self.pause();
    }

    fn runtimeHook(context: *anyopaque, point: metadata.RuntimePoint, size: usize) void {
        const self: *Controller = @ptrCast(@alignCast(context));
        switch (point) {
            .before_collect => {
                self.collecting.set(self.io);
                self.release.waitUncancelable(self.io);
            },
            .before_group => {
                // Gated enqueue order guarantees exactly three independent
                // two-record transactions in one group, not three single groups.
                if (size != count) std.process.exit(94);
                if (std.mem.eql(u8, self.scenario, "before-group")) self.pause();
            },
            .after_group => {
                if (std.mem.eql(u8, self.scenario, "after-group")) self.pause();
            },
            .after_notify => {
                if (size == 1 and std.mem.eql(u8, self.scenario, "notify-1")) {
                    // Confirm the first caller actually observed success and
                    // persisted its receipt before allowing the parent to kill.
                    self.acknowledged[0].waitUncancelable(self.io);
                    self.pause();
                }
            },
        }
    }
};

fn writer(runtime: *metadata.Runtime, controller: *Controller, index: usize) anyerror!void {
    var first_buffer: [32]u8 = undefined;
    var second_buffer: [32]u8 = undefined;
    var payload_buffer: [32]u8 = undefined;
    const first = try std.fmt.bufPrint(&first_buffer, "group/{d}/a", .{index});
    const second = try std.fmt.bufPrint(&second_buffer, "group/{d}/b", .{index});
    const payload = try std.fmt.bufPrint(&payload_buffer, "request-{d}", .{index});
    const generation = try runtime.commit(&.{
        .{ .record_type = .object, .key = first, .payload = payload, .expected = .missing },
        .{ .record_type = .object, .key = second, .payload = payload, .expected = .missing },
    });
    var name_buffer: [32]u8 = undefined;
    var receipt_buffer: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "ACK-{d}", .{index});
    const receipt = try std.fmt.bufPrint(&receipt_buffer, "{d}", .{generation});
    var file = try controller.root.createFile(controller.io, name, .{});
    defer file.close(controller.io);
    try file.writeStreamingAll(controller.io, receipt);
    try file.sync(controller.io);
    controller.acknowledged[index].set(controller.io);
}

pub fn crash(engine: *metadata.Engine, scenario: []const u8) !void {
    const allowed = [_][]const u8{
        "before-group", "append-1", "append-2", "before-sync", "after-sync", "after-group", "notify-1",
    };
    var valid = false;
    for (allowed) |name| {
        if (std.mem.eql(u8, name, scenario)) valid = true;
    }
    if (!valid) return error.InvalidArguments;
    var controller: Controller = .{ .root = engine.root, .io = engine.io, .scenario = scenario };
    engine.hook = .{ .context = &controller, .call = Controller.engineHook };
    defer engine.hook = null;
    var runtime: metadata.Runtime = .{
        .engine = engine,
        .options = .{ .group_delay_us = 0, .max_group_transactions = count, .checkpoint_interval_ms = 0 },
        .hook = .{ .context = &controller, .call = Controller.runtimeHook },
    };
    try runtime.start();
    defer runtime.stop();
    var futures: [count]std.Io.Future(anyerror!void) = undefined;
    var started: usize = 0;
    defer {
        controller.release.set(engine.io);
        for (futures[0..started]) |*future| future.await(engine.io) catch {};
    }
    for (&futures, 0..) |*future, index| {
        future.* = try engine.io.concurrent(writer, .{ &runtime, &controller, index });
        started += 1;
        if (index == 0) controller.collecting.waitUncancelable(engine.io);
        const since = std.Io.Clock.awake.now(engine.io);
        while (runtime.stats().queued != index + 1) {
            if (since.durationTo(std.Io.Clock.awake.now(engine.io)).toMilliseconds() > 5000)
                return error.EnqueueTimeout;
            try engine.io.sleep(.fromMilliseconds(1), .awake);
        }
    }
    controller.release.set(engine.io);
    for (&futures) |*future| try future.await(engine.io);
    return error.FaultPointNotReached;
}

pub fn verify(engine: *metadata.Engine, scenario: []const u8) !void {
    const allocator = std.heap.smp_allocator;
    const repository = engine.interface();
    const baseline = try repository.get(allocator, .object, "acknowledged");
    defer baseline.deinit(allocator);
    if (!std.mem.eql(u8, baseline.payload, "durable") or baseline.generation != 1)
        return error.ValidationFailed;
    const required: usize = if (std.mem.eql(u8, scenario, "after-sync") or
        std.mem.eql(u8, scenario, "after-group") or std.mem.eql(u8, scenario, "notify-1")) count else 0;
    const maximum: usize = if (std.mem.eql(u8, scenario, "before-group")) 0 else if (std.mem.eql(u8, scenario, "append-1")) 1 else if (std.mem.eql(u8, scenario, "append-2")) 2 else count;
    var recovered: usize = 0;
    var missing_seen = false;
    for (0..count) |index| {
        var first_buffer: [32]u8 = undefined;
        var second_buffer: [32]u8 = undefined;
        var payload_buffer: [32]u8 = undefined;
        const first_key = try std.fmt.bufPrint(&first_buffer, "group/{d}/a", .{index});
        const second_key = try std.fmt.bufPrint(&second_buffer, "group/{d}/b", .{index});
        const expected_payload = try std.fmt.bufPrint(&payload_buffer, "request-{d}", .{index});
        const first = repository.get(allocator, .object, first_key) catch |err| switch (err) {
            error.NotFound => null,
            else => return err,
        };
        defer if (first) |record| record.deinit(allocator);
        const second = repository.get(allocator, .object, second_key) catch |err| switch (err) {
            error.NotFound => null,
            else => return err,
        };
        defer if (second) |record| record.deinit(allocator);
        if ((first == null) != (second == null)) return error.PartialTransaction;
        if (first) |record| {
            if (missing_seen) return error.NonPrefixRecovery;
            if (record.generation != index + 2 or second.?.generation != record.generation or
                record.tombstone or second.?.tombstone or
                !std.mem.eql(u8, record.payload, expected_payload) or
                !std.mem.eql(u8, second.?.payload, expected_payload)) return error.ValidationFailed;
            recovered += 1;
        } else missing_seen = true;
        var name_buffer: [32]u8 = undefined;
        var receipt_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "ACK-{d}", .{index});
        const receipt = engine.root.readFile(engine.io, name, &receipt_buffer) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (receipt) |bytes| {
            if (first == null or try std.fmt.parseInt(u64, bytes, 10) != first.?.generation)
                return error.LostAcknowledgedTransaction;
        } else if (index == 0 and std.mem.eql(u8, scenario, "notify-1")) return error.MissingReceipt;
    }
    if (recovered < required or recovered > maximum) return error.ValidationFailed;
    if (engine.stats().generation != recovered + 1) return error.ValidationFailed;
    _ = try repository.put(allocator, .object, "post-group-recovery", .missing, "ok");
    try engine.checkpoint();
}
