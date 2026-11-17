const std = @import("std");
const metadata = @import("root.zig");
const a = std.testing.allocator;
const io = std.testing.io;

test "96 record cross namespace transaction rejects last conflict and preserves tombstone predicates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try metadata.Engine.openWithOptions(a, io, tmp.dir, .{ .max_records = 96 });
    var opened = true;
    defer if (opened) engine.deinit();
    var keys: [96][32]u8 = undefined;
    var mutations: [96]metadata.Mutation = undefined;
    for (&mutations, &keys, 0..) |*mutation, *buffer, index| {
        mutation.* = .{
            .record_type = @fromBackingInt(@intCast(index % 6 + 1)),
            .key = try std.fmt.bufPrint(buffer, "batch-{d:0>4}", .{index}),
            .expected = .missing,
            .payload = "old",
        };
    }
    const initial = try engine.commit(&mutations);
    for (&mutations, 0..) |*mutation, index| {
        mutation.expected = .{ .exact = initial };
        mutation.tombstone = index % 2 == 0;
        mutation.payload = if (mutation.tombstone) "" else "new";
    }
    mutations[95].expected = .{ .exact = 0 };
    try std.testing.expectError(error.Conflict, engine.commit(&mutations));
    for (mutations) |mutation| {
        const record = try engine.interface().get(a, mutation.record_type, mutation.key);
        defer record.deinit(a);
        try std.testing.expectEqualStrings("old", record.payload);
        try std.testing.expectEqual(initial, record.generation);
    }
    mutations[95].expected = .{ .exact = initial };
    const committed = try engine.commit(&mutations);
    try std.testing.expectError(error.ResourceLimit, engine.interface().put(a, .object, "extra", .missing, "x"));
    try std.testing.expectError(error.Conflict, engine.interface().put(a, mutations[0].record_type, mutations[0].key, .missing, "x"));
    const restored_generation = try engine.interface().put(a, mutations[0].record_type, mutations[0].key, .{ .exact = committed }, "restored");
    try engine.checkpoint();
    engine.deinit();
    opened = false;
    var reopened = try metadata.Engine.open(a, io, tmp.dir);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 96), reopened.stats().records);
    for (mutations, 0..) |mutation, index| {
        const record = try reopened.interface().get(a, mutation.record_type, mutation.key);
        defer record.deinit(a);
        try std.testing.expectEqual(if (index == 0) restored_generation else committed, record.generation);
        try std.testing.expectEqual(index != 0 and mutation.tombstone, record.tombstone);
        try std.testing.expectEqualStrings(if (index == 0) "restored" else mutation.payload, record.payload);
    }
}

fn transfer(runtime: *metadata.Runtime, worker: usize) anyerror!void {
    for (0..256) |_| {
        const started = std.Io.Clock.awake.now(io);
        while (true) {
            if (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 10000) return error.TransactionStalled;
            const records = try runtime.engine.interface().scan(a, .object);
            defer records.deinit(a);
            if (records.records.len != 2) return error.InvalidAccounts;
            var amounts: [2]u64 = undefined;
            for (records.records, &amounts) |record, *amount| {
                if (record.payload.len != 8) return error.InvalidBalance;
                amount.* = std.mem.readInt(u64, record.payload[0..8], .little);
            }
            // scan is one consistent view. Every successful transaction moves
            // one unit atomically; failed CAS must leave both balances intact.
            if (amounts[0] + amounts[1] != 2_000_000) return error.TornTransfer;
            const from = worker % 2;
            amounts[from] -= 1;
            amounts[1 - from] += 1;
            var payloads: [2][8]u8 = undefined;
            var mutations: [2]metadata.Mutation = undefined;
            for (&mutations, &payloads, records.records, amounts) |*mutation, *payload, record, amount| {
                std.mem.writeInt(u64, payload, amount, .little);
                mutation.* = .{ .record_type = .object, .key = record.key, .expected = .{ .exact = record.generation }, .payload = payload };
            }
            _ = runtime.commit(&mutations) catch |err| {
                if (err == error.Conflict) continue;
                return err;
            };
            break;
        }
    }
}

