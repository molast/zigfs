const std = @import("std");
const Engine = @import("engine.zig").Engine;
const codec = @import("codec.zig");
const a = std.testing.allocator;
const io = std.testing.io;

fn expectPayload(engine: *Engine, key: []const u8, expected: []const u8) !void {
    const record = try engine.interface().get(a, .object, key);
    defer record.deinit(a);
    try std.testing.expectEqualStrings(expected, record.payload);
}

test "existing MetadataRepository contract and snapshot reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    try @import("contract.zig").run(engine.interface());
    const generation = engine.generation;
    try engine.checkpoint();
    engine.deinit();
    var reopened = try Engine.open(a, io, tmp.dir);
    defer reopened.deinit();
    try std.testing.expectEqual(generation, reopened.generation);
    const tombstone = try reopened.interface().get(a, .bucket, "contract-secondary");
    defer tombstone.deinit(a);
    try std.testing.expect(tombstone.tombstone);
    try std.testing.expectError(error.Conflict, reopened.interface().put(a, .bucket, tombstone.key, .missing, "new"));
    const next = try reopened.interface().put(a, .directory, "folder/", .missing, "directory");
    try std.testing.expect(next > generation);
}

test "atomic batch validates all predicates and rejects duplicate keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    defer engine.deinit();
    const first = try engine.commit(&.{
        .{ .record_type = .object, .key = "a", .payload = "one" },
        .{ .record_type = .object, .key = "b", .payload = "two" },
    });
    try std.testing.expectError(error.Conflict, engine.commit(&.{
        .{ .record_type = .object, .key = "a", .payload = "changed", .expected = .{ .exact = first } },
        .{ .record_type = .object, .key = "b", .payload = "changed", .expected = .missing },
    }));
    try expectPayload(&engine, "a", "one");
    try std.testing.expectEqual(first, engine.generation);
    try std.testing.expectError(error.InvalidKey, engine.commit(&.{
        .{ .record_type = .object, .key = "a" },
        .{ .record_type = .object, .key = "a" },
    }));
}

test "durable but unpublished batch recovers in full and poisons old handle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    engine.test_fault = .after_sync;
    try std.testing.expectError(error.Unavailable, engine.commit(&.{
        .{ .record_type = .object, .key = "a", .payload = "one" },
        .{ .record_type = .object, .key = "b", .payload = "two" },
    }));
    try std.testing.expectError(error.Unavailable, engine.interface().get(a, .object, "a"));
    try std.testing.expectError(error.Unavailable, engine.interface().put(a, .object, "c", .any, "three"));
    engine.deinit();
    var reopened = try Engine.open(a, io, tmp.dir);
    defer reopened.deinit();
    try expectPayload(&reopened, "a", "one");
    try expectPayload(&reopened, "b", "two");
}

test "every truncated final transaction boundary preserves earlier commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    _ = try engine.interface().put(a, .object, "stable", .missing, "acknowledged");
    const boundary = engine.wal_length;
    engine.test_fault = .after_append;
    try std.testing.expectError(error.Unavailable, engine.commit(&.{
        .{ .record_type = .object, .key = "a", .payload = "unconfirmed" },
        .{ .record_type = .object, .key = "b", .payload = "unconfirmed" },
    }));
    engine.deinit();
    var wal = try tmp.dir.openFile(io, "wal", .{ .mode = .read_write });
    defer wal.close(io);
    const full = try a.alloc(u8, @intCast((try wal.stat(io)).size));
    defer a.free(full);
    try std.testing.expectEqual(full.len, try wal.readPositionalAll(io, full, 0));
    for (@as(usize, @intCast(boundary))..full.len) |length| {
        try wal.writePositionalAll(io, full[0..length], 0);
        try wal.setLength(io, length);
        var recovered = try Engine.open(a, io, tmp.dir);
        try expectPayload(&recovered, "stable", "acknowledged");
        try std.testing.expectError(error.NotFound, recovered.interface().get(a, .object, "a"));
        try std.testing.expectError(error.NotFound, recovered.interface().get(a, .object, "b"));
        try std.testing.expectEqual(boundary, recovered.wal_length);
        recovered.deinit();
    }
}

test "complete corrupt WAL frame fails closed without truncating it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    _ = try engine.interface().put(a, .object, "a", .missing, "one");
    const length = engine.wal_length;
    engine.deinit();
    var wal = try tmp.dir.openFile(io, "wal", .{ .mode = .read_write });
    defer wal.close(io);
    try wal.writePositionalAll(io, "\xff", length - 1);
    try std.testing.expectError(error.CorruptRecord, Engine.open(a, io, tmp.dir));
    try std.testing.expectEqual(length, (try wal.stat(io)).size);
}

test "checkpoint interruption retains replay chain and subsequent updates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    _ = try engine.interface().put(a, .object, "a", .missing, "one");
    engine.test_fault = .after_snapshot;
    try std.testing.expectError(error.Unavailable, engine.checkpoint());
    engine.deinit();
    var recovered = try Engine.open(a, io, tmp.dir);
    try expectPayload(&recovered, "a", "one");
    _ = try recovered.interface().put(a, .object, "a", .any, "two");
    try recovered.checkpoint();
    _ = try recovered.interface().put(a, .object, "b", .missing, "three");
    recovered.deinit();
    var reopened = try Engine.open(a, io, tmp.dir);
    defer reopened.deinit();
    try expectPayload(&reopened, "a", "two");
    try expectPayload(&reopened, "b", "three");
}

