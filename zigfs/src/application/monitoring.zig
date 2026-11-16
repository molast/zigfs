const std = @import("std");
const Application = @import("mod.zig").Application;
const host = @import("../backend/host_metrics.zig");
const process = @import("../backend/process_metrics.zig");
const filesystem = @import("../backend/filesystem_capacity.zig");
pub const analysis = @import("monitoring_analysis.zig");
const runtime = @import("runtime_metrics.zig");
const store = @import("monitoring_store.zig");
const retention = store.max_points;
pub const Persistence = struct { state: enum { pending, healthy, unavailable } = .pending, last_saved_at: ?i64 = null };

pub const Point = struct {
    user_cpu_seconds: ?f64 = null,
    kernel_cpu_seconds: ?f64 = null,
    allocated_bytes: ?u64 = null,
    freed_bytes: ?u64 = null,
    reallocations: ?u64 = null,
    timestamp: i64 = 0,
    run_id: i64 = 0,
    host_cpu: ?f64 = null,
    process_cpu: ?f64 = null,
    memory_used: ?f64 = null,
    memory_total: ?f64 = null,
    rss: ?f64 = null,
    virtual_bytes: ?f64 = null,
    peak_rss: ?f64 = null,
    heap: ?f64 = null,
    heap_peak: ?f64 = null,
    allocations: ?u64 = null,
    frees: ?u64 = null,
    allocation_failures: ?u64 = null,
    cores: ?f64 = null,
    threads: ?f64 = null,
    workers: ?usize = null,
    workers_busy: ?usize = null,
    descriptors: ?f64 = null,
    descriptor_limit: ?f64 = null,
    storage_used: ?u64 = null,
    storage_total: ?u64 = null,
    storage_available: ?u64 = null,
    load1: ?f64 = null,
    load5: ?f64 = null,
    load15: ?f64 = null,
    disk_read: ?f64 = null,
    disk_write: ?f64 = null,
    network_receive: ?f64 = null,
    network_transmit: ?f64 = null,
    upload: ?f64 = null,
    download: ?f64 = null,
    qps: ?f64 = null,
    error_percent: ?f64 = null,
    client_error_percent: ?f64 = null,
    p50: ?f64 = null,
    p95: ?f64 = null,
    p99: ?f64 = null,
    active_requests: u64 = 0,
    active_connections: u64 = 0,
};
const Baseline = struct {
    host: host.Sample,
    process: ?process.Sample,
    s3: runtime.OperationSnapshot,
    upload: u64,
    download: u64,
    time: f64,
};
pub const Registry = struct {
    mutex: std.Io.Mutex = .init,
    history: std.ArrayList(Point) = .empty,
    next: usize = 0,
    ticks: usize = 0,
    run_id: i64 = 0,
    persistence: Persistence = .{},
    alert_engine: analysis.Engine = .{},
    diagnosis: analysis.Analysis = .{ .rss = .{}, .heap = .{}, .descriptors = .{}, .allocations = .{} },
    latest: ?Point = null,
    previous: ?Baseline = null,
    history_baseline: ?Baseline = null,

    pub fn read(self: *Registry, a: std.mem.Allocator, io: std.Io, seconds: i64) !struct { latest: ?Point, history: []Point, step_seconds: usize, persistence: Persistence, diagnosis: analysis.Analysis, alerts: analysis.Engine } {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var result: std.ArrayList(Point) = .empty;
        errdefer result.deinit(a);
        const cutoff = if (self.latest) |p| p.timestamp - seconds else 0;
        const count = self.history.items.len;
        var eligible: usize = 0;
        for (0..count) |i| {
            const p = self.history.items[(self.next + i) % count];
            if (p.timestamp >= cutoff) eligible += 1;
        }
        const stride = @max(1, (eligible + 359) / 360);
        var selected: usize = 0;
        for (0..count) |i| {
            const p = self.history.items[(self.next + i) % count];
            if (p.timestamp < cutoff) continue;
            if (selected % stride == 0 or i + 1 == count) try result.append(a, p);
            selected += 1;
        }
        return .{ .latest = self.latest, .history = try result.toOwnedSlice(a), .step_seconds = stride * 10, .persistence = self.persistence, .diagnosis = self.diagnosis, .alerts = self.alert_engine };
    }
};