test "eight FIFO clients preserve multi key money invariant through competing CAS and checkpoints" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try metadata.Engine.openWithOptions(a, io, tmp.dir, .{ .segment_bytes = 8192 });
    var opened = true;
    defer if (opened) engine.deinit();
    var initial: [8]u8 = undefined;
    std.mem.writeInt(u64, &initial, 1_000_000, .little);
    _ = try engine.commit(&.{
        .{ .record_type = .object, .key = "account-a", .payload = &initial },
        .{ .record_type = .object, .key = "account-b", .payload = &initial },
    });
    var runtime: metadata.Runtime = .{ .engine = &engine, .options = .{
        .group_delay_us = 0,
        .checkpoint_interval_ms = 5,
        .checkpoint_min_wal_bytes = 8192,
    } };
    try runtime.start();
    var running = true;
    defer if (running) runtime.stop();
    var futures: [8]std.Io.Future(anyerror!void) = undefined;
    var launched: usize = 0;
    defer for (futures[0..launched]) |*future| {
        future.await(io) catch {};
    };
    for (&futures, 0..) |*future, worker| {
        future.* = try io.concurrent(transfer, .{ &runtime, worker });
        launched += 1;
    }
    var first_error: ?anyerror = null;
    for (&futures) |*future| {
        future.await(io) catch |err| {
            if (first_error == null) first_error = err;
        };
    }
    launched = 0;
    if (first_error) |err| return err;
    runtime.stop();
    running = false;
    try std.testing.expectEqual(@as(u64, 2049), engine.stats().generation);
    try engine.checkpoint();
    engine.deinit();
    opened = false;
    var reopened = try metadata.Engine.open(a, io, tmp.dir);
    defer reopened.deinit();
    for ([_][]const u8{ "account-a", "account-b" }) |key| {
        const record = try reopened.interface().get(a, .object, key);
        defer record.deinit(a);
        try std.testing.expectEqual(@as(u64, 1_000_000), std.mem.readInt(u64, record.payload[0..8], .little));
        try std.testing.expectEqual(@as(u64, 2049), record.generation);
    }
}

test "cross namespace transaction remains atomic across short write disk full and sync faults" {
    inline for (.{ .short_write, .disk_full, .sync_failure, .after_sync }) |fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var engine = try metadata.Engine.open(a, io, tmp.dir);
        _ = try engine.interface().put(a, .object, "acknowledged", .missing, "old");
        var mutations: [6]metadata.Mutation = undefined;
        for (&mutations, 1..) |*mutation, namespace| {
            mutation.* = .{ .record_type = @fromBackingInt(@intCast(namespace)), .key = "new", .payload = "atomic" };
        }
        engine.test_fault = fault;
        try std.testing.expectError(error.Unavailable, engine.commit(&mutations));
        try std.testing.expect(engine.stats().recovery_required);
        engine.deinit();
        var reopened = try metadata.Engine.open(a, io, tmp.dir);
        defer reopened.deinit();
        var count: usize = 0;
        for (mutations) |mutation| {
            if (reopened.interface().get(a, mutation.record_type, mutation.key)) |record| {
                defer record.deinit(a);
                try std.testing.expectEqualStrings("atomic", record.payload);
                try std.testing.expectEqual(@as(u64, 2), record.generation);
                count += 1;
            } else |err| try std.testing.expectEqual(error.NotFound, err);
        }
        try std.testing.expect(count == 0 or count == 6);
        if (fault == .after_sync) try std.testing.expectEqual(@as(usize, 6), count);
        const old = try reopened.interface().get(a, .object, "acknowledged");
        defer old.deinit(a);
        try std.testing.expectEqualStrings("old", old.payload);
    }
}
