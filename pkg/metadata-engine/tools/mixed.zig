const std = @import("std");
const metadata = @import("metadata_engine");
const allocator = std.heap.smp_allocator;
const profile = @import("memory_profile");
const Entry = struct {
    generation: u64 = 0,
    value: u64 = 0,
    tombstone: bool = false,
};
const Model = [metadata.namespace_count][]Entry;

/// One foreground actor owns the reference model; Runtime writer and maintenance
/// run concurrently. No engine reopen occurs until the timed workload is over.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3 or args.len > 5) return error.InvalidArguments;
    const seconds = try std.fmt.parseInt(u32, args[2], 10);
    const slots = if (args.len >= 4) try std.fmt.parseInt(usize, args[3], 10) else 64;
    const payload_size = if (args.len == 5) try std.fmt.parseInt(usize, args[4], 10) else 256;
    if (seconds == 0 or seconds > 540 or slots < 2 or slots > 65536 or
        payload_size < 32 or payload_size > 65536) return error.InvalidArguments;
    const value = try allocator.alloc(u8, payload_size);
    defer allocator.free(value);
    var model: Model = undefined;
    var allocated: usize = 0;
    defer for (model[0..allocated]) |entries| allocator.free(entries);
    for (&model) |*entries| {
        entries.* = try allocator.alloc(Entry, slots);
        @memset(entries.*, .{});
        allocated += 1;
    }
    var tracker: profile.Tracker = .{ .backing = allocator };
    try std.Io.Dir.cwd().createDir(init.io, args[1], .default_dir);
    var directory = try std.Io.Dir.cwd().openDir(init.io, args[1], .{});
    defer directory.close(init.io);
    const options: metadata.Options = if (slots == 64) .{
        .segment_bytes = 4096,
        .max_wal_bytes = 65536,
    } else .{
        .segment_bytes = 1024 * 1024,
        .max_wal_bytes = @max(8 * 1024 * 1024, slots * metadata.namespace_count * payload_size * 2),
    };
    var engine = try metadata.Engine.openWithOptions(tracker.allocator(), init.io, directory, options);
    var opened = true;
    defer if (opened) engine.deinit();
    var runtime: metadata.Runtime = .{ .engine = &engine, .options = .{
        .checkpoint_interval_ms = if (slots == 64) 10 else 100,
        .checkpoint_min_wal_bytes = if (slots == 64) 16384 else 2 * 1024 * 1024,
        .group_delay_us = 0,
    } };
    try runtime.start();
    var running = true;
    defer if (running) runtime.stop();
    var transactions: u64 = 0;
    var conflicts: u64 = 0;
    var retries: u64 = 0;
    var validations: u64 = 0;
    var batches: u64 = 0;
    var deletes: u64 = 0;
    var random = std.Random.DefaultPrng.init(0x5a49474653);
    const start = std.Io.Clock.awake.now(init.io);
    var last_sample_ms: i64 = -1000;
    while (start.durationTo(std.Io.Clock.awake.now(init.io)).toMilliseconds() < @as(i64, seconds) * 1000) {
        const namespace = random.random().uintLessThan(usize, metadata.namespace_count);
        const slot = random.random().uintLessThan(usize, slots);
        const kind: metadata.Type = @fromBackingInt(@intCast(namespace + 1));
        const entry = model[namespace][slot];
        var keys: [2][32]u8 = undefined;
        const key = try std.fmt.bufPrint(&keys[0], "key-{d:0>8}", .{slot});
        const prefix = try std.fmt.bufPrint(value, "value-{d}", .{transactions + 1});
        @memset(value[prefix.len..], @intCast((transactions + 1) % 251));
        // Deliberate conflicts verify that rejected transactions publish nothing.
        if (entry.generation != 0) {
            if (runtime.interface().put(allocator, kind, key, .missing, "invalid")) |_| {
                return error.ExpectedConflict;
            } else |err| if (err != error.Conflict) return err;
            conflicts += 1;
        }
        const tombstone = transactions % 5 == 0;
        var mutations: [2]metadata.Mutation = undefined;
        mutations[0] = .{
            .record_type = kind,
            .key = key,
            .expected = if (entry.generation == 0) .missing else .{ .exact = entry.generation },
            .payload = if (tombstone) "" else value,
            .tombstone = tombstone,
        };
        const count: usize = if (transactions % 7 == 0) 2 else 1;
        const other = (slot + 1) % slots;
        mutations[1] = .{
            .record_type = kind,
            .key = try std.fmt.bufPrint(&keys[1], "key-{d:0>8}", .{other}),
            .payload = value,
        };
        const retry_start = std.Io.Clock.awake.now(init.io);
        const generation = while (true) {
            const result = runtime.commit(mutations[0..count]) catch |err| {
                if (err != error.ResourceLimit) return err;
                if (retry_start.durationTo(std.Io.Clock.awake.now(init.io)).toMilliseconds() > 5000)
                    return error.MaintenanceStalled;
                retries += 1;
                try init.io.sleep(.fromMilliseconds(2), .awake);
                continue;
            };
            break result;
        };
        transactions += 1;
        if (generation != transactions) return error.GenerationMismatch;
        model[namespace][slot] = .{ .generation = generation, .value = transactions, .tombstone = tombstone };
        if (tombstone) deletes += 1;
        if (count == 2) {
            model[namespace][other] = .{ .generation = generation, .value = transactions };
            batches += 1;
        }
        // A page token from before this transaction must be rejected.
        if (engine.scanPage(allocator, kind, .{ .expected_generation = generation - 1 })) |page| {
            page.deinit(allocator);
            return error.ExpectedConflict;
        } else |err| if (err != error.Conflict) return err;
        conflicts += 1;
        if (transactions % @max(64, slots * 4) == 0) {
            try validate(&engine, &model, payload_size);
            validations += 1;
        }
        const elapsed_ms = start.durationTo(std.Io.Clock.awake.now(init.io)).toMilliseconds();
        if (elapsed_ms - last_sample_ms >= 1000) {
            const state = engine.stats();
            std.debug.print(
                "{{\"sample\":true,\"elapsed_ms\":{d},\"records\":{d},\"live_bytes\":{d}," ++
                    "\"engine_live\":{d},\"engine_peak\":{d},\"wal_bytes\":{d}," ++
                    "\"checkpoints\":{d},\"rotations\":{d},\"transactions\":{d}}}\n",
                .{ elapsed_ms, state.records, state.live_bytes, tracker.live.load(.monotonic), tracker.peak.load(.monotonic), state.wal_bytes, state.checkpoints, state.rotations, transactions },
            );
            last_sample_ms = elapsed_ms;
        }
    }
    runtime.stop();
    running = false;
    try validate(&engine, &model, payload_size);
    const stats = engine.stats();
    if (stats.checkpoints == 0 or stats.rotations == 0 or stats.recovery_required)
        return error.MaintenanceNotExercised;
    const duration = start.durationTo(std.Io.Clock.awake.now(init.io)).toMilliseconds();
    engine.deinit();
    opened = false;
    engine = try metadata.Engine.openWithOptions(tracker.allocator(), init.io, directory, options);
    opened = true;
    try validate(&engine, &model, payload_size);
    if (engine.stats().generation != transactions) return error.GenerationMismatch;
    engine.deinit();
    opened = false;
    const remaining = tracker.live.load(.monotonic);
    if (remaining != 0) return error.EngineAllocationLeak;
    std.debug.print(
        "{{\"namespace_count\":{d},\"transactions\":{d},\"batches\":{d},\"tombstones\":{d},\"conflicts\":{d}," ++
            "\"quota_retries\":{d},\"model_validations\":{d},\"checkpoints\":{d}," ++
            "\"rotations\":{d},\"elapsed_ms\":{d},\"reopen_verified\":true," ++
            "\"slots_per_namespace\":{d},\"payload_bytes\":{d},\"records\":{d}," ++
            "\"engine_live_after_close\":{d},\"engine_peak\":{d},\"wal_quota_bytes\":{d}}}\n",
        .{ metadata.namespace_count, transactions, batches, deletes, conflicts, retries, validations + 2, stats.checkpoints, stats.rotations, duration, slots, payload_size, stats.records, remaining, tracker.peak.load(.monotonic), options.max_wal_bytes },
    );
}

