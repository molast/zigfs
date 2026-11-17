const std = @import("std");
const Engine = @import("engine.zig").Engine;
const GroupItem = @import("engine.zig").GroupItem;
const Runtime = @import("runtime.zig").Runtime;
const port = @import("repository.zig");
const a = std.testing.allocator;
const io = std.testing.io;

fn put(engine: *Engine, key: []const u8) !void {
    _ = try engine.interface().put(a, .object, key, .any, "value");
}

fn checkValue(engine: *Engine, key: []const u8) !void {
    const record = try engine.interface().get(a, .object, key);
    defer record.deinit(a);
    try std.testing.expectEqualStrings("value", record.payload);
}

test "AVL pagination is ordered bounded and consistent across restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    for (0..200) |index| {
        var buffer: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&buffer, "prefix/{d:0>4}", .{199 - index});
        try put(&engine, key);
    }
    try put(&engine, "other");
    var cursor: ?[]u8 = null;
    defer if (cursor) |key| a.free(key);
    var count: usize = 0;
    while (true) {
        const page = try engine.scanPage(a, .object, .{ .prefix = "prefix/", .start_after = cursor, .limit = 7 });
        defer page.deinit(a);
        try std.testing.expect(page.visited <= 7);
        for (page.records) |record| {
            var buffer: [32]u8 = undefined;
            const expected = try std.fmt.bufPrint(&buffer, "prefix/{d:0>4}", .{count});
            try std.testing.expectEqualStrings(expected, record.key);
            count += 1;
        }
        if (cursor) |key| a.free(key);
        cursor = null;
        if (page.next_start_after) |key| cursor = try a.dupe(u8, key) else break;
    }
    try std.testing.expectEqual(@as(usize, 200), count);
    try std.testing.expect(engine.indexes[2].root.?.height <= 9);
    const generation = engine.stats().generation;
    try put(&engine, "new");
    try std.testing.expectError(error.Conflict, engine.scanPage(a, .object, .{ .expected_generation = generation }));
    try engine.checkpoint();
    engine.deinit();
    var reopened = try Engine.open(a, io, tmp.dir);
    defer reopened.deinit();
    const page = try reopened.scanPage(a, .object, .{ .prefix = "prefix/", .start_after = "prefix/0198" });
    defer page.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), page.records.len);
    try std.testing.expectEqualStrings("prefix/0199", page.records[0].key);
    try std.testing.expect(page.next_start_after == null);
}

test "page byte budget and tombstones cannot trigger unbounded scans" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    defer engine.deinit();
    for ([_][]const u8{ "a", "b", "c" }) |key| {
        _ = try engine.interface().tombstone(a, .object, key, .any);
    }
    try put(&engine, "d");
    const empty = try engine.scanPage(a, .object, .{ .limit = 2, .include_tombstones = false });
    defer empty.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), empty.records.len);
    try std.testing.expectEqualStrings("b", empty.next_start_after.?);
    const last = try engine.scanPage(a, .object, .{ .start_after = empty.next_start_after, .limit = 2, .include_tombstones = false });
    defer last.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), last.records.len);
    try std.testing.expectEqualStrings("d", last.records[0].key);
    try std.testing.expectError(error.ResourceLimit, engine.scanPage(a, .object, .{ .prefix = "d", .max_bytes = 1 }));
}

test "group commit shares sync and evaluates conditions in FIFO order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    defer engine.deinit();
    var items = [_]GroupItem{
        .{ .mutations = &.{.{ .record_type = .object, .key = "same", .payload = "first", .expected = .missing }} },
        .{ .mutations = &.{.{ .record_type = .object, .key = "same", .payload = "invalid", .expected = .missing }} },
        .{ .mutations = &.{.{ .record_type = .object, .key = "same", .payload = "last", .expected = .{ .exact = 1 } }} },
    };
    engine.commitGroup(&items);
    try std.testing.expectEqual(@as(u64, 1), try items[0].result);
    try std.testing.expectError(error.Conflict, items[1].result);
    try std.testing.expectEqual(@as(u64, 2), try items[2].result);
    try std.testing.expectEqual(@as(u64, 1), engine.stats().syncs);
    const record = try engine.interface().get(a, .object, "same");
    defer record.deinit(a);
    try std.testing.expectEqualStrings("last", record.payload);
}

test "failed group sync acknowledges no transaction and blocks reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    engine.test_fault = .sync_failure;
    var items = [_]GroupItem{
        .{ .mutations = &.{.{ .record_type = .object, .key = "a", .payload = "value" }} },
        .{ .mutations = &.{.{ .record_type = .object, .key = "b", .payload = "value" }} },
    };
    engine.commitGroup(&items);
    for (items) |item| try std.testing.expectError(error.Unavailable, item.result);
    try std.testing.expectError(error.Unavailable, engine.interface().get(a, .object, "a"));
    engine.deinit();
    // A failed fsync has an uncertain outcome. On this filesystem both complete
    // frames remain readable; the API must not claim that they were rolled back.
    var reopened = try Engine.open(a, io, tmp.dir);
    defer reopened.deinit();
    try checkValue(&reopened, "a");
    try checkValue(&reopened, "b");
}

test "short write disk full and directory sync failure preserve acknowledged data" {
    inline for (.{ .short_write, .disk_full, .directory_sync_failure }) |fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var engine = try Engine.open(a, io, tmp.dir);
        try put(&engine, "acknowledged");
        engine.test_fault = fault;
        if (fault == .directory_sync_failure) {
            try std.testing.expectError(error.Unavailable, engine.checkpoint());
        } else {
            try std.testing.expectError(error.Unavailable, put(&engine, "unconfirmed"));
        }
        engine.deinit();
        var reopened = try Engine.open(a, io, tmp.dir);
        defer reopened.deinit();
        try checkValue(&reopened, "acknowledged");
        try std.testing.expectError(error.NotFound, reopened.interface().get(a, .object, "unconfirmed"));
    }
}