pub fn rate(current: f64, previous: f64, elapsed: f64) ?f64 {
    if (current < 0 or previous < 0 or current < previous or elapsed <= 0 or elapsed > 3) return null;
    return (current - previous) / elapsed;
}

/// Upper bucket bounds, never fabricated exact quantiles. Overflow quantiles are unavailable.
pub fn percentile(current: runtime.OperationSnapshot, previous: runtime.OperationSnapshot, q: f64) ?f64 {
    if (current.completed <= previous.completed) return null;
    const target = @ceil(@as(f64, @floatFromInt(current.completed - previous.completed)) * q);
    var count: u64 = 0;
    for (runtime.bounds, 0..) |bound, i| {
        if (current.histogram[i] < previous.histogram[i]) return null;
        count += current.histogram[i] - previous.histogram[i];
        if (@as(f64, @floatFromInt(count)) >= target) return @floatFromInt(bound);
    }
    return null;
}

pub fn collect(app: *Application) !void {
    const io = app.io orelse return;
    const h = host.read();
    const proc = process.read();
    const s3 = app.runtime_metrics.s3.snapshot(io);
    const management = app.runtime_metrics.management.snapshot(io);
    const up = app.runtime_metrics.uploaded_bytes.load(.monotonic);
    const down = app.runtime_metrics.downloaded_bytes.load(.monotonic);
    const now: f64 = @as(f64, @floatFromInt(std.Io.Clock.awake.now(io).toMilliseconds())) / 1000;
    var point: Point = .{
        .user_cpu_seconds = host.available(h.user_seconds),
        .kernel_cpu_seconds = host.available(h.kernel_seconds),
        .timestamp = std.Io.Clock.real.now(io).toSeconds(),
        .run_id = app.monitor.run_id,
        .memory_total = host.available(h.memory_total),
        .memory_used = if (h.memory_total >= 0 and h.memory_available >= 0) @max(0, h.memory_total - h.memory_available) else null,
        .rss = if (proc) |p| @floatFromInt(p.resident_bytes) else null,
        .virtual_bytes = host.available(h.virtual_bytes),
        .peak_rss = host.available(h.peak_rss),
        .cores = host.available(h.cores),
        .threads = host.available(h.threads),
        .descriptors = host.available(h.descriptors),
        .descriptor_limit = host.available(h.descriptor_limit),
        .load1 = host.available(h.load1),
        .load5 = host.available(h.load5),
        .load15 = host.available(h.load15),
        .active_requests = s3.active + management.active,
        .active_connections = app.runtime_metrics.connections.load(.monotonic),
    };
    if (app.data_root) |root| if (filesystem.read(root)) |capacity| {
        point.storage_total = capacity.total;
        point.storage_used = capacity.used;
        point.storage_available = capacity.available;
    };
    if (@import("../backend/runtime_workers.zig").read(io)) |workers| {
        point.workers = workers.count;
        point.workers_busy = workers.busy;
    }
    if (app.allocator_metrics) |a| {
        point.allocated_bytes = a.allocated_bytes.load(.monotonic);
        point.freed_bytes = a.freed_bytes.load(.monotonic);
        point.reallocations = a.resizes.load(.monotonic);
        point.heap = @floatFromInt(a.live.load(.monotonic));
        point.heap_peak = @floatFromInt(a.peak.load(.monotonic));
        point.allocations = a.allocations.load(.monotonic);
        point.frees = a.frees.load(.monotonic);
        point.allocation_failures = a.failures.load(.monotonic);
    }
    const registry = &app.monitor;
    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);
    const current: Baseline = .{ .host = h, .process = proc, .s3 = s3, .upload = up, .download = down, .time = now };
    const gauges = point;
    if (registry.previous) |prev| applyRates(&point, current, prev, @as(f64, @floatFromInt(app.config.monitoring_interval_seconds * 3)));
    registry.previous = current;
    registry.latest = point;
    // Counter deltas cover the entire history interval, including bursts between ticks.
    if (registry.ticks % (10 / app.config.monitoring_interval_seconds) == 0) {
        var historical = gauges;
        if (registry.history_baseline) |prev| applyRates(&historical, current, prev, 15);
        registry.history_baseline = current;
        if (registry.history.items.len < retention) {
            try registry.history.append(app.allocator, historical);
        } else {
            registry.history.items[registry.next] = historical;
            registry.next = (registry.next + 1) % retention;
        }
    }
    registry.diagnosis = analysis.analyze(registry.history.items, registry.next, point);
    registry.alert_engine.evaluate(point, registry.diagnosis, app.config.monitoring_interval_seconds);
    registry.ticks +%= 1;
}

