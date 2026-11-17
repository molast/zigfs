const std = @import("std");
const metadata = @import("root.zig");
const a = std.testing.allocator;
const io = std.testing.io;

test "GC shrinks records and persists absence fence across checkpoint backup and reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var destination = std.testing.tmpDir(.{});
    defer destination.cleanup();
    var engine = try metadata.Engine.openWithOptions(a, io, tmp.dir, .{ .max_records = 2 });
    var opened = true;
    defer if (opened) engine.deinit();
    const old_generation = try engine.interface().put(a, .object, "deleted", .missing, "old");
    const deletion = try engine.interface().tombstone(a, .object, "deleted", .{ .exact = old_generation });
    const live_generation = try engine.interface().put(a, .bucket, "live", .missing, "keep");
    const old_page = try engine.scanPage(a, .object, .{});
    defer old_page.deinit(a);
    try std.testing.expectError(error.ResourceLimit, engine.interface().put(a, .object, "new", .missing, "x"));

    const result = try engine.collectTombstones();
    try std.testing.expectEqual(@as(usize, 1), result.reclaimed);
    try std.testing.expectEqual(@as(u48, 1), result.gc_epoch);
    try std.testing.expectEqual(@as(usize, 1), engine.stats().records);
    try std.testing.expectEqual(@as(usize, 8), engine.stats().live_bytes);
    try std.testing.expectError(error.NotFound, engine.interface().get(a, .object, "deleted"));
    try std.testing.expectError(error.Conflict, engine.interface().put(a, .object, "deleted", .{ .exact = deletion }, "stale"));
    try std.testing.expectError(error.Conflict, engine.interface().put(a, .object, "deleted", .missing, "stale"));
    try std.testing.expectError(error.Conflict, engine.interface().put(a, .object, "deleted", .{ .missing_at = 0 }, "stale"));
    try std.testing.expectError(error.Conflict, engine.scanPage(a, .object, .{ .expected_generation = old_page.generation }));
    const page = try engine.scanPage(a, .object, .{ .expected_generation = old_page.generation, .expected_gc_epoch = 1 });
    defer page.deinit(a);
    try std.testing.expectEqual(@as(u48, 1), page.gc_epoch);
    const recreated = try engine.interface().put(a, .object, "deleted", .{ .missing_at = 1 }, "new");
    try std.testing.expect(recreated > live_generation);
    try std.testing.expectError(error.Conflict, engine.interface().put(a, .object, "deleted", .{ .exact = old_generation }, "stale"));
    const noop = try engine.collectTombstones();
    try std.testing.expectEqual(@as(usize, 0), noop.reclaimed);
    try std.testing.expectEqual(@as(u48, 1), noop.gc_epoch);
    try engine.checkpoint();
    const backup = try engine.backup(destination.dir, "copy");
    try std.testing.expectEqual(@as(u48, 1), backup.gc_epoch);
    engine.deinit();
    opened = false;

    var reopened = try metadata.Engine.open(a, io, tmp.dir);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(u48, 1), reopened.stats().gc_epoch);
    try std.testing.expectError(error.Conflict, reopened.interface().put(a, .object, "unused", .missing, "x"));
    var copy_dir = try destination.dir.openDir(io, "copy", .{});
    defer copy_dir.close(io);
    var copy = try metadata.Engine.open(a, io, copy_dir);
    defer copy.deinit();
    try std.testing.expectEqual(@as(u48, 1), copy.stats().gc_epoch);
    const record = try copy.interface().get(a, .object, "deleted");
    defer record.deinit(a);
    try std.testing.expectEqualStrings("new", record.payload);
    _ = try copy.interface().put(a, .object, "unused", .{ .missing_at = 1 }, "ok");
}

test "GC all tombstones empty snapshot repeated epochs and atomic stale batch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try metadata.Engine.open(a, io, tmp.dir);
    var opened = true;
    defer if (opened) engine.deinit();
    for (0..4) |epoch| {
        var batch: [6]metadata.Mutation = undefined;
        for (&batch, 1..) |*mutation, namespace| {
            mutation.* = .{ .record_type = @fromBackingInt(@intCast(namespace)), .key = "gone", .expected = .{ .missing_at = @intCast(epoch) }, .tombstone = true };
        }
        _ = try engine.commit(&batch);
        const result = try engine.collectTombstones();
        try std.testing.expectEqual(@as(usize, 6), result.reclaimed);
        try std.testing.expectEqual(@as(u48, @intCast(epoch + 1)), result.gc_epoch);
        try std.testing.expectEqual(@as(usize, 0), engine.stats().records);
        try std.testing.expectEqual(@as(usize, 0), engine.stats().live_bytes);
        try std.testing.expectError(error.Conflict, engine.commit(&.{
            .{ .record_type = .object, .key = "first", .payload = "must-not-publish" },
            .{ .record_type = .bucket, .key = "gone", .expected = .{ .missing_at = @intCast(epoch) } },
        }));
        try std.testing.expectError(error.NotFound, engine.interface().get(a, .object, "first"));
    }
    engine.deinit();
    opened = false;
    var reopened = try metadata.Engine.open(a, io, tmp.dir);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(u48, 4), reopened.stats().gc_epoch);
    try std.testing.expectEqual(@as(usize, 0), reopened.stats().records);
    _ = try reopened.interface().put(a, .object, "first", .{ .missing_at = 4 }, "ok");
}