test "segmented WAL recovers then checkpoint reclaims only covered history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.openWithOptions(a, io, tmp.dir, .{ .segment_bytes = 128 });
    for ([_][]const u8{ "a", "b", "c", "d" }) |key| try put(&engine, key);
    try std.testing.expect(engine.stats().rotations >= 3);
    engine.deinit();
    var reopened = try Engine.openWithOptions(a, io, tmp.dir, .{ .segment_bytes = 128 });
    for ([_][]const u8{ "a", "b", "c", "d" }) |key| try checkValue(&reopened, key);
    try reopened.checkpoint();
    try std.testing.expectEqual(@as(u64, 80), reopened.stats().wal_bytes);
    try put(&reopened, "after");
    reopened.deinit();
    var final = try Engine.open(a, io, tmp.dir);
    defer final.deinit();
    try checkValue(&final, "a");
    try checkValue(&final, "after");
}

test "missing WAL segment is corruption rather than a sequence reset" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.openWithOptions(a, io, tmp.dir, .{ .segment_bytes = 128 });
    try put(&engine, "a");
    try put(&engine, "b");
    try put(&engine, "c");
    engine.deinit();
    try tmp.dir.deleteFile(io, "wal-00000000000000000000.segment");
    try std.testing.expectError(error.CorruptRecord, Engine.open(a, io, tmp.dir));
}

test "read only inspection reports torn tail without changing files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    try put(&engine, "acknowledged");
    engine.test_fault = .short_write;
    try std.testing.expectError(error.Unavailable, put(&engine, "unconfirmed"));
    engine.deinit();
    const file = try tmp.dir.openFile(io, "wal", .{});
    defer file.close(io);
    const size = (try file.stat(io)).size;
    var inspected = try Engine.openWithOptions(a, io, tmp.dir, .{ .read_only = true });
    try std.testing.expect(inspected.stats().incomplete_tail_bytes > 0);
    try std.testing.expectError(error.ReadOnly, put(&inspected, "forbidden"));
    try std.testing.expectError(error.ReadOnly, inspected.checkpoint());
    inspected.deinit();
    try std.testing.expectEqual(size, (try file.stat(io)).size);
    var repaired = try Engine.open(a, io, tmp.dir);
    defer repaired.deinit();
    try std.testing.expect((try file.stat(io)).size < size);
    try checkValue(&repaired, "acknowledged");
}

test "resource limits reject before WAL append and still permit overwrites" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.openWithOptions(a, io, tmp.dir, .{ .max_records = 1, .max_live_bytes = 8 });
    defer engine.deinit();
    try put(&engine, "a");
    const before = engine.stats();
    try std.testing.expectError(error.ResourceLimit, put(&engine, "b"));
    try std.testing.expectEqual(before.wal_bytes, engine.stats().wal_bytes);
    try put(&engine, "a");
    try std.testing.expect(!engine.stats().recovery_required);
}

const SnapshotBarrier = struct {
    captured: std.Io.Event = .unset,
    continue_event: std.Io.Event = .unset,

    fn hook(context: *anyopaque, point: @import("engine.zig").Point) void {
        const self: *SnapshotBarrier = @ptrCast(@alignCast(context));
        if (point != .checkpoint_captured) return;
        self.captured.set(io);
        self.continue_event.waitUncancelable(io);
    }
};

fn checkpointWorker(engine: *Engine) anyerror!void {
    try engine.checkpoint();
}

test "snapshot written outside state lock retains concurrent writes after reclamation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.openWithOptions(a, io, tmp.dir, .{ .segment_bytes = 128 });
    try put(&engine, "before");
    var barrier: SnapshotBarrier = .{};
    engine.hook = .{ .context = &barrier, .call = SnapshotBarrier.hook };
    var future = try io.concurrent(checkpointWorker, .{&engine});
    barrier.captured.waitUncancelable(io);
    const result = put(&engine, "during");
    const second_result = put(&engine, "also-during");
    barrier.continue_event.set(io);
    try future.await(io);
    try result;
    try second_result;
    engine.deinit();
    var reopened = try Engine.open(a, io, tmp.dir);
    defer reopened.deinit();
    for ([_][]const u8{ "before", "during", "also-during" }) |key| try checkValue(&reopened, key);
}

fn runtimeWriter(runtime: *Runtime, id: usize) anyerror!void {
    var key_buffer: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buffer, "worker-{d}", .{id});
    _ = try runtime.interface().put(a, .object, key, .missing, "value");
}

test "runtime batches concurrent requests drains on stop and schedules checkpoints" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    defer engine.deinit();
    var runtime: Runtime = .{
        .engine = &engine,
        .options = .{ .group_delay_us = 5000, .checkpoint_interval_ms = 5, .checkpoint_min_wal_bytes = 81 },
    };
    try runtime.start();
    defer runtime.stop();
    var futures: [8]std.Io.Future(anyerror!void) = undefined;
    var started: usize = 0;
    defer for (futures[0..started]) |*future| {
        future.await(io) catch {};
    };
    for (&futures, 0..) |*future, id| {
        future.* = try io.concurrent(runtimeWriter, .{ &runtime, id });
        started += 1;
    }
    for (&futures) |*future| try future.await(io);
    started = 0;
    // Finite deadline: fail rather than hang if maintenance cannot make progress.
    const start = std.Io.Clock.awake.now(io);
    while (engine.stats().checkpoint_generation != engine.stats().generation) {
        if (start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 5000) return error.MaintenanceTimeout;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    runtime.stop();
    try std.testing.expectEqual(@as(u64, 8), runtime.stats().transactions);
    try std.testing.expect(engine.stats().syncs < 8);
    try std.testing.expectError(error.Unavailable, runtimeWriter(&runtime, 9));
    try std.testing.expectEqual(@as(usize, 8), engine.stats().records);
}