pub fn restore(app: *Application) !void {
    const io = app.io orelse return error.Unavailable;
    const root = app.data_root orelse return error.Unavailable;
    const points = try store.load(app.allocator, root, io, std.Io.Clock.real.now(io).toSeconds());
    defer app.allocator.free(points);
    app.monitor.mutex.lockUncancelable(io);
    defer app.monitor.mutex.unlock(io);
    try app.monitor.history.appendSlice(app.allocator, points);
    // Never restore live gauges, counters or delta baselines from a previous process.
}

pub fn persist(app: *Application) !void {
    const io = app.io orelse return error.Unavailable;
    const root = app.data_root orelse return error.Unavailable;
    const now = std.Io.Clock.real.now(io).toSeconds();
    var points: std.ArrayList(Point) = .empty;
    defer points.deinit(app.allocator);
    {
        app.monitor.mutex.lockUncancelable(io);
        defer app.monitor.mutex.unlock(io);
        const count = app.monitor.history.items.len;
        for (0..count) |i| {
            const point = app.monitor.history.items[(app.monitor.next + i) % count];
            if (point.timestamp < now - 86400 or point.timestamp > now) continue;
            // Discard points superseded by a wall-clock rollback.
            while (points.items.len > 0 and points.items[points.items.len - 1].timestamp > point.timestamp) _ = points.pop();
            try points.append(app.allocator, point);
        }
    }
    try store.save(app.allocator, root, io, points.items);
    app.monitor.mutex.lockUncancelable(io);
    defer app.monitor.mutex.unlock(io);
    app.monitor.persistence = .{ .state = .healthy, .last_saved_at = now };
}

fn persistenceFailed(app: *Application) void {
    const io = app.io orelse return;
    app.monitor.mutex.lockUncancelable(io);
    defer app.monitor.mutex.unlock(io);
    app.monitor.persistence.state = .unavailable;
}

pub fn serve(app: *Application) void {
    const io = app.io orelse return;
    app.monitor.run_id = std.Io.Clock.real.now(io).toMilliseconds();
    restore(app) catch |err| {
        persistenceFailed(app);
        std.log.warn("Monitoring history could not be restored: {t}; collecting fresh samples", .{err});
    };
    if (app.data_root) |root| {
        app.policy_mutex.lockUncancelable(io);
        defer app.policy_mutex.unlock(io);
        const rules = analysis.load(app.allocator, root, io) catch |err| blk: {
            std.log.warn("Monitoring rules unavailable: {t}; using defaults", .{err});
            break :blk analysis.defaults;
        };
        app.monitor.mutex.lockUncancelable(io);
        app.monitor.alert_engine.reset(rules);
        app.monitor.mutex.unlock(io);
    }
    var last_save: ?std.Io.Timestamp = null;
    while (true) {
        collect(app) catch {};
        const now = std.Io.Clock.awake.now(io);
        if (last_save == null or last_save.?.durationTo(now).toSeconds() >= 60) {
            last_save = now;
            persist(app) catch |err| {
                persistenceFailed(app);
                std.log.warn("Monitoring history persistence failed: {t}; live monitoring remains available", .{err});
            };
        }
        (std.Io.Clock.Duration{ .clock = .awake, .raw = std.Io.Duration.fromSeconds(@intCast(app.config.monitoring_interval_seconds)) }).sleep(io) catch return;
    }
}

test "rates reject resets and sampling gaps; percentiles use actual histogram observations" {
    try std.testing.expectEqual(@as(?f64, 10), rate(30, 20, 1));
    try std.testing.expect(rate(10, 20, 1) == null);
    try std.testing.expect(rate(30, 20, 5) == null);
    var ops: runtime.Operations = .{};
    const before = ops.snapshot(std.testing.io);
    ops.begin(std.testing.io);
    ops.finish(std.testing.io, true, 7);
    try std.testing.expectEqual(@as(?f64, 10), percentile(ops.snapshot(std.testing.io), before, 0.95));
    try std.testing.expect(percentile(before, before, 0.95) == null);
}