const BackupWrites = struct {
    engine: *metadata.Engine,
    err: ?anyerror = null,

    fn hook(context: *anyopaque, point: metadata.Point) void {
        if (point != .backup_captured) return;
        const self: *@This() = @ptrCast(@alignCast(context));
        self.write() catch |err| {
            self.err = err;
        };
    }

    fn write(self: *@This()) !void {
        // Runs while the view is pinned; would deadlock if backup held state lock.
        _ = try self.engine.commit(&.{
            .{ .record_type = .object, .key = "old", .payload = "changed" },
            .{ .record_type = .bucket, .key = "inserted", .payload = "later" },
            .{ .record_type = .credential, .key = "removed", .tombstone = true },
        });
        _ = try self.engine.interface().put(a, .object, "old", .any, "changed-again");
    }
};

test "online backup pins point in time while source writes and never replaces destination" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var destination = std.testing.tmpDir(.{});
    defer destination.cleanup();
    var engine = try metadata.Engine.open(a, io, tmp.dir);
    defer engine.deinit();
    const boundary = try engine.commit(&.{
        .{ .record_type = .object, .key = "old", .payload = "before" },
        .{ .record_type = .credential, .key = "removed", .payload = "before" },
    });
    var writes: BackupWrites = .{ .engine = &engine };
    engine.hook = .{ .context = &writes, .call = BackupWrites.hook };
    const result = try engine.backup(destination.dir, "copy");
    engine.hook = null;
    if (writes.err) |err| return err;
    try std.testing.expectEqual(boundary, result.generation);
    try std.testing.expect(engine.stats().generation > boundary);
    try std.testing.expectError(error.PathAlreadyExists, engine.backup(destination.dir, "copy"));
    try std.testing.expectError(error.InvalidKey, engine.backup(destination.dir, "../escape"));
    try std.testing.expectError(error.InvalidKey, engine.backup(destination.dir, "."));
    var copy_dir = try destination.dir.openDir(io, "copy", .{});
    defer copy_dir.close(io);
    var copy = try metadata.Engine.open(a, io, copy_dir);
    defer copy.deinit();
    try std.testing.expectEqual(boundary, copy.stats().generation);
    try std.testing.expectEqual(@as(usize, 2), copy.stats().records);
    for ([_]metadata.Type{ .object, .credential }, [_][]const u8{ "old", "removed" }) |namespace, key| {
        const record = try copy.interface().get(a, namespace, key);
        defer record.deinit(a);
        try std.testing.expectEqualStrings("before", record.payload);
        try std.testing.expect(!record.tombstone);
    }
    try std.testing.expectError(error.NotFound, copy.interface().get(a, .bucket, "inserted"));
    _ = try copy.interface().put(a, .object, "independent", .missing, "ok");
    try std.testing.expectError(error.NotFound, engine.interface().get(a, .object, "independent"));
}

test "GC uncertain publication freezes source and recovers durable epoch with matching data" {
    inline for (.{ .gc_before_publish, .gc_after_publish }) |fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var engine = try metadata.Engine.open(a, io, tmp.dir);
        _ = try engine.interface().tombstone(a, .object, "gone", .missing);
        engine.test_fault = fault;
        try std.testing.expectError(error.Unavailable, engine.collectTombstones());
        try std.testing.expectEqual(fault == .gc_after_publish, engine.stats().recovery_required);
        engine.deinit();
        var reopened = try metadata.Engine.open(a, io, tmp.dir);
        defer reopened.deinit();
        if (fault == .gc_before_publish) {
            try std.testing.expectEqual(@as(u48, 0), reopened.stats().gc_epoch);
            const record = try reopened.interface().get(a, .object, "gone");
            defer record.deinit(a);
            try std.testing.expect(record.tombstone);
        } else {
            try std.testing.expectEqual(@as(u48, 1), reopened.stats().gc_epoch);
            try std.testing.expectError(error.NotFound, reopened.interface().get(a, .object, "gone"));
            try std.testing.expectError(error.Conflict, reopened.interface().put(a, .object, "gone", .missing, "stale"));
        }
    }
}