const WriterBarrier = struct {
    arrived: std.Io.Event = .unset,
    released: std.Io.Event = .unset,

    fn hook(context: *anyopaque, point: @import("engine.zig").Point) void {
        const self: *WriterBarrier = @ptrCast(@alignCast(context));
        if (point != .after_append) return;
        self.arrived.set(io);
        self.released.waitUncancelable(io);
    }
};

fn stopWorker(runtime: *Runtime) void {
    runtime.stop();
}

test "bounded FIFO queue rejects excess requests and shutdown drains accepted requests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    defer engine.deinit();
    var barrier: WriterBarrier = .{};
    engine.hook = .{ .context = &barrier, .call = WriterBarrier.hook };
    var runtime: Runtime = .{ .engine = &engine, .options = .{
        .max_pending = 2,
        .group_delay_us = 0,
        .checkpoint_interval_ms = 0,
    } };
    try runtime.start();
    defer runtime.stop();
    var first = try io.concurrent(runtimeWriter, .{ &runtime, 0 });
    barrier.arrived.waitUncancelable(io);
    var second = io.concurrent(runtimeWriter, .{ &runtime, 1 }) catch |err| {
        barrier.released.set(io);
        try first.await(io);
        return err;
    };
    while (runtime.stats().queued != 1) try io.sleep(.fromMilliseconds(1), .awake);
    const rejection = runtimeWriter(&runtime, 2);
    var stopped = io.concurrent(stopWorker, .{&runtime}) catch |err| {
        barrier.released.set(io);
        try first.await(io);
        try second.await(io);
        return err;
    };
    barrier.released.set(io);
    const first_result = first.await(io);
    const second_result = second.await(io);
    stopped.await(io);
    try first_result;
    try second_result;
    try std.testing.expectError(error.Busy, rejection);
    try std.testing.expectEqual(@as(usize, 2), engine.stats().records);
    const record0 = try engine.interface().get(a, .object, "worker-0");
    defer record0.deinit(a);
    const record1 = try engine.interface().get(a, .object, "worker-1");
    defer record1.deinit(a);
    try std.testing.expect(record0.generation < record1.generation);
}

test "WAL quota leaves enough space to checkpoint and resume writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.openWithOptions(a, io, tmp.dir, .{
        .segment_bytes = 256,
        .max_wal_bytes = 512,
    });
    defer engine.deinit();
    try put(&engine, "a");
    try put(&engine, "b");
    try std.testing.expectError(error.ResourceLimit, put(&engine, "c"));
    try std.testing.expect(!engine.stats().recovery_required);
    try engine.checkpoint();
    try put(&engine, "c");
}

test "old database headers are rejected without modifying files" {
    for ([_]u16{ 1, 2 }) |version| {
        for ([_][]const u8{ "wal", "snapshot" }) |name| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var engine = try Engine.open(a, io, tmp.dir);
            try put(&engine, "old");
            try engine.checkpoint();
            engine.deinit();
            const file = try tmp.dir.openFile(io, name, .{ .mode = .read_write });
            defer file.close(io);
            const size = (try file.stat(io)).size;
            var header: [80]u8 = undefined;
            try std.testing.expectEqual(@as(usize, 80), try file.readPositionalAll(io, &header, 0));
            std.mem.writeInt(u16, header[8..10], version, .little);
            std.crypto.hash.sha2.Sha256.hash(header[0..48], header[48..80], .{});
            try file.writePositionalAll(io, &header, 0);
            try std.testing.expectError(error.UnsupportedFormat, Engine.open(a, io, tmp.dir));
            var after: [80]u8 = undefined;
            try std.testing.expectEqual(@as(usize, 80), try file.readPositionalAll(io, &after, 0));
            try std.testing.expectEqualSlices(u8, &header, &after);
            try std.testing.expectEqual(size, (try file.stat(io)).size);
        }
    }
}

fn pageAllocationScenario(allocator: std.mem.Allocator, engine: *Engine) !void {
    const page = try engine.scanPage(allocator, .object, .{ .limit = 1 });
    defer page.deinit(allocator);
}

test "page allocation failures release records and continuation token" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    defer engine.deinit();
    try put(&engine, "a");
    try put(&engine, "b");
    try std.testing.checkAllAllocationFailures(a, pageAllocationScenario, .{&engine});
}

test "startup reclaims reserved atomic temporaries only after validation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    try put(&engine, "data");
    engine.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = "0123456789abcdef", .data = "orphan" });
    try tmp.dir.writeFile(io, .{ .sub_path = "operator-note", .data = "keep" });
    var inspected = try Engine.openWithOptions(a, io, tmp.dir, .{ .read_only = true });
    inspected.deinit();
    const temporary = try tmp.dir.openFile(io, "0123456789abcdef", .{});
    temporary.close(io);
    var reopened = try Engine.open(a, io, tmp.dir);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 1), reopened.stats().orphan_temporaries_removed);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "0123456789abcdef", .{}));
    const note = try tmp.dir.openFile(io, "operator-note", .{});
    note.close(io);
    try checkValue(&reopened, "data");
}