pub fn prometheus(app: *Application, writer: *std.Io.Writer) !void {
    const io = app.io orelse return;
    app.monitor.mutex.lockUncancelable(io);
    const latest = app.monitor.latest;
    const alerts = app.monitor.alert_engine.alerts;
    app.monitor.mutex.unlock(io);
    if (latest) |point| {
        // Names carry units; unsupported values are omitted, never exported as zero.
        inline for (.{
            .{ "host_cpu", "host_cpu_percent" },                             .{ "process_cpu", "process_cpu_percent" },
            .{ "memory_used", "host_memory_used_bytes" },                    .{ "memory_total", "host_memory_total_bytes" },
            .{ "rss", "process_resident_memory_bytes" },                     .{ "virtual_bytes", "process_virtual_memory_bytes" },
            .{ "peak_rss", "process_peak_resident_memory_bytes" },           .{ "heap", "allocator_active_bytes" },
            .{ "heap_peak", "allocator_peak_bytes" },                        .{ "threads", "process_threads" },
            .{ "cores", "host_logical_cpus" },                               .{ "descriptors", "process_open_fds" },
            .{ "descriptor_limit", "process_max_fds" },                      .{ "storage_used", "filesystem_used_bytes" },
            .{ "storage_total", "filesystem_total_bytes" },                  .{ "storage_available", "filesystem_available_bytes" },
            .{ "disk_read", "process_disk_read_bytes_per_second" },          .{ "disk_write", "process_disk_write_bytes_per_second" },
            .{ "network_receive", "host_network_receive_bytes_per_second" }, .{ "network_transmit", "host_network_transmit_bytes_per_second" },
            .{ "load1", "host_load1" },                                      .{ "load5", "host_load5" },
            .{ "load15", "host_load15" },                                    .{ "workers", "runtime_workers" },
            .{ "workers_busy", "runtime_workers_busy" },
        }) |mapping| if (@field(point, mapping[0])) |value| {
            try writer.print("# TYPE zigfs_{s} gauge\nzigfs_{s} {d}\n", .{ mapping[1], mapping[1], value });
        };
        inline for (.{ .{ "allocations", "allocator_allocations_total" }, .{ "frees", "allocator_frees_total" }, .{ "allocation_failures", "allocator_failures_total" }, .{ "allocated_bytes", "allocator_allocated_bytes_total" }, .{ "freed_bytes", "allocator_freed_bytes_total" }, .{ "reallocations", "allocator_resizes_total" }, .{ "user_cpu_seconds", "process_user_cpu_seconds_total" }, .{ "kernel_cpu_seconds", "process_kernel_cpu_seconds_total" } }) |mapping| if (@field(point, mapping[0])) |value| {
            try writer.print("# TYPE zigfs_{s} counter\nzigfs_{s} {d}\n", .{ mapping[1], mapping[1], value });
        };
        try writer.print("# TYPE zigfs_monitor_sample_timestamp_seconds gauge\nzigfs_monitor_sample_timestamp_seconds {d}\n", .{point.timestamp});
    }
    try writer.print("# TYPE zigfs_object_upload_bytes_total counter\nzigfs_object_upload_bytes_total {d}\n# TYPE zigfs_object_download_bytes_total counter\nzigfs_object_download_bytes_total {d}\n# TYPE zigfs_http_connections gauge\nzigfs_http_connections {d}\n# TYPE zigfs_http_connections_rejected_total counter\nzigfs_http_connections_rejected_total {d}\n", .{
        app.runtime_metrics.uploaded_bytes.load(.monotonic), app.runtime_metrics.downloaded_bytes.load(.monotonic), app.runtime_metrics.connections.load(.monotonic), app.runtime_metrics.rejected_connections.load(.monotonic),
    });
    try writer.writeAll("# TYPE zigfs_monitor_alert_firing gauge\n# TYPE zigfs_lock_acquisitions_total counter\n# TYPE zigfs_lock_contentions_total counter\n# TYPE zigfs_lock_waiters gauge\n# TYPE zigfs_lock_wait_seconds_total counter\n# TYPE zigfs_lock_max_wait_seconds gauge\n");
    for (alerts) |alert| try writer.print("zigfs_monitor_alert_firing{{rule=\"{s}\"}} {d}\n", .{ @tagName(alert.id), @intFromBool(alert.state == .firing) });
    const locks = .{ app.state_mutex.snapshot(), app.policy_mutex.snapshot() };
    inline for (.{ "metadata", "identity" }, locks) |name, lock| {
        try writer.print("zigfs_lock_acquisitions_total{{lock=\"{s}\"}} {d}\nzigfs_lock_contentions_total{{lock=\"{s}\"}} {d}\nzigfs_lock_waiters{{lock=\"{s}\"}} {d}\nzigfs_lock_wait_seconds_total{{lock=\"{s}\"}} {d}\nzigfs_lock_max_wait_seconds{{lock=\"{s}\"}} {d}\n", .{ name, lock.acquisitions, name, lock.contentions, name, lock.waiters, name, @as(f64, @floatFromInt(lock.wait_ns)) / 1e9, name, @as(f64, @floatFromInt(lock.max_wait_ns)) / 1e9 });
    }
    try writer.writeAll("# TYPE zigfs_requests_total counter\n# TYPE zigfs_request_failures_total counter\n# TYPE zigfs_request_client_errors_total counter\n# TYPE zigfs_requests_active gauge\n# TYPE zigfs_request_duration_seconds histogram\n");
    try exportOperations(writer, "api", "s3", app.runtime_metrics.s3.snapshot(io));
    try exportOperations(writer, "api", "management", app.runtime_metrics.management.snapshot(io));
    try exportOperations(writer, "internal", "listings", app.runtime_metrics.listings.snapshot(io));
    for (&app.runtime_metrics.operations, 0..) |*operation, i| {
        const snapshot = operation.snapshot(io);
        if (snapshot.completed == 0 and snapshot.active == 0) continue;
        try exportOperations(writer, "operation", @tagName(@as(runtime.ApiOperation, @fromBackingInt(@intCast(i)))), snapshot);
    }
}

