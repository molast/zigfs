const std = @import("std");
const Counter = std.atomic.Value(u64);

/// Instruments application locks only; no dependency on runtime mutex internals.
pub const Mutex = struct {
    inner: std.Io.Mutex = .init,
    acquisitions: Counter = .init(0),
    contentions: Counter = .init(0),
    waiters: Counter = .init(0),
    wait_ns: Counter = .init(0),
    max_wait_ns: Counter = .init(0),
    pub const init: Mutex = .{};
    pub const Snapshot = struct { acquisitions: u64, contentions: u64, waiters: u64, wait_ns: u64, max_wait_ns: u64 };

    pub fn lockUncancelable(self: *Mutex, io: std.Io) void {
        if (!self.inner.tryLock()) {
            _ = self.contentions.fetchAdd(1, .monotonic);
            _ = self.waiters.fetchAdd(1, .monotonic);
            const start = std.Io.Clock.awake.now(io);
            self.inner.lockUncancelable(io);
            const elapsed: u64 = @intCast(@max(0, start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds()));
            _ = self.wait_ns.fetchAdd(elapsed, .monotonic);
            _ = self.max_wait_ns.fetchMax(elapsed, .monotonic);
            _ = self.waiters.fetchSub(1, .monotonic);
        }
        _ = self.acquisitions.fetchAdd(1, .monotonic);
    }
    pub fn unlock(self: *Mutex, io: std.Io) void {
        self.inner.unlock(io);
    }
    pub fn snapshot(self: *Mutex) Snapshot {
        return .{ .acquisitions = self.acquisitions.load(.monotonic), .contentions = self.contentions.load(.monotonic), .waiters = self.waiters.load(.monotonic), .wait_ns = self.wait_ns.load(.monotonic), .max_wait_ns = self.max_wait_ns.load(.monotonic) };
    }
};

test "uncontended application locks record acquisitions without fabricated waiting" {
    var mutex: Mutex = .init;
    mutex.lockUncancelable(std.testing.io);
    mutex.unlock(std.testing.io);
    try std.testing.expectEqual(@as(u64, 1), mutex.snapshot().acquisitions);
    try std.testing.expectEqual(@as(u64, 0), mutex.snapshot().contentions);
}

test "contended application lock records a real waiter and measured delay" {
    const Task = struct {
        fn run(mutex: *Mutex) void {
            mutex.lockUncancelable(std.testing.io);
            mutex.unlock(std.testing.io);
        }
    };
    const io = std.testing.io;
    var mutex: Mutex = .init;
    mutex.lockUncancelable(io);
    var future = io.concurrent(Task.run, .{&mutex}) catch |err| {
        mutex.unlock(io);
        return err;
    };
    var observed = false;
    for (0..1000) |_| {
        if (mutex.snapshot().waiters == 1) {
            observed = true;
            break;
        }
        (std.Io.Clock.Duration{ .clock = .awake, .raw = std.Io.Duration.fromMilliseconds(1) }).sleep(io) catch {};
    }
    mutex.unlock(io);
    future.await(io);
    try std.testing.expect(observed);
    const snapshot = mutex.snapshot();
    try std.testing.expectEqual(@as(u64, 2), snapshot.acquisitions);
    try std.testing.expectEqual(@as(u64, 1), snapshot.contentions);
    try std.testing.expectEqual(@as(u64, 0), snapshot.waiters);
    try std.testing.expect(snapshot.wait_ns > 0);
    try std.testing.expectEqual(snapshot.wait_ns, snapshot.max_wait_ns);
}