fn putWithMaintenance(runtime: *Runtime, key: []const u8, payload: []const u8) !u64 {
    const started = std.Io.Clock.awake.now(io);
    while (true) {
        return runtime.interface().put(a, .object, key, .any, payload) catch |err| {
            if (err != error.ResourceLimit) return err;
            if (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 5000)
                return error.MaintenanceTimeout;
            try io.sleep(.fromMilliseconds(2), .awake);
            continue;
        };
    }
}

test "automatic maintenance clamps unreachable threshold and restores small quota writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.openWithOptions(a, io, tmp.dir, .{
        .segment_bytes = 128,
        .max_wal_bytes = 512,
    });
    defer engine.deinit();
    var runtime: Runtime = .{ .engine = &engine, .options = .{ .checkpoint_interval_ms = 5, .group_delay_us = 0 } };
    try runtime.start();
    defer runtime.stop();
    try std.testing.expectEqual(@as(u64, 256), runtime.stats().effective_checkpoint_wal_bytes);
    for (0..20) |_| _ = try putWithMaintenance(&runtime, "same", "value");
    runtime.stop();
    try std.testing.expect(engine.stats().checkpoints > 0);
    try checkValue(&engine, "same");
}

test "quota pressure triggers maintenance below effective threshold" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.openWithOptions(a, io, tmp.dir, .{
        .segment_bytes = 512,
        .max_wal_bytes = 512,
    });
    defer engine.deinit();
    try put(&engine, "a");
    const payload = @as([187]u8, @splat('x'));
    try std.testing.expectError(error.ResourceLimit, engine.interface().put(a, .object, "large", .any, &payload));
    try std.testing.expect(engine.stats().wal_bytes < 256);
    try std.testing.expect(engine.stats().wal_pressure);
    var runtime: Runtime = .{ .engine = &engine, .options = .{ .checkpoint_interval_ms = 5, .group_delay_us = 0 } };
    try runtime.start();
    defer runtime.stop();
    _ = try putWithMaintenance(&runtime, "large", &payload);
    const record = try engine.interface().get(a, .object, "large");
    defer record.deinit(a);
    try std.testing.expectEqualStrings(&payload, record.payload);
}

test "maintenance rejects unusable quota but preserves explicitly manual mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.openWithOptions(a, io, tmp.dir, .{
        .segment_bytes = 128,
        .max_wal_bytes = 128,
    });
    defer engine.deinit();
    var automatic: Runtime = .{ .engine = &engine };
    try std.testing.expectError(error.InvalidOptions, automatic.start());
    var manual: Runtime = .{ .engine = &engine, .options = .{ .checkpoint_interval_ms = 0 } };
    try manual.start();
    defer manual.stop();
    try std.testing.expectEqual(@as(u64, 0), manual.stats().effective_checkpoint_wal_bytes);
    try std.testing.expectError(error.ResourceLimit, manual.interface().put(a, .object, "a", .any, "value"));
}

test "cleanup failures retry without new generation or another snapshot" {
    inline for (.{ .delete, .sync }) |kind| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var engine = try Engine.open(a, io, tmp.dir);
        defer engine.deinit();
        try put(&engine, "retained");
        engine.test_cleanup_failure = .{ .kind = kind, .remaining = 2 };
        try std.testing.expectError(error.Unavailable, engine.checkpoint());
        const before = engine.stats();
        try std.testing.expect(before.cleanup_pending);
        try std.testing.expectEqual(before.generation, before.checkpoint_generation);
        try std.testing.expect(!before.recovery_required);
        var runtime: Runtime = .{ .engine = &engine, .options = .{ .checkpoint_interval_ms = 5 } };
        try runtime.start();
        defer runtime.stop();
        const started = std.Io.Clock.awake.now(io);
        while (engine.stats().cleanup_pending or runtime.stats().last_checkpoint_error != null) {
            if (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 5000)
                return error.MaintenanceTimeout;
            try io.sleep(.fromMilliseconds(2), .awake);
        }
        runtime.stop();
        const after = engine.stats();
        try std.testing.expectEqual(before.generation, after.generation);
        try std.testing.expectEqual(before.checkpoints, after.checkpoints);
        try std.testing.expectEqual(@as(u64, 2), after.cleanup_retries);
        try std.testing.expectEqual(@as(u64, 1), runtime.stats().checkpoint_failures);
        try std.testing.expectEqual(@as(u64, 80), after.wal_bytes);
        try checkValue(&engine, "retained");
    }
}

test "cleanup retry retains segments written after the snapshot boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.openWithOptions(a, io, tmp.dir, .{ .segment_bytes = 128 });
    try put(&engine, "before");
    engine.test_cleanup_failure = .{ .kind = .delete, .remaining = 1 };
    var barrier: SnapshotBarrier = .{};
    engine.hook = .{ .context = &barrier, .call = SnapshotBarrier.hook };
    var future = try io.concurrent(checkpointWorker, .{&engine});
    barrier.captured.waitUncancelable(io);
    const first = put(&engine, "during");
    const second = put(&engine, "after-rotation");
    barrier.continue_event.set(io);
    const checkpoint_result = future.await(io);
    try first;
    try second;
    try std.testing.expectError(error.Unavailable, checkpoint_result);
    try std.testing.expect(engine.stats().cleanup_pending);
    try engine.retryCleanup();
    try std.testing.expect(!engine.stats().cleanup_pending);
    try std.testing.expect(engine.stats().wal_bytes > engine.stats().active_wal_bytes);
    engine.deinit();
    var reopened = try Engine.open(a, io, tmp.dir);
    defer reopened.deinit();
    for ([_][]const u8{ "before", "during", "after-rotation" }) |key| try checkValue(&reopened, key);
}

