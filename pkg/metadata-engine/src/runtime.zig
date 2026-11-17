const std = @import("std");
const timing = @import("timing.zig");
const engine_module = @import("engine.zig");
const port = @import("repository.zig");
const Type = @import("types.zig").Type;
const codec = @import("codec.zig");

pub const Options = struct {
    max_pending: usize = 1024,
    max_group_transactions: usize = 64,
    max_group_bytes: usize = 4 * 1024 * 1024,
    group_delay_us: u32 = 100,
    /// Start promptly when this many requests are ready; never exceeds group cap.
    group_ready_transactions: usize = 8,
    /// A lone request adds at most this delay. Zero makes sparse writes immediate.
    group_low_load_delay_us: u32 = 25,
    /// Zero disables the maintenance worker; manual checkpoints still work.
    checkpoint_interval_ms: u32 = 1000,
    /// Runtime clamps this target to half the Engine WAL quota.
    checkpoint_min_wal_bytes: u64 = 32 * 1024 * 1024,
    /// Adapt to live data size and previous maintenance cost. Pressure bypasses cooldown.
    adaptive_checkpoints: bool = true,
    checkpoint_cooldown_multiplier: u32 = 4,
};

pub const Stats = struct {
    queue_wait: timing.Timing = .{},
    group_collect: timing.Timing = .{},
    max_group_size: usize = 0,
    queued: usize = 0,
    queued_bytes: u64 = 0,
    ready_groups: u64 = 0,
    in_flight: usize = 0,
    peak_pending: usize = 0,
    groups: u64 = 0,
    transactions: u64 = 0,
    rejected: u64 = 0,
    checkpoint_failures: u64 = 0,
    /// Most recent checkpoint or cleanup-retry error, cleared on success.
    last_checkpoint_error: ?anyerror = null,
    effective_checkpoint_wal_bytes: u64 = 0,
    checkpoint_target_wal_bytes: u64 = 0,
    checkpoint_deferred: u64 = 0,
    last_checkpoint_duration_ns: u64 = 0,
};

pub const Point = enum { before_collect, before_group, after_group, after_notify };

/// Diagnostic callback; called without the queue or engine state locks. It must
/// not synchronously submit work to this Runtime (the writer invokes it).
pub const Hook = struct {
    context: *anyopaque,
    call: *const fn (*anyopaque, Point, usize) void,
};

const Request = struct {
    enqueued_at: ?std.Io.Timestamp = null,
    mutations: []const engine_module.Mutation,
    bytes: usize,
    result: port.Error!u64 = error.Unavailable,
    next: ?*Request = null,
    done: std.Io.Event = .unset,
};

