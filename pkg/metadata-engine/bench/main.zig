const std = @import("std");
const engine_package = @import("metadata_engine");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or args.len > 8) {
        std.debug.print("usage: metadata-bench NEW_DIRECTORY [operations=1000] [payload_bytes=256] [batch_size=1] [workers=1] [direct|runtime] [compare|compare-fullsync|profile|phases]\n", .{});
        return error.InvalidArguments;
    }
    const profiling = args.len == 8 and std.mem.eql(u8, args[7], "profile");
    const phases = args.len == 8 and std.mem.eql(u8, args[7], "phases");
    const comparison = args.len == 8 and !profiling and !phases;
    const full_sync = comparison and std.mem.eql(u8, args[7], "compare-fullsync");
    if (comparison and !full_sync and !std.mem.eql(u8, args[7], "compare")) return error.InvalidArguments;
    const io = if (full_sync) try @import("fullsync.zig").wrap(init.io) else init.io;
    const operations = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 1000;
    const payload_size = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else 256;
    const batch_size = if (args.len > 4) try std.fmt.parseInt(usize, args[4], 10) else 1;
    const workers = if (args.len > 5) try std.fmt.parseInt(usize, args[5], 10) else 1;
    const use_runtime = if (args.len > 6) std.mem.eql(u8, args[6], "runtime") else true;
    if (args.len > 6 and !use_runtime and !std.mem.eql(u8, args[6], "direct")) return error.InvalidArguments;
    if (workers == 0 or workers > 64) return error.InvalidArguments;
    if (operations == 0 or batch_size == 0 or batch_size > engine_package.Limits.max_mutations or
        payload_size > 1024 * 1024) return error.InvalidArguments;
    // Exclusive creation prevents accidentally benchmarking or overwriting live data.
    try std.Io.Dir.cwd().createDir(io, args[1], .default_dir);
    var root = try std.Io.Dir.cwd().openDir(io, args[1], .{});
    defer root.close(io);
    const allocator = std.heap.smp_allocator;
    var tracker: @import("profile.zig").Tracker = .{ .backing = allocator };
    const engine_allocator = if (profiling) tracker.allocator() else allocator;
    var engine = try engine_package.Engine.openWithOptions(engine_allocator, io, root, .{ .diagnostics = phases });
    var profile: @import("profile.zig").Context = .{ .tracker = &tracker, .engine = &engine };
    if (profiling) {
        engine.hook = .{ .context = &profile, .call = @import("profile.zig").Context.hook };
        profile.mark("opened");
    }
    defer if (profiling) {
        tracker.report("closed", null);
        std.debug.assert(tracker.live.load(.monotonic) == 0);
    };
    var open = true;
    defer if (open) engine.deinit();
    const payload = try allocator.alloc(u8, payload_size);
    defer allocator.free(payload);
    @memset(payload, 'x');
    const timings = try allocator.alloc(u64, operations);
    defer allocator.free(timings);
    const keys = try allocator.alloc([40]u8, batch_size);
    defer allocator.free(keys);
    const mutations = try allocator.alloc(engine_package.Mutation, batch_size);
    defer allocator.free(mutations);
    std.debug.print("zig={s} mode={s} os={s} arch={s} insert_sync=per_transaction operations={d} payload_bytes={d} batch_size={d}\n", .{
        @import("builtin").zig_version_string, @tagName(@import("builtin").mode),
        @tagName(@import("builtin").os.tag),   @tagName(@import("builtin").cpu.arch),
        operations,                            payload_size,
        batch_size,
    });
    const write_start = std.Io.Clock.awake.now(io);
    var completed: usize = 0;
    var transactions: usize = 0;
    while (completed < operations) {
        const count = @min(batch_size, operations - completed);
        for (0..count) |index| {
            const key = try std.fmt.bufPrint(&keys[index], "bucket/key-{d:0>12}", .{completed + index});
            mutations[index] = .{ .record_type = .object, .key = key, .expected = .missing, .payload = payload };
        }
        const start = std.Io.Clock.awake.now(io);
        _ = try engine.commit(mutations[0..count]);
        timings[transactions] = elapsed(io, start);
        completed += count;
        transactions += 1;
    }
    report("durable_insert", operations, transactions, elapsed(io, write_start), timings[0..transactions]);
    if (profiling) profile.mark("inserted");
    const read_start = std.Io.Clock.awake.now(io);
    for (0..operations) |index| {
        var buffer: [40]u8 = undefined;
        const key = try std.fmt.bufPrint(&buffer, "bucket/key-{d:0>12}", .{index});
        const start = std.Io.Clock.awake.now(io);
        const record = try engine.interface().get(allocator, .object, key);
        if (!std.mem.eql(u8, payload, record.payload)) return error.ValidationFailed;
        record.deinit(allocator);
        timings[index] = elapsed(io, start);
    }
    report("warm_get", operations, operations, elapsed(io, read_start), timings);
    if (profiling) profile.mark("read_complete");
    const updated_payload = try allocator.alloc(u8, payload_size);
    defer allocator.free(updated_payload);
    @memset(updated_payload, 'y');
    const futures = try allocator.alloc(std.Io.Future(anyerror!void), workers);
    defer allocator.free(futures);
    var runtime: engine_package.Runtime = .{ .engine = &engine };
    if (use_runtime) try runtime.start();
    var runtime_running = use_runtime;
    defer if (runtime_running) runtime.stop();
    const writer_repository = if (use_runtime) runtime.interface() else engine.interface();
    const before_overwrite = engine.stats();
    const concurrent_start = std.Io.Clock.awake.now(io);
    var launched: usize = 0;
    // Join already launched workers even when spawning or another worker fails.
    defer for (futures[0..launched]) |*future| {
        future.await(io) catch {};
    };
    for (0..workers) |worker| {
        futures[worker] = try io.concurrent(overwriteWorker, .{
            writer_repository, allocator, io, operations, updated_payload, timings, worker, workers,
        });
        launched += 1;
    }
    var worker_error: ?anyerror = null;
    for (futures[0..launched]) |*future| {
        future.await(io) catch |err| {
            worker_error = err;
        };
    }
    launched = 0;
    if (worker_error) |err| return err;
    const overwrite_ns = elapsed(io, concurrent_start);
    if (use_runtime) runtime.stop();
    runtime_running = false;
    if (profiling) profile.mark("overwritten");
    const after_overwrite = engine.stats();
    if (phases) {
        inline for (.{ "lock_wait", "lock_hold", "wal_append", "wal_sync", "rotation", "snapshot_capture", "snapshot_install", "cleanup_io" }) |name| {
            reportPhase(name, @field(after_overwrite.phases, name));
        }
        const runtime_stats = runtime.stats();
        std.debug.print("rotation_stats linked={d} copied_bytes={d}\n", .{
            after_overwrite.linked_rotations, after_overwrite.rotation_copy_bytes,
        });
        std.debug.print("maintenance_stats target_wal_bytes={d} deferred={d} last_duration_ns={d} ready_groups={d}\n", .{
            runtime_stats.checkpoint_target_wal_bytes, runtime_stats.checkpoint_deferred,
            runtime_stats.last_checkpoint_duration_ns, runtime_stats.ready_groups,
        });
        reportPhase("queue_wait", runtime_stats.queue_wait);
        reportPhase("group_collect", runtime_stats.group_collect);
        std.debug.print("group_stats groups={d} transactions={d} peak_pending={d} max_group_size={d}\n", .{
            runtime_stats.groups, runtime_stats.transactions, runtime_stats.peak_pending, runtime_stats.max_group_size,
        });
    }
    std.debug.print(
        "overwrite_workers={d} runtime={} transactions={d} " ++
            "commit_wal_syncs={d} rotations={d} checkpoints={d}\n",
        .{
            workers,
            use_runtime,
            after_overwrite.commits - before_overwrite.commits,
            after_overwrite.syncs - before_overwrite.syncs,
            after_overwrite.rotations - before_overwrite.rotations,
            after_overwrite.checkpoints,
        },
    );
    report("concurrent_overwrite", operations, operations, overwrite_ns, timings);
    const page_start = std.Io.Clock.awake.now(io);
    var cursor: ?[]u8 = null;
    defer if (cursor) |key| allocator.free(key);
    var listed: usize = 0;
    var pages: usize = 0;
    while (true) {
        const page = try engine.scanPage(allocator, .object, .{
            .prefix = "bucket/key-",
            .start_after = cursor,
            .limit = 100,
        });
        defer page.deinit(allocator);
        listed += page.records.len;
        pages += 1;
        if (cursor) |key| allocator.free(key);
        cursor = null;
        if (page.next_start_after) |key| cursor = try allocator.dupe(u8, key) else break;
    }
    if (listed != operations) return error.ValidationFailed;
    std.debug.print("prefix_pages pages={d} records={d} elapsed_ms={d:.3}\n", .{
        pages, listed, @as(f64, @floatFromInt(elapsed(io, page_start))) / 1e6,
    });
    if (profiling) profile.mark("pages_complete");
    const scan_start = std.Io.Clock.awake.now(io);
    const records = try engine.interface().scan(allocator, .object);
    if (records.records.len != operations) return error.ValidationFailed;
    if (profiling) profile.mark("scan_live");
    records.deinit(allocator);
    if (profiling) profile.mark("scan_released");
    std.debug.print("full_sorted_scan records={d} elapsed_ms={d:.3}\n", .{ operations, @as(f64, @floatFromInt(elapsed(io, scan_start))) / 1e6 });
    const close_start = std.Io.Clock.awake.now(io);
    engine.deinit();
    open = false;
    if (comparison) std.debug.print("close elapsed_ms={d:.3}\n", .{
        @as(f64, @floatFromInt(elapsed(io, close_start))) / 1e6,
    });
    const wal_reopen_start = std.Io.Clock.awake.now(io);
    engine = try engine_package.Engine.openWithOptions(engine_allocator, io, root, .{ .diagnostics = phases });
    open = true;
    std.debug.print("wal_reopen elapsed_ms={d:.3} generation={d}\n", .{
        @as(f64, @floatFromInt(elapsed(io, wal_reopen_start))) / 1e6, engine.generation,
    });
    if (profiling) {
        profile.mark("wal_reopened");
        engine.hook = .{ .context = &profile, .call = @import("profile.zig").Context.hook };
    }
    // External KV comparisons use one clean close/reopen. A Zig checkpoint is
    // not equivalent to an LSM flush/compaction or a bbolt read snapshot.
    if (!comparison) {
        const snapshot_start = std.Io.Clock.awake.now(io);
        try engine.checkpoint();
        if (profiling) profile.mark("checkpoint_complete");
        std.debug.print("checkpoint elapsed_ms={d:.3}\n", .{@as(f64, @floatFromInt(elapsed(io, snapshot_start))) / 1e6});
        engine.deinit();
        open = false;
        const reopen_start = std.Io.Clock.awake.now(io);
        engine = try engine_package.Engine.openWithOptions(engine_allocator, io, root, .{ .diagnostics = phases });
        open = true;
        std.debug.print("snapshot_reopen elapsed_ms={d:.3} generation={d}\n", .{
            @as(f64, @floatFromInt(elapsed(io, reopen_start))) / 1e6, engine.generation,
        });
    }
    if (profiling) profile.mark("snapshot_reopened");
    const restored = try engine.interface().scan(allocator, .object);
    defer restored.deinit(allocator);
    if (profiling) profile.mark("restored_scan_live");
    if (restored.records.len != operations) return error.ValidationFailed;
    for (restored.records, 0..) |record, index| {
        var buffer: [40]u8 = undefined;
        const expected_key = try std.fmt.bufPrint(&buffer, "bucket/key-{d:0>12}", .{index});
        if (!std.mem.eql(u8, expected_key, record.key) or
            !std.mem.eql(u8, updated_payload, record.payload)) return error.ValidationFailed;
    }
    if (engine.stats().generation != transactions + operations) return error.ValidationFailed;
}