test "snapshot buffering preserves large frames and mixed namespace records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    var opened = true;
    defer if (opened) engine.deinit();
    // Exercise a frame larger than the write buffer, a partial trailing buffer,
    // and empty tombstone payloads in the snapshot copy.
    const payload = try a.alloc(u8, 96 * 1024);
    defer a.free(payload);
    for (payload, 0..) |*byte, index| byte.* = @intCast(index % 251);
    const large_generation = try engine.interface().put(a, .object, "large", .missing, payload);
    const small_generation = try engine.interface().put(a, .bucket, "small", .missing, "tail");
    const deleted_generation = try engine.interface().tombstone(a, .credential, "deleted", .missing);
    try engine.checkpoint();
    engine.deinit();
    opened = false;
    engine = try Engine.open(a, io, tmp.dir);
    opened = true;
    const large = try engine.interface().get(a, .object, "large");
    defer large.deinit(a);
    try std.testing.expectEqualSlices(u8, payload, large.payload);
    try std.testing.expectEqual(large_generation, large.generation);
    const small = try engine.interface().get(a, .bucket, "small");
    defer small.deinit(a);
    try std.testing.expectEqualStrings("tail", small.payload);
    try std.testing.expectEqual(small_generation, small.generation);
    const deleted = try engine.interface().get(a, .credential, "deleted");
    defer deleted.deinit(a);
    try std.testing.expect(deleted.tombstone);
    try std.testing.expectEqual(@as(usize, 0), deleted.payload.len);
    try std.testing.expectEqual(deleted_generation, deleted.generation);
}

test "ordered iterator seeks gaps inclusively and exclusively after randomized inserts" {
    const ordered = @import("ordered_index.zig");
    var index: ordered.Index = .{};
    var keys: [512][16]u8 = undefined;
    defer index.deinit(a);
    var order: [512]usize = undefined;
    for (&order, 0..) |*value, position| value.* = position;
    var random = std.Random.DefaultPrng.init(20261117);
    random.random().shuffle(usize, &order);
    for (order) |position| {
        const node = try a.create(ordered.Node);
        node.* = .{ .key = try std.fmt.bufPrint(&keys[position], "key-{d:0>6}", .{position * 2}) };
        index.upsert(a, node);
    }
    for (0..1026) |seek| {
        var buffer: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&buffer, "key-{d:0>6}", .{seek});
        for ([_]bool{ false, true }) |exclusive| {
            var iterator = index.iterator(key, exclusive);
            var expected = if (exclusive) seek / 2 + 1 else (seek + 1) / 2;
            while (iterator.next()) |actual| : (expected += 1) {
                try std.testing.expect(expected < keys.len);
                var expected_buffer: [16]u8 = undefined;
                const expected_key = try std.fmt.bufPrint(&expected_buffer, "key-{d:0>6}", .{expected * 2});
                try std.testing.expectEqualStrings(expected_key, actual);
            }
            try std.testing.expectEqual(@max(@as(usize, 512), if (exclusive) seek / 2 + 1 else (seek + 1) / 2), expected);
            try std.testing.expect(iterator.next() == null);
        }
    }
}

test "overwrite reuses stable key and node while returned records remain owned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    defer engine.deinit();
    try put(&engine, "stable");
    const node = engine.maps[2].get("stable").?;
    const key = node.key.ptr;
    const copy = try engine.interface().get(a, .object, "stable");
    defer copy.deinit(a);
    _ = try engine.interface().tombstone(a, .object, "stable", .any);
    try put(&engine, "stable");
    try std.testing.expect(node == engine.maps[2].get("stable").?);
    try std.testing.expect(key == node.key.ptr);
    try std.testing.expectEqualStrings("value", copy.payload);
    try std.testing.expectError(error.InvalidKey, engine.commit(&.{
        .{ .record_type = .object, .key = "stable", .payload = "invalid" },
        .{ .record_type = .object, .key = "stable", .expected = .missing },
    }));
}

fn mixedPrepareFailure(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    defer engine.deinit();
    try put(&engine, "old");
    const before = engine.stats();
    // The failing allocator forwards to the same backing allocator. Restore it
    // before teardown so each failure also checks that old ownership survived.
    engine.allocator = allocator;
    const result = engine.commit(&.{
        .{ .record_type = .object, .key = "old", .payload = "updated" },
        .{ .record_type = .object, .key = "new", .payload = "inserted" },
    });
    engine.allocator = a;
    _ = result catch |err| {
        try checkValue(&engine, "old");
        try std.testing.expect(!engine.maps[2].contains("new"));
        try std.testing.expectEqual(before.generation, engine.stats().generation);
        try std.testing.expectEqual(before.wal_bytes, engine.stats().wal_bytes);
        return err;
    };
}

test "all mixed insert overwrite allocation failures preserve pretransaction state" {
    try std.testing.checkAllAllocationFailures(a, mixedPrepareFailure, .{});
}

fn snapshotOpenFailure(allocator: std.mem.Allocator, root: std.Io.Dir) !void {
    var engine = try Engine.open(allocator, io, root);
    defer engine.deinit();
    try std.testing.expectEqual(@as(usize, 3), engine.stats().records);
}