/// Optional FIFO/group-commit and maintenance service. Keep Engine and Runtime
/// at stable addresses, start once, stop before destroying Engine. Mutations
/// are borrowed until commit returns. Accepted requests are drained on stop.
/// The engine allocator must support concurrent checkpoint/writer allocation.
pub const Runtime = struct {
    engine: *engine_module.Engine,
    options: Options = .{},
    hook: ?Hook = null,
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    maintenance_stop: std.Io.Event = .unset,
    head: ?*Request = null,
    tail: ?*Request = null,
    started: bool = false,
    stopping: bool = false,
    counters: Stats = .{},
    writer: ?std.Io.Future(void) = null,
    maintenance: ?std.Io.Future(void) = null,

    pub fn start(self: *Runtime) !void {
        if (self.started or self.stopping) return error.AlreadyStarted;
        if (self.engine.options.read_only) return error.ReadOnly;
        if (self.options.max_pending == 0 or self.options.max_pending > 65535 or
            self.options.max_group_transactions == 0 or self.options.max_group_transactions > 128 or
            self.options.max_group_bytes == 0 or self.options.group_delay_us > 1_000_000 or
            self.options.group_ready_transactions == 0 or self.options.group_ready_transactions > 128 or
            self.options.group_low_load_delay_us > 1_000_000 or
            self.options.checkpoint_cooldown_multiplier > 1000) return error.InvalidOptions;
        if (self.options.checkpoint_interval_ms != 0) {
            // Two file headers and the smallest legal one-key transaction must
            // fit. Otherwise automatic maintenance cannot enable even one write.
            const minimum_quota = 160 + codec.header_length + codec.checksum_length + 12 + 1;
            if (self.engine.options.max_wal_bytes < minimum_quota) return error.InvalidOptions;
            self.counters.effective_checkpoint_wal_bytes = @min(
                self.options.checkpoint_min_wal_bytes,
                self.engine.options.max_wal_bytes / 2,
            );
        }
        self.started = true;
        errdefer self.stop();
        self.writer = try self.engine.io.concurrent(writerMain, .{self});
        if (self.options.checkpoint_interval_ms != 0) {
            self.maintenance = try self.engine.io.concurrent(maintenanceMain, .{self});
        }
    }

    pub fn stop(self: *Runtime) void {
        const io = self.engine.io;
        self.mutex.lockUncancelable(io);
        self.stopping = true;
        self.wake.broadcast(io);
        self.mutex.unlock(io);
        self.maintenance_stop.set(io);
        if (self.writer) |*future| future.await(io);
        if (self.maintenance) |*future| future.await(io);
        self.writer = null;
        self.maintenance = null;
    }

    pub fn stats(self: *Runtime) Stats {
        self.mutex.lockUncancelable(self.engine.io);
        defer self.mutex.unlock(self.engine.io);
        return self.counters;
    }

    pub fn commit(self: *Runtime, mutations: []const engine_module.Mutation) port.Error!u64 {
        if (mutations.len == 0 or mutations.len > codec.Limits.max_mutations) return error.PayloadTooLarge;
        var bytes: usize = codec.header_length + codec.checksum_length;
        for (mutations) |mutation| {
            if (!codec.validKey(mutation.key)) return error.InvalidKey;
            if (mutation.payload.len > codec.Limits.max_frame_bytes) return error.PayloadTooLarge;
            bytes += 12 + mutation.key.len + mutation.payload.len;
            if (bytes > codec.Limits.max_frame_bytes) return error.PayloadTooLarge;
        }
        var request: Request = .{ .mutations = mutations, .bytes = bytes };
        const io = self.engine.io;
        self.mutex.lockUncancelable(io);
        if (!self.started or self.stopping) {
            self.mutex.unlock(io);
            return error.Unavailable;
        }
        const pending = self.counters.queued + self.counters.in_flight;
        if (pending >= self.options.max_pending) {
            self.counters.rejected += 1;
            self.mutex.unlock(io);
            return error.Busy;
        }
        request.enqueued_at = timing.begin(self.engine.options.diagnostics, io);
        if (self.tail) |tail| tail.next = &request else self.head = &request;
        self.tail = &request;
        self.counters.queued += 1;
        self.counters.queued_bytes += bytes;
        self.counters.peak_pending = @max(self.counters.peak_pending, pending + 1);
        self.wake.signal(io);
        self.mutex.unlock(io);
        // Once enqueued, cancellation cannot invalidate this stack request.
        request.done.waitUncancelable(io);
        return request.result;
    }

    fn writerMain(self: *Runtime) void {
        const io = self.engine.io;
        while (true) {
            self.mutex.lockUncancelable(io);
            while (self.head == null and !self.stopping) self.wake.waitUncancelable(io, &self.mutex);
            if (self.head == null and self.stopping) {
                self.mutex.unlock(io);
                return;
            }
            if (self.hook != null) {
                self.mutex.unlock(io);
                self.at(.before_collect, 0);
                self.mutex.lockUncancelable(io);
            }
            const collect_start = timing.begin(self.engine.options.diagnostics, io);
            // Fixed deadline; neither new arrivals nor spurious wakeups extend
            // it. Ready batches skip the delay, sparse requests use a short cap.
            const delay_us = collectionDelay(self.options, self.counters.queued);
            const ready_count = @min(self.options.group_ready_transactions, self.options.max_group_transactions);
            if (delay_us != 0 and !self.stopping) {
                const deadline = (std.Io.Timeout{ .duration = .{
                    .raw = .fromMicroseconds(delay_us),
                    .clock = .awake,
                } }).toDeadline(io);
                while (self.counters.queued < ready_count and
                    self.counters.queued_bytes < self.options.max_group_bytes and !self.stopping)
                {
                    self.wake.waitTimeout(io, &self.mutex, deadline) catch break;
                }
            }
            if (self.counters.queued >= ready_count or self.counters.queued_bytes >= self.options.max_group_bytes) {
                self.counters.ready_groups += 1;
            }
            var requests: [128]*Request = undefined;
            var items: [128]engine_module.GroupItem = undefined;
            var count: usize = 0;
            var bytes: usize = 0;
            while (self.head) |request| {
                if (count == self.options.max_group_transactions or
                    (count != 0 and request.bytes > self.options.max_group_bytes -| bytes)) break;
                self.counters.queue_wait.record(io, request.enqueued_at);
                requests[count] = request;
                items[count] = .{ .mutations = request.mutations };
                self.head = request.next;
                count += 1;
                bytes += request.bytes;
            }
            if (self.head == null) self.tail = null;
            self.counters.group_collect.record(io, collect_start);
            self.counters.max_group_size = @max(self.counters.max_group_size, count);
            self.counters.queued -= count;
            self.counters.queued_bytes -= bytes;
            self.counters.in_flight += count;
            self.mutex.unlock(io);
            self.at(.before_group, count);
            self.engine.commitGroup(items[0..count]);
            self.at(.after_group, count);
            self.mutex.lockUncancelable(io);
            self.counters.in_flight -= count;
            self.counters.groups += 1;
            self.counters.transactions += count;
            self.mutex.unlock(io);
            for (requests[0..count], items[0..count], 0..) |request, item, index| {
                request.result = item.result;
                request.done.set(io); // Last access: caller may now unwind its stack.
                self.at(.after_notify, index + 1);
            }
        }
    }

    fn maintenanceMain(self: *Runtime) void {
        const io = self.engine.io;
        var last_finished: ?std.Io.Timestamp = null;
        var last_duration_ns: u64 = 0;
        while (!self.maintenance_stop.isSet()) {
            self.maintenance_stop.waitTimeout(io, .{ .duration = .{
                .raw = .fromMilliseconds(self.options.checkpoint_interval_ms),
                .clock = .awake,
            } }) catch {};
            if (self.maintenance_stop.isSet()) return;
            var state = self.engine.stats();
            if (state.recovery_required) continue;
            if (state.cleanup_pending) {
                self.engine.retryCleanup() catch |err| {
                    self.recordMaintenanceResult(err);
                    continue;
                };
                self.recordMaintenanceResult(null);
                state = self.engine.stats();
            }
            if (state.recovery_required or state.generation == state.checkpoint_generation) continue;
            const elapsed_ns: u64 = if (last_finished) |finished|
                @intCast(@max(0, finished.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds()))
            else
                std.math.maxInt(u64);
            const target = checkpointTarget(self.options, state.live_bytes, self.engine.options.max_wal_bytes);
            const due = maintenanceDue(self.options, state, self.engine.options.max_wal_bytes, elapsed_ns, last_duration_ns);
            self.mutex.lockUncancelable(io);
            self.counters.checkpoint_target_wal_bytes = target;
            if (!due) self.counters.checkpoint_deferred += 1;
            self.mutex.unlock(io);
            if (!due) continue;
            const checkpoint_started = std.Io.Clock.awake.now(io);
            var failure: ?anyerror = null;
            self.engine.checkpoint() catch |err| {
                failure = err;
            };
            last_finished = std.Io.Clock.awake.now(io);
            last_duration_ns = @intCast(@max(0, checkpoint_started.durationTo(last_finished.?).toNanoseconds()));
            self.mutex.lockUncancelable(io);
            self.counters.last_checkpoint_duration_ns = last_duration_ns;
            self.mutex.unlock(io);
            self.recordMaintenanceResult(failure);
        }
    }

    fn recordMaintenanceResult(self: *Runtime, failure: ?anyerror) void {
        self.mutex.lockUncancelable(self.engine.io);
        defer self.mutex.unlock(self.engine.io);
        self.counters.last_checkpoint_error = failure;
        if (failure != null) self.counters.checkpoint_failures += 1;
    }

    fn at(self: *Runtime, point: Point, count: usize) void {
        if (self.hook) |hook| hook.call(hook.context, point, count);
    }

    pub fn interface(self: *Runtime) port.MetadataRepository {
        return .{ .context = self, .vtable = &.{ .get = get, .put = put, .tombstone = tombstone, .scan = scan } };
    }

    fn get(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        record_type: Type,
        key: []const u8,
    ) port.Error!port.Record {
        const self: *Runtime = @ptrCast(@alignCast(context));
        return self.engine.interface().get(allocator, record_type, key);
    }

    fn put(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        record_type: Type,
        key: []const u8,
        expected: port.ExpectedGeneration,
        payload: []const u8,
    ) port.Error!u64 {
        _ = allocator;
        const self: *Runtime = @ptrCast(@alignCast(context));
        return self.commit(&.{.{ .record_type = record_type, .key = key, .expected = expected, .payload = payload }});
    }

    fn tombstone(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        record_type: Type,
        key: []const u8,
        expected: port.ExpectedGeneration,
    ) port.Error!u64 {
        _ = allocator;
        const self: *Runtime = @ptrCast(@alignCast(context));
        return self.commit(&.{.{ .record_type = record_type, .key = key, .expected = expected, .tombstone = true }});
    }

    fn scan(context: *anyopaque, allocator: std.mem.Allocator, record_type: Type) port.Error!port.ScanResult {
        const self: *Runtime = @ptrCast(@alignCast(context));
        return self.engine.interface().scan(allocator, record_type);
    }
};