test "failed backup publishes nothing and releases pins without freezing source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var destination = std.testing.tmpDir(.{});
    defer destination.cleanup();
    var engine = try metadata.Engine.open(a, io, tmp.dir);
    defer engine.deinit();
    _ = try engine.interface().put(a, .object, "old", .missing, "before");
    var writes: BackupWrites = .{ .engine = &engine };
    engine.hook = .{ .context = &writes, .call = BackupWrites.hook };
    engine.test_fault = .backup_before_publish;
    try std.testing.expectError(error.Unavailable, engine.backup(destination.dir, "copy"));
    engine.hook = null;
    engine.test_fault = null;
    if (writes.err) |err| return err;
    try std.testing.expectError(error.FileNotFound, destination.dir.openDir(io, "copy", .{}));
    try std.testing.expect(!engine.stats().recovery_required);
    _ = try engine.collectTombstones();
    _ = try engine.backup(destination.dir, "copy");
}

fn maintenanceAllocationFailure(allocator: std.mem.Allocator, backup: bool) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var destination = std.testing.tmpDir(.{});
    defer destination.cleanup();
    var engine = try metadata.Engine.open(allocator, io, tmp.dir);
    defer engine.deinit();
    _ = try engine.commit(&.{
        .{ .record_type = .object, .key = "live", .payload = "retained" },
        .{ .record_type = .bucket, .key = "gone", .tombstone = true },
    });
    const result: anyerror!void = if (backup) blk: {
        _ = engine.backup(destination.dir, "copy") catch |err| break :blk err;
        break :blk {};
    } else blk: {
        _ = engine.collectTombstones() catch |err| break :blk err;
        break :blk {};
    };
    const record = try engine.interface().get(a, .object, "live");
    defer record.deinit(a);
    try std.testing.expectEqualStrings("retained", record.payload);
    try std.testing.expect(!engine.stats().recovery_required);
    for (&engine.maps) |*map| {
        var iterator = map.valueIterator();
        while (iterator.next()) |node| {
            try std.testing.expect(!node.*.snapshot_pinned.load(.monotonic));
        }
    }
    try result;
}

test "GC and online backup allocation failures release ownership and retain source" {
    try std.testing.checkAllAllocationFailures(a, maintenanceAllocationFailure, .{false});
    try std.testing.checkAllAllocationFailures(a, maintenanceAllocationFailure, .{true});
}

fn pairWriter(engine: *metadata.Engine) anyerror!void {
    for (0..256) |iteration| {
        const deleted = iteration % 2 == 0;
        _ = try engine.commit(&.{
            .{ .record_type = .object, .key = "pair", .payload = if (deleted) "" else "live", .tombstone = deleted },
            .{ .record_type = .bucket, .key = "pair", .payload = if (deleted) "" else "live", .tombstone = deleted },
        });
    }
}

fn collectRepeatedly(engine: *metadata.Engine) anyerror!void {
    for (0..16) |_| {
        _ = try engine.collectTombstones();
    }
}

test "concurrent writer collector and backups preserve cross namespace atomicity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var destination = std.testing.tmpDir(.{});
    defer destination.cleanup();
    var engine = try metadata.Engine.open(a, io, tmp.dir);
    defer engine.deinit();
    var writer = try io.concurrent(pairWriter, .{&engine});
    defer writer.await(io) catch {};
    var collector = try io.concurrent(collectRepeatedly, .{&engine});
    defer collector.await(io) catch {};
    for (0..8) |iteration| {
        var buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, "backup-{d}", .{iteration});
        _ = try engine.backup(destination.dir, name);
        var directory = try destination.dir.openDir(io, name, .{});
        defer directory.close(io);
        var copy = try metadata.Engine.open(a, io, directory);
        defer copy.deinit();
        const objects = try copy.interface().scan(a, .object);
        defer objects.deinit(a);
        const buckets = try copy.interface().scan(a, .bucket);
        defer buckets.deinit(a);
        try std.testing.expectEqual(objects.records.len, buckets.records.len);
        if (objects.records.len == 1) {
            try std.testing.expectEqual(objects.records[0].generation, buckets.records[0].generation);
            try std.testing.expectEqual(objects.records[0].tombstone, buckets.records[0].tombstone);
            try std.testing.expectEqualStrings(objects.records[0].payload, buckets.records[0].payload);
        }
    }
    try writer.await(io);
    try collector.await(io);
    const record = try engine.interface().get(a, .object, "pair");
    defer record.deinit(a);
    try std.testing.expectEqualStrings("live", record.payload);
}

test "read only inspection rejects GC but can export an independent backup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var destination = std.testing.tmpDir(.{});
    defer destination.cleanup();
    var engine = try metadata.Engine.open(a, io, tmp.dir);
    _ = try engine.interface().tombstone(a, .object, "gone", .missing);
    _ = try engine.collectTombstones();
    engine.deinit();
    var audit = try metadata.Engine.openWithOptions(a, io, tmp.dir, .{ .read_only = true });
    defer audit.deinit();
    try std.testing.expectError(error.ReadOnly, audit.collectTombstones());
    const backup = try audit.backup(destination.dir, "copy");
    try std.testing.expectEqual(@as(u48, 1), backup.gc_epoch);
}