test "snapshot preflight bulk load and tree construction release partial ownership" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    _ = try engine.commit(&.{
        .{ .record_type = .object, .key = "z", .payload = "z" },
        .{ .record_type = .object, .key = "a", .payload = "a" },
        .{ .record_type = .bucket, .key = "b", .payload = "b" },
    });
    try engine.checkpoint();
    engine.deinit();
    try std.testing.checkAllAllocationFailures(a, snapshotOpenFailure, .{tmp.dir});
    try std.testing.expectError(error.ResourceLimit, Engine.openWithOptions(a, io, tmp.dir, .{ .max_records = 2 }));
    try std.testing.expectError(error.ResourceLimit, Engine.openWithOptions(a, io, tmp.dir, .{ .max_live_bytes = 1 }));
}

test "buffered WAL recovery crosses small and large frames and repairs partial tail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    const payload = try a.alloc(u8, 96 * 1024);
    defer a.free(payload);
    @memset(payload, 71);
    for (0..4) |index| {
        var key_buffer: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, "key-{d}", .{index});
        _ = try engine.interface().put(a, .object, key, .any, if (index % 2 == 0) payload[0..40000] else payload);
    }
    const length = engine.wal_length;
    try engine.wal.writePositionalAll(io, "partial-header", length);
    engine.deinit();
    var reopened = try Engine.open(a, io, tmp.dir);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 4), reopened.stats().records);
    try std.testing.expectEqual(length, (try reopened.wal.stat(io)).size);
    for (0..4) |index| {
        var key_buffer: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, "key-{d}", .{index});
        const record = try reopened.interface().get(a, .object, key);
        defer record.deinit(a);
        try std.testing.expectEqualSlices(u8, if (index % 2 == 0) payload[0..40000] else payload, record.payload);
    }
}

test "v3 snapshot rejects unordered keys and duplicates" {
    const codec = @import("codec.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    for ([_][]const u8{ "c", "a", "b" }) |key| try put(&engine, key);
    try engine.checkpoint();
    engine.deinit();
    const snapshot = try tmp.dir.openFile(io, "snapshot", .{ .mode = .read_write });
    defer snapshot.close(io);
    const bytes = try a.alloc(u8, @intCast((try snapshot.stat(io)).size));
    defer a.free(bytes);
    try std.testing.expectEqual(bytes.len, try snapshot.readPositionalAll(io, bytes, 0));
    const frame_size = (try codec.decodeHeader(bytes[80..][0..64])).length;
    try std.testing.expectEqual(@as(usize, 80 + 3 * frame_size), bytes.len);
    // Reordering preserves each frame checksum but violates v3 key order.
    try snapshot.writePositionalAll(io, bytes[80 + 2 * frame_size ..], 80);
    try snapshot.writePositionalAll(io, bytes[80..][0..frame_size], 80 + 2 * frame_size);
    try std.testing.expectError(error.CorruptRecord, Engine.open(a, io, tmp.dir));
    try snapshot.writePositionalAll(io, bytes, 0);
    try snapshot.writePositionalAll(io, bytes[80..][0..frame_size], 80 + frame_size);
    try std.testing.expectError(error.CorruptRecord, Engine.open(a, io, tmp.dir));
}

test "linked WAL archive is sealed and active writes use a different inode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.openWithOptions(a, io, tmp.dir, .{ .segment_bytes = 128 });
    defer engine.deinit();
    try put(&engine, "first");
    const original_inode = (try engine.wal.stat(io)).inode;
    const sealed_size = engine.wal_length;
    try put(&engine, "second");
    const archive = try tmp.dir.openFile(io, "wal-00000000000000000000.segment", .{});
    defer archive.close(io);
    const archive_stat = try archive.stat(io);
    try std.testing.expectEqual(original_inode, archive_stat.inode);
    try std.testing.expect(original_inode != (try engine.wal.stat(io)).inode);
    try std.testing.expectEqual(sealed_size, archive_stat.size);
    try put(&engine, "third");
    try std.testing.expectEqual(sealed_size, (try archive.stat(io)).size);
    try std.testing.expectEqual(@as(u64, 0), engine.stats().rotation_copy_bytes);
    try std.testing.expectEqual(@as(u64, 2), engine.stats().linked_rotations);
}

test "unsupported hard links retain durable copy rotation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.openWithOptions(a, io, tmp.dir, .{ .segment_bytes = 128 });
    try put(&engine, "first");
    const length = engine.wal_length;
    engine.test_fault = .link_unsupported;
    try put(&engine, "second");
    try std.testing.expectEqual(length, engine.stats().rotation_copy_bytes);
    try std.testing.expectEqual(@as(u64, 0), engine.stats().linked_rotations);
    engine.deinit();
    var reopened = try Engine.open(a, io, tmp.dir);
    defer reopened.deinit();
    try checkValue(&reopened, "first");
    try checkValue(&reopened, "second");
}

test "archive failure freezes instance and acknowledged records recover" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.openWithOptions(a, io, tmp.dir, .{ .segment_bytes = 128 });
    try put(&engine, "acknowledged");
    engine.test_fault = .archive_link_failure;
    try std.testing.expectError(error.Unavailable, put(&engine, "new"));
    try std.testing.expect(engine.stats().recovery_required);
    try std.testing.expectError(error.Unavailable, put(&engine, "also-new"));
    engine.deinit();
    var reopened = try Engine.open(a, io, tmp.dir);
    defer reopened.deinit();
    try checkValue(&reopened, "acknowledged");
    try std.testing.expect(!reopened.maps[2].contains("new"));
}

test "snapshot capture only clears dirty volume covered by its boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    defer engine.deinit();
    try put(&engine, "before");
    const captured = engine.stats().dirty_bytes;
    var barrier: SnapshotBarrier = .{};
    engine.hook = .{ .context = &barrier, .call = SnapshotBarrier.hook };
    var future = try io.concurrent(checkpointWorker, .{&engine});
    barrier.captured.waitUncancelable(io);
    const result = put(&engine, "during");
    const dirty = engine.stats().dirty_bytes;
    barrier.continue_event.set(io);
    try future.await(io);
    try result;
    try std.testing.expectEqual(dirty - captured, engine.stats().dirty_bytes);
    engine.hook = null;
    try engine.checkpoint();
    try std.testing.expectEqual(@as(u64, 0), engine.stats().dirty_bytes);
}