fn checkpointTarget(options: Options, live_bytes: usize, quota: u64) u64 {
    const minimum = @min(options.checkpoint_min_wal_bytes, quota / 2);
    return if (options.adaptive_checkpoints) @min(quota / 2, @max(minimum, live_bytes)) else minimum;
}

/// Dirty bytes are write volume, not a distinct-key estimate. Either enough WAL
/// or dirty volume can trigger maintenance. Pressure always bypasses throttling.
fn maintenanceDue(options: Options, state: @import("options.zig").Stats, quota: u64, elapsed_ns: u64, duration_ns: u64) bool {
    if (state.generation == state.checkpoint_generation or state.recovery_required) return false;
    if (state.wal_pressure or state.wal_bytes >= quota - quota / 4) return true;
    const minimum = @min(options.checkpoint_min_wal_bytes, quota / 2);
    if (state.wal_bytes < minimum) return false;
    if (!options.adaptive_checkpoints) return true;
    if (elapsed_ns < duration_ns *| options.checkpoint_cooldown_multiplier) return false;
    return state.wal_bytes >= checkpointTarget(options, state.live_bytes, quota) or
        state.dirty_bytes >= state.live_bytes / 2;
}

test "adaptive checkpoint policy bounds frequency without starving quota pressure" {
    const std_testing = std.testing;
    const options: Options = .{ .checkpoint_min_wal_bytes = 100 };
    var state: @import("options.zig").Stats = .{
        .generation = 2,
        .checkpoint_generation = 1,
        .wal_bytes = 150,
        .live_bytes = 1000,
        .dirty_bytes = 100,
    };
    try std_testing.expect(!maintenanceDue(options, state, 2000, 1000, 0));
    state.dirty_bytes = 500;
    try std_testing.expect(maintenanceDue(options, state, 2000, 1000, 0));
    try std_testing.expect(!maintenanceDue(options, state, 2000, 1000, 1000));
    state.wal_pressure = true;
    try std_testing.expect(maintenanceDue(options, state, 2000, 0, 1000));
    state.wal_pressure = false;
    state.wal_bytes = 1500;
    try std_testing.expect(maintenanceDue(options, state, 2000, 0, 1000));
    try std_testing.expectEqual(@as(u64, 250), checkpointTarget(options, 1000, 500));
}

fn collectionDelay(options: Options, queued: usize) u32 {
    if (queued >= @min(options.group_ready_transactions, options.max_group_transactions)) return 0;
    return if (queued <= 1) @min(options.group_delay_us, options.group_low_load_delay_us) else options.group_delay_us;
}

test "group collection respects ready threshold sparse cap and configured maximum" {
    const options: Options = .{};
    try std.testing.expectEqual(@as(u32, 25), collectionDelay(options, 1));
    try std.testing.expectEqual(@as(u32, 100), collectionDelay(options, 2));
    try std.testing.expectEqual(@as(u32, 0), collectionDelay(options, 8));
    try std.testing.expectEqual(@as(u32, 0), collectionDelay(.{ .max_group_transactions = 1 }, 1));
    try std.testing.expectEqual(@as(u32, 5), collectionDelay(.{ .group_delay_us = 5 }, 1));
    try std.testing.expectEqual(@as(u32, 0), collectionDelay(.{ .group_delay_us = 0 }, 1));
}