fn checkRecord(record: metadata.Record, entry: Entry, payload_size: usize) !void {
    if (entry.generation == 0 or record.generation != entry.generation or record.tombstone != entry.tombstone)
        return error.ModelMismatch;
    var buffer: [32]u8 = undefined;
    if (entry.tombstone) {
        if (record.payload.len != 0) return error.ModelMismatch;
        return;
    }
    const expected = try std.fmt.bufPrint(&buffer, "value-{d}", .{entry.value});
    if (record.payload.len != payload_size or !std.mem.startsWith(u8, record.payload, expected) or
        !std.mem.allEqual(u8, record.payload[expected.len..], @intCast(entry.value % 251))) return error.ModelMismatch;
}

fn validate(engine: *metadata.Engine, model: *const Model, payload_size: usize) !void {
    var records: usize = 0;
    var live_bytes: usize = 0;
    for (model, 0..) |entries, namespace| {
        const kind: metadata.Type = @fromBackingInt(@intCast(namespace + 1));
        var expected_count: [2]usize = .{ 0, 0 };
        for (entries, 0..) |entry, slot| {
            var buffer: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&buffer, "key-{d:0>8}", .{slot});
            if (entry.generation == 0) {
                if (engine.interface().get(allocator, kind, key)) |record| {
                    record.deinit(allocator);
                    return error.UnexpectedRecord;
                } else |err| if (err != error.NotFound) return err;
                continue;
            }
            const record = try engine.interface().get(allocator, kind, key);
            defer record.deinit(allocator);
            try checkRecord(record, entry, payload_size);
            records += 1;
            live_bytes += record.key.len + record.payload.len;
            expected_count[0] += 1;
            if (!entry.tombstone) expected_count[1] += 1;
        }
        for (0..2) |filter| {
            var cursor: ?[]u8 = null;
            defer if (cursor) |key| allocator.free(key);
            var count: usize = 0;
            while (true) {
                const page = try engine.scanPage(allocator, kind, .{
                    .prefix = "key-",
                    .start_after = cursor,
                    .limit = 7,
                    .include_tombstones = filter == 0,
                    .expected_generation = engine.stats().generation,
                });
                defer page.deinit(allocator);
                for (page.records) |record| {
                    const slot = try std.fmt.parseInt(usize, record.key[4..], 10);
                    if (slot >= entries.len) return error.UnexpectedRecord;
                    try checkRecord(record, entries[slot], payload_size);
                    if (filter == 1 and record.tombstone) return error.UnexpectedTombstone;
                    if (cursor) |key| if (std.mem.order(u8, key, record.key) != .lt) return error.CursorStalled;
                    count += 1;
                }
                if (page.next_start_after) |next| {
                    if (cursor) |key| if (std.mem.order(u8, key, next) != .lt) return error.CursorStalled;
                    const owned = try allocator.dupe(u8, next);
                    if (cursor) |key| allocator.free(key);
                    cursor = owned;
                } else break;
            }
            if (count != expected_count[filter]) return error.ModelMismatch;
        }
    }
    const stats = engine.stats();
    if (stats.records != records or stats.live_bytes != live_bytes) return error.ModelMismatch;
}