test "optional stage diagnostics count commit and checkpoint operations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.openWithOptions(a, io, tmp.dir, .{ .diagnostics = true });
    defer engine.deinit();
    try put(&engine, "timed");
    try engine.checkpoint();
    const phases = engine.stats().phases;
    try std.testing.expectEqual(@as(u64, 1), phases.wal_append.count);
    try std.testing.expectEqual(@as(u64, 1), phases.wal_sync.count);
    try std.testing.expectEqual(@as(u64, 1), phases.rotation.count);
    try std.testing.expectEqual(@as(u64, 1), phases.snapshot_capture.count);
    try std.testing.expectEqual(@as(u64, 1), phases.snapshot_install.count);
    try std.testing.expect(phases.lock_hold.count >= 2);
    try std.testing.expect(phases.lock_hold.total_ns >= phases.lock_hold.max_ns);
}

const CleanupBarrier = struct {
    started: std.Io.Event = .unset,
    released: std.Io.Event = .unset,

    fn hook(context: *anyopaque, point: @import("engine.zig").Point) void {
        const self: *CleanupBarrier = @ptrCast(@alignCast(context));
        if (point != .cleanup_started) return;
        self.started.set(io);
        self.released.waitUncancelable(io);
    }
};

test "unlocked cleanup preserves concurrently rotated WAL and quota accounting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.openWithOptions(a, io, tmp.dir, .{ .segment_bytes = 128 });
    try put(&engine, "before");
    var barrier: CleanupBarrier = .{};
    engine.hook = .{ .context = &barrier, .call = CleanupBarrier.hook };
    var checkpoint = try io.concurrent(checkpointWorker, .{&engine});
    barrier.started.waitUncancelable(io);
    const first = put(&engine, "during-cleanup");
    const second = put(&engine, "after-rotation");
    barrier.released.set(io);
    try checkpoint.await(io);
    try first;
    try second;
    const files = try @import("segments.zig").list(a, io, tmp.dir);
    defer a.free(files);
    var bytes = (try engine.wal.stat(io)).size;
    for (files) |file| bytes += file.size;
    try std.testing.expectEqual(bytes, engine.stats().wal_bytes);
    try std.testing.expect(bytes > engine.wal_length);
    engine.deinit();
    var reopened = try Engine.open(a, io, tmp.dir);
    defer reopened.deinit();
    for ([_][]const u8{ "before", "during-cleanup", "after-rotation" }) |key| try checkValue(&reopened, key);
}

test "checkpoint rechecks frozen state after unlocked cleanup retry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    defer engine.deinit();
    try put(&engine, "old");
    engine.test_cleanup_failure = .{ .kind = .delete, .remaining = 1 };
    try std.testing.expectError(error.Unavailable, engine.checkpoint());
    var barrier: CleanupBarrier = .{};
    engine.hook = .{ .context = &barrier, .call = CleanupBarrier.hook };
    engine.test_fault = .sync_failure;
    var checkpoint = try io.concurrent(checkpointWorker, .{&engine});
    barrier.started.waitUncancelable(io);
    const write = put(&engine, "uncertain");
    barrier.released.set(io);
    const result = checkpoint.await(io);
    try std.testing.expectError(error.Unavailable, write);
    try std.testing.expectError(error.Unavailable, result);
    try std.testing.expect(engine.stats().recovery_required);
}