test "missing required snapshot is not mistaken for empty database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    _ = try engine.interface().put(a, .object, "a", .missing, "one");
    try engine.checkpoint();
    engine.deinit();
    try tmp.dir.deleteFile(io, "snapshot");
    try std.testing.expectError(error.CorruptRecord, Engine.open(a, io, tmp.dir));
}

test "exclusive writer lock is released after close" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    try std.testing.expectError(error.Busy, Engine.open(a, io, tmp.dir));
    engine.deinit();
    var reopened = try Engine.open(a, io, tmp.dir);
    reopened.deinit();
}

test "codec bounds and checksum validation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    defer engine.deinit();
    try std.testing.expectError(error.InvalidKey, engine.interface().put(a, .object, "", .any, "x"));
    try std.testing.expectError(error.InvalidKey, engine.interface().put(a, .object, "a\x00b", .any, "x"));
    const key = @as([codec.Limits.max_key_bytes + 1]u8, @splat('a'));
    try std.testing.expectError(error.InvalidKey, engine.interface().put(a, .object, &key, .any, "x"));
    _ = try engine.interface().put(a, .object, key[0..codec.Limits.max_key_bytes], .missing, "x");
}

fn allocationScenario(allocator: std.mem.Allocator, root: std.Io.Dir) !void {
    var engine = try Engine.open(allocator, io, root);
    defer engine.deinit();
    _ = try engine.commit(&.{
        .{ .record_type = .object, .key = "one", .payload = "value" },
        .{ .record_type = .bucket, .key = "two", .payload = "value" },
    });
    const result = try engine.interface().scan(allocator, .object);
    defer result.deinit(allocator);
    try engine.checkpoint();
}

test "allocation failures release ownership across prepare recovery scan and snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.checkAllAllocationFailures(a, allocationScenario, .{tmp.dir});
}

fn raceWriter(engine: *Engine, expected: u64, payload: []const u8) anyerror!bool {
    _ = engine.interface().put(a, .object, "shared", .{ .exact = expected }, payload) catch |err| {
        if (err == error.Conflict) return false;
        return err;
    };
    return true;
}

test "concurrent compare and swap has exactly one winner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    defer engine.deinit();
    const generation = try engine.interface().put(a, .object, "shared", .missing, "original");
    var first = try io.concurrent(raceWriter, .{ &engine, generation, "first" });
    var second = io.concurrent(raceWriter, .{ &engine, generation, "second" }) catch |err| {
        _ = try first.await(io);
        return err;
    };
    const first_result = first.await(io);
    const second_result = second.await(io);
    try std.testing.expect((try first_result) != (try second_result));
    try std.testing.expectEqual(generation + 1, engine.generation);
}

test "foreign snapshot and corrupt snapshot fail closed" {
    var first_tmp = std.testing.tmpDir(.{});
    defer first_tmp.cleanup();
    var second_tmp = std.testing.tmpDir(.{});
    defer second_tmp.cleanup();
    var first = try Engine.open(a, io, first_tmp.dir);
    _ = try first.interface().put(a, .object, "a", .missing, "one");
    try first.checkpoint();
    first.deinit();
    var second = try Engine.open(a, io, second_tmp.dir);
    _ = try second.interface().put(a, .object, "b", .missing, "two");
    try second.checkpoint();
    second.deinit();
    var buffer: [4096]u8 = undefined;
    const snapshot = try first_tmp.dir.readFile(io, "snapshot", &buffer);
    try second_tmp.dir.writeFile(io, .{ .sub_path = "snapshot", .data = snapshot });
    try std.testing.expectError(error.CorruptRecord, Engine.open(a, io, second_tmp.dir));
    buffer[snapshot.len - 1] ^= 0xff;
    try first_tmp.dir.writeFile(io, .{ .sub_path = "snapshot", .data = buffer[0..snapshot.len] });
    try std.testing.expectError(error.CorruptRecord, Engine.open(a, io, first_tmp.dir));
}

test "future format is rejected without modifying files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    engine.deinit();
    var file = try tmp.dir.openFile(io, "wal", .{ .mode = .read_write });
    defer file.close(io);
    try file.writePositionalAll(io, &.{ 4, 0 }, 8);
    try std.testing.expectError(error.UnsupportedFormat, Engine.open(a, io, tmp.dir));
    try std.testing.expectEqual(@as(u64, 80), (try file.stat(io)).size);
}

test "initialization refuses unrelated data directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "business-data", .data = "untouched" });
    try std.testing.expectError(error.DirectoryNotEmpty, Engine.open(a, io, tmp.dir));
}

test "all namespaces survive snapshot and repeated overwrite" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    for ([_]@import("types.zig").Type{ .system, .bucket, .object, .multipart, .credential, .directory }) |record_type| {
        _ = try engine.interface().put(a, record_type, "same-key", .missing, @tagName(record_type));
    }
    for (0..20) |_| {
        _ = try engine.interface().put(a, .object, "same-key", .any, "object");
    }
    try engine.checkpoint();
    engine.deinit();
    var reopened = try Engine.open(a, io, tmp.dir);
    defer reopened.deinit();
    for ([_]@import("types.zig").Type{ .system, .bucket, .object, .multipart, .credential, .directory }) |record_type| {
        const record = try reopened.interface().get(a, record_type, "same-key");
        defer record.deinit(a);
        try std.testing.expectEqualStrings(@tagName(record_type), record.payload);
    }
}

test "missing WAL without a snapshot is not reinitialized" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine = try Engine.open(a, io, tmp.dir);
    _ = try engine.interface().put(a, .object, "a", .missing, "one");
    engine.deinit();
    try tmp.dir.deleteFile(io, "wal");
    try std.testing.expectError(error.CorruptRecord, Engine.open(a, io, tmp.dir));
}