fn exportOperations(writer: *std.Io.Writer, scope: []const u8, name: []const u8, snapshot: runtime.OperationSnapshot) !void {
    inline for (.{ .{ "requests_total", "completed" }, .{ "request_failures_total", "failed" }, .{ "request_client_errors_total", "client_errors" }, .{ "requests_active", "active" } }) |mapping| {
        try writer.print("zigfs_{s}{{scope=\"{s}\",operation=\"{s}\"}} {d}\n", .{ mapping[0], scope, name, @field(snapshot, mapping[1]) });
    }
    var count: u64 = 0;
    for (runtime.bounds, 0..) |bound, i| {
        count += snapshot.histogram[i];
        try writer.print("zigfs_request_duration_seconds_bucket{{scope=\"{s}\",operation=\"{s}\",le=\"{d}\"}} {d}\n", .{ scope, name, @as(f64, @floatFromInt(bound)) / 1000, count });
    }
    try writer.print("zigfs_request_duration_seconds_bucket{{scope=\"{s}\",operation=\"{s}\",le=\"+Inf\"}} {d}\n", .{ scope, name, snapshot.completed });
    try writer.print("zigfs_request_duration_seconds_count{{scope=\"{s}\",operation=\"{s}\"}} {d}\n", .{ scope, name, snapshot.completed });
    try writer.print("zigfs_request_duration_seconds_sum{{scope=\"{s}\",operation=\"{s}\"}} {d}\n", .{ scope, name, @as(f64, @floatFromInt(snapshot.duration_ms)) / 1000 });
}

fn intervalRate(current: f64, previous: f64, elapsed: f64) ?f64 {
    const delta = rate(current, previous, 1) orelse return null;
    return delta / elapsed;
}