test "pinned checkpoint preserves old values across overwrite tombstone and resurrection" {
    const codec = @import("codec.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    var opened = true;
    defer if (opened) engine.deinit();
    const payload = try a.alloc(u8, 96 * 1024);
    defer a.free(payload);
    @memset(payload, 73);
    const old_generation = try engine.interface().put(a, .object, "changed", .missing, payload);
    try put(&engine, "untouched");
    const deleted_generation = try engine.interface().tombstone(a, .credential, "deleted", .missing);
    const untouched = engine.maps[2].get("untouched").?;
    const untouched_payload = untouched.payload.ptr;
    var barrier: SnapshotBarrier = .{};
    engine.hook = .{ .context = &barrier, .call = SnapshotBarrier.hook };
    var checkpoint = try io.concurrent(checkpointWorker, .{&engine});
    barrier.captured.waitUncancelable(io);
    const overwritten = engine.commit(&.{
        .{ .record_type = .object, .key = "changed", .payload = "intermediate" },
        .{ .record_type = .credential, .key = "deleted", .payload = "resurrected" },
    });
    const deleted = engine.interface().tombstone(a, .object, "changed", .any);
    const revived = engine.interface().put(a, .object, "changed", .any, "latest");
    barrier.continue_event.set(io);
    try checkpoint.await(io);
    _ = try overwritten;
    _ = try deleted;
    const latest_generation = try revived;
    try std.testing.expect(!untouched.snapshot_pinned.load(.acquire));
    try std.testing.expect(untouched.payload.ptr == untouched_payload);
    const file = try tmp.dir.openFile(io, "snapshot", .{});
    defer file.close(io);
    const bytes = try a.alloc(u8, @intCast((try file.stat(io)).size));
    defer a.free(bytes);
    try std.testing.expectEqual(bytes.len, try file.readPositionalAll(io, bytes, 0));
    var offset: usize = 80;
    var count: usize = 0;
    while (offset < bytes.len) {
        const header = try codec.decodeHeader(bytes[offset..][0..64]);
        const entries = try codec.decode(a, bytes[offset..][0..header.length]);
        defer codec.freeEntries(a, entries);
        const record = entries[0].record;
        if (std.mem.eql(u8, record.key, "changed")) {
            try std.testing.expectEqualSlices(u8, payload, record.payload);
            try std.testing.expectEqual(old_generation, record.generation);
        } else if (std.mem.eql(u8, record.key, "deleted")) {
            try std.testing.expect(record.tombstone);
            try std.testing.expectEqual(deleted_generation, record.generation);
        } else {
            try std.testing.expectEqualStrings("untouched", record.key);
            try std.testing.expectEqualStrings("value", record.payload);
        }
        offset += header.length;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
    engine.deinit();
    opened = false;
    var reopened = try Engine.open(a, io, tmp.dir);
    defer reopened.deinit();
    const latest = try reopened.interface().get(a, .object, "changed");
    defer latest.deinit(a);
    try std.testing.expectEqualStrings("latest", latest.payload);
    try std.testing.expectEqual(latest_generation, latest.generation);
}

const PinAllocationFailure = struct {
    engine: *Engine,
    allocator: *std.testing.FailingAllocator,
    mutation_error: ?anyerror = null,

    fn hook(context: *anyopaque, point: @import("engine.zig").Point) void {
        const self: *PinAllocationFailure = @ptrCast(@alignCast(context));
        if (point != .checkpoint_captured) return;
        _ = self.engine.interface().put(a, .object, "pinned", .any, "new") catch |err| {
            self.mutation_error = err;
            return;
        };
        // Same-thread injection after ownership transfers to the view. Fail the
        // next frame allocation, then verify its deferred old payload is freed.
        self.allocator.fail_index = self.allocator.alloc_index;
    }
};

test "snapshot encoding OOM releases retired payload and keeps current version usable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var failing = std.testing.FailingAllocator.init(a, .{});
    var engine = try Engine.open(failing.allocator(), io, tmp.dir);
    try put(&engine, "pinned");
    var fault: PinAllocationFailure = .{ .engine = &engine, .allocator = &failing };
    engine.hook = .{ .context = &fault, .call = PinAllocationFailure.hook };
    const result = engine.checkpoint();
    failing.fail_index = std.math.maxInt(usize);
    engine.hook = null;
    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expect(fault.mutation_error == null);
    try std.testing.expect(!engine.stats().recovery_required);
    try std.testing.expect(!engine.maps[2].get("pinned").?.snapshot_pinned.load(.acquire));
    const current = try engine.interface().get(a, .object, "pinned");
    defer current.deinit(a);
    try std.testing.expectEqualStrings("new", current.payload);
    try engine.checkpoint();
    engine.deinit();
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "failed concurrent sync releases pinned view without publishing a snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    defer engine.deinit();
    try put(&engine, "pinned");
    var barrier: SnapshotBarrier = .{};
    engine.hook = .{ .context = &barrier, .call = SnapshotBarrier.hook };
    engine.test_fault = .sync_failure;
    var checkpoint = try io.concurrent(checkpointWorker, .{&engine});
    barrier.captured.waitUncancelable(io);
    const write = put(&engine, "pinned");
    barrier.continue_event.set(io);
    try std.testing.expectError(error.Unavailable, checkpoint.await(io));
    try std.testing.expectError(error.Unavailable, write);
    try std.testing.expect(!engine.maps[2].get("pinned").?.snapshot_pinned.load(.acquire));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "snapshot", .{}));
}

test "snapshot pin uses existing node padding on 64 bit targets" {
    if (@sizeOf(usize) == 8) try std.testing.expectEqual(@as(usize, 64), @sizeOf(@import("ordered_index.zig").Node));
}

fn pinRaceWriter(engine: *Engine, stopped: *std.atomic.Value(bool)) anyerror!void {
    var sequence: usize = 0;
    while (!stopped.load(.acquire)) : (sequence += 1) {
        var buffer: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&buffer, "race-{d}", .{sequence % 64});
        _ = try engine.interface().put(a, .object, key, .any, if (sequence % 2 == 0) "short" else "longer-current-value");
    }
}

test "repeated snapshot release races with overwrites without leaking or changing recovery" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    var opened = true;
    defer if (opened) engine.deinit();
    for (0..64) |index| {
        var buffer: [32]u8 = undefined;
        try put(&engine, try std.fmt.bufPrint(&buffer, "race-{d}", .{index}));
    }
    var stopped: std.atomic.Value(bool) = .init(false);
    var writer = try io.concurrent(pinRaceWriter, .{ &engine, &stopped });
    var joined = false;
    defer if (!joined) {
        stopped.store(true, .release);
        writer.await(io) catch {};
    };
    for (0..32) |_| try engine.checkpoint();
    stopped.store(true, .release);
    try writer.await(io);
    joined = true;
    var nodes = engine.maps[2].valueIterator();
    while (nodes.next()) |node| try std.testing.expect(!node.*.snapshot_pinned.load(.acquire));
    const expected = try engine.interface().scan(a, .object);
    defer expected.deinit(a);
    engine.deinit();
    opened = false;
    var reopened = try Engine.open(a, io, tmp.dir);
    defer reopened.deinit();
    for (expected.records) |record| {
        const actual = try reopened.interface().get(a, .object, record.key);
        defer actual.deinit(a);
        try std.testing.expectEqualSlices(u8, record.payload, actual.payload);
        try std.testing.expectEqual(record.generation, actual.generation);
    }
}