test "GC rebuilds multi namespace ordered indexes and retains exact live versions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try metadata.Engine.open(a, io, tmp.dir);
    var opened = true;
    defer if (opened) engine.deinit();
    var keys: [120][16]u8 = undefined;
    var mutations: [120]metadata.Mutation = undefined;
    for (&keys, &mutations, 0..) |*buffer, *mutation, index| {
        const deleted = (index / 6) % 2 == 0;
        mutation.* = .{
            .record_type = @fromBackingInt(@intCast(index % 6 + 1)),
            .key = try std.fmt.bufPrint(buffer, "key-{d:0>4}", .{index}),
            .payload = if (deleted) "" else "live",
            .tombstone = deleted,
        };
    }
    const generation = try engine.commit(&mutations);
    const result = try engine.collectTombstones();
    try std.testing.expectEqual(@as(usize, 60), result.reclaimed);
    for (1..7) |namespace| {
        const records = try engine.interface().scan(a, @fromBackingInt(@intCast(namespace)));
        defer records.deinit(a);
        try std.testing.expectEqual(@as(usize, 10), records.records.len);
        for (records.records, 0..) |record, index| {
            try std.testing.expectEqual(generation, record.generation);
            try std.testing.expect(!record.tombstone);
            if (index != 0) {
                try std.testing.expect(std.mem.order(u8, records.records[index - 1].key, record.key) == .lt);
            }
        }
    }
    _ = try engine.interface().put(a, mutations[6].record_type, mutations[6].key, .{ .exact = generation }, "updated");
    engine.deinit();
    opened = false;
    var reopened = try metadata.Engine.open(a, io, tmp.dir);
    defer reopened.deinit();
    for (mutations, 0..) |mutation, index| {
        if (mutation.tombstone) {
            try std.testing.expectError(error.NotFound, reopened.interface().get(a, mutation.record_type, mutation.key));
        } else {
            const record = try reopened.interface().get(a, mutation.record_type, mutation.key);
            defer record.deinit(a);
            try std.testing.expectEqualStrings(if (index == 6) "updated" else "live", record.payload);
        }
    }
}

test "empty online backup opens independently and epoch corruption fails closed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var destination = std.testing.tmpDir(.{});
    defer destination.cleanup();
    var engine = try metadata.Engine.open(a, io, tmp.dir);
    var opened = true;
    defer if (opened) engine.deinit();
    _ = try engine.backup(destination.dir, "empty");
    var directory = try destination.dir.openDir(io, "empty", .{});
    defer directory.close(io);
    var copy = try metadata.Engine.open(a, io, directory);
    defer copy.deinit();
    try std.testing.expectEqual(@as(u64, 0), copy.stats().generation);
    _ = try copy.interface().put(a, .object, "first", .missing, "ok");
    _ = try engine.interface().tombstone(a, .object, "gone", .missing);
    _ = try engine.collectTombstones();
    engine.deinit();
    opened = false;
    const snapshot = try tmp.dir.openFile(io, "snapshot", .{ .mode = .read_write });
    defer snapshot.close(io);
    try snapshot.writePositionalAll(io, &.{2}, 10);
    try std.testing.expectError(error.CorruptRecord, metadata.Engine.open(a, io, tmp.dir));
}

test "GC cleanup failure is retryable and exhausted epoch never wraps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try metadata.Engine.open(a, io, tmp.dir);
    defer engine.deinit();
    _ = try engine.interface().tombstone(a, .object, "gone", .missing);
    engine.test_cleanup_failure = .{ .kind = .delete, .remaining = 1 };
    try std.testing.expectError(error.Unavailable, engine.collectTombstones());
    try std.testing.expectEqual(@as(u48, 1), engine.stats().gc_epoch);
    try std.testing.expect(engine.stats().cleanup_pending);
    try std.testing.expect(!engine.stats().recovery_required);
    try std.testing.expectError(error.NotFound, engine.interface().get(a, .object, "gone"));
    try engine.retryCleanup();
    try std.testing.expect(!engine.stats().cleanup_pending);
    _ = try engine.interface().tombstone(a, .object, "gone", .{ .missing_at = 1 });
    engine.gc_epoch = std.math.maxInt(u48);
    try std.testing.expectError(error.GenerationExhausted, engine.collectTombstones());
    try std.testing.expectEqual(std.math.maxInt(u48), engine.stats().gc_epoch);
    try std.testing.expectEqual(@as(usize, 1), engine.stats().records);
}