fn elapsed(io: std.Io, start: std.Io.Timestamp) u64 {
    return @intCast(@max(1, start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds));
}

fn report(name: []const u8, operations: usize, transactions: usize, ns: u64, timings: []u64) void {
    std.mem.sort(u64, timings, {}, std.sort.asc(u64));
    const seconds = @as(f64, @floatFromInt(ns)) / 1e9;
    std.debug.print(
        "{s} operations={d} transactions={d} qps={d:.2} tps={d:.2} " ++
            "latency_us_p50={d:.2} p95={d:.2} p99={d:.2} p99_9={d:.2} max={d:.2}\n",
        .{
            name,
            operations,
            transactions,
            @as(f64, @floatFromInt(operations)) / seconds,
            @as(f64, @floatFromInt(transactions)) / seconds,
            percentile(timings, 50),
            percentile(timings, 95),
            percentile(timings, 99),
            @as(f64, @floatFromInt(timings[@min(timings.len - 1, (timings.len * 999 - 1) / 1000)])) / 1000,
            percentile(timings, 100),
        },
    );
}

fn percentile(timings: []const u64, percent: usize) f64 {
    return @as(f64, @floatFromInt(timings[@min(timings.len - 1, (timings.len * percent - 1) / 100)])) / 1000;
}

fn overwriteWorker(
    repository: engine_package.MetadataRepository,
    allocator: std.mem.Allocator,
    io: std.Io,
    operations: usize,
    payload: []const u8,
    timings: []u64,
    worker: usize,
    workers: usize,
) anyerror!void {
    var index = worker;
    while (index < operations) : (index += workers) {
        var buffer: [40]u8 = undefined;
        const key = try std.fmt.bufPrint(&buffer, "bucket/key-{d:0>12}", .{index});
        const start = std.Io.Clock.awake.now(io);
        _ = try repository.put(allocator, .object, key, .any, payload);
        timings[index] = elapsed(io, start);
    }
}

fn reportPhase(name: []const u8, phase: anytype) void {
    std.debug.print("phase={s} count={d} total_ms={d:.3} max_ms={d:.3}\n", .{
        name,                                        phase.count, @as(f64, @floatFromInt(phase.total_ns)) / 1e6,
        @as(f64, @floatFromInt(phase.max_ns)) / 1e6,
    });
}