fn applyRates(point: *Point, current: Baseline, prev: Baseline, max_gap: f64) void {
    const elapsed = current.time - prev.time;
    if (elapsed <= 0 or elapsed > max_gap) return;
    const h = current.host;
    const proc = current.process;
    const s3 = current.s3;
    const up = current.upload;
    const down = current.download;
    if (intervalRate(h.cpu_total, prev.host.cpu_total, elapsed)) |total| {
        if (intervalRate(h.cpu_idle, prev.host.cpu_idle, elapsed)) |idle| {
            if (total > 0) point.host_cpu = std.math.clamp((total - idle) / total * 100, 0, 100);
        }
    }
    if (proc) |p| if (prev.process) |old| {
        if (intervalRate(p.cpu_seconds, old.cpu_seconds, elapsed)) |cpu| point.process_cpu = cpu * 100;
    };
    point.disk_read = intervalRate(h.read_bytes, prev.host.read_bytes, elapsed);
    point.disk_write = intervalRate(h.write_bytes, prev.host.write_bytes, elapsed);
    point.network_receive = intervalRate(h.receive_bytes, prev.host.receive_bytes, elapsed);
    point.network_transmit = intervalRate(h.transmit_bytes, prev.host.transmit_bytes, elapsed);
    point.upload = intervalRate(@floatFromInt(up), @floatFromInt(prev.upload), elapsed);
    point.download = intervalRate(@floatFromInt(down), @floatFromInt(prev.download), elapsed);
    point.qps = intervalRate(@floatFromInt(s3.completed), @floatFromInt(prev.s3.completed), elapsed);
    if (elapsed > 0 and elapsed <= max_gap and s3.completed >= prev.s3.completed) {
        const completed = s3.completed - prev.s3.completed;
        if (completed > 0) {
            point.error_percent = @as(f64, @floatFromInt(s3.failed - prev.s3.failed)) / @as(f64, @floatFromInt(completed)) * 100;
            point.client_error_percent = @as(f64, @floatFromInt(s3.client_errors - prev.s3.client_errors)) / @as(f64, @floatFromInt(completed)) * 100;
        }
        point.p50 = percentile(s3, prev.s3, 0.5);
        point.p95 = percentile(s3, prev.s3, 0.95);
        point.p99 = percentile(s3, prev.s3, 0.99);
    }
}

test "history queries remain ordered and bounded after ring rollover" {
    var registry: Registry = .{};
    defer registry.history.deinit(std.testing.allocator);
    for (0..retention) |i| try registry.history.append(std.testing.allocator, .{ .timestamp = @intCast(i * 10) });
    registry.history.items[0] = .{ .timestamp = retention * 10 };
    registry.next = 1;
    registry.latest = registry.history.items[0];
    const recent = try registry.read(std.testing.allocator, std.testing.io, 60);
    defer std.testing.allocator.free(recent.history);
    try std.testing.expectEqual(@as(usize, 7), recent.history.len);
    try std.testing.expectEqual(@as(i64, retention * 10), recent.history[6].timestamp);
    const full = try registry.read(std.testing.allocator, std.testing.io, 86400);
    defer std.testing.allocator.free(full.history);
    try std.testing.expect(full.history.len <= 361);
    for (full.history[1..], 0..) |p, i| try std.testing.expect(p.timestamp > full.history[i].timestamp);
}

test "history rates include short bursts between collection points and omit sampling gaps" {
    const h: host.Sample = std.mem.zeroes(host.Sample);
    var operations: runtime.Operations = .{};
    const before: Baseline = .{ .host = h, .process = null, .s3 = .{}, .upload = 0, .download = 0, .time = 0 };
    operations.begin(std.testing.io);
    operations.finishStatus(std.testing.io, 404, 7);
    const after: Baseline = .{ .host = h, .process = null, .s3 = operations.snapshot(std.testing.io), .upload = 100, .download = 0, .time = 10 };
    var p: Point = .{};
    applyRates(&p, after, before, 15);
    try std.testing.expectEqual(@as(?f64, 0.1), p.qps);
    try std.testing.expectEqual(@as(?f64, 10), p.p95);
    try std.testing.expectEqual(@as(?f64, 100), p.client_error_percent);
    try std.testing.expectEqual(@as(?f64, 10), p.upload);
    p = .{};
    applyRates(&p, after, before, 3);
    try std.testing.expect(p.qps == null);
}

test "Prometheus histogram buckets are cumulative and include overflow" {
    var operations: runtime.Operations = .{};
    operations.begin(std.testing.io);
    operations.finish(std.testing.io, true, 7);
    operations.begin(std.testing.io);
    operations.finish(std.testing.io, false, 31000);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try exportOperations(&output.writer, "api", "s3", operations.snapshot(std.testing.io));
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "le=\"0.01\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "le=\"+Inf\"} 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "zigfs_request_failures_total{scope=\"api\",operation=\"s3\"} 1") != null);
    try std.testing.expect(percentile(operations.snapshot(std.testing.io), .{}, 0.99) == null);
}
