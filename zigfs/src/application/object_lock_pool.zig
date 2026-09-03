const std = @import("std");

pub const stripe_count: usize = 64;

pub const ObjectLockPool = struct {
    locks: [stripe_count]std.Io.RwLock = @splat(.init),

    pub fn get(
        self: *ObjectLockPool,
        bucket: []const u8,
        key: []const u8,
    ) *std.Io.RwLock {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(bucket);
        hasher.update(&.{0});
        hasher.update(key);
        return &self.locks[hasher.final() % stripe_count];
    }

    pub fn lockAll(self: *ObjectLockPool, io: std.Io) void {
        for (&self.locks) |*lock| lock.lockUncancelable(io);
    }

    pub fn unlockAll(self: *ObjectLockPool, io: std.Io) void {
        var index = self.locks.len;
        while (index > 0) {
            index -= 1;
            self.locks[index].unlock(io);
        }
    }
};

test "object lock pool deterministically selects a stripe" {
    var pool: ObjectLockPool = .{};
    try std.testing.expect(pool.get("bucket", "key") == pool.get("bucket", "key"));
}

test "all-stripe barrier waits for an active object reader" {
    const BarrierTask = struct {
        pool: *ObjectLockPool,
        io: std.Io,
        state_mutex: std.Io.Mutex = .init,
        state_changed: std.Io.Condition = .init,
        started: bool = false,
        acquired: bool = false,

        fn run(self: *@This()) void {
            self.state_mutex.lockUncancelable(self.io);
            self.started = true;
            self.state_changed.broadcast(self.io);
            self.state_mutex.unlock(self.io);

            self.pool.lockAll(self.io);
            self.state_mutex.lockUncancelable(self.io);
            self.acquired = true;
            self.state_changed.broadcast(self.io);
            self.state_mutex.unlock(self.io);
            self.pool.unlockAll(self.io);
        }
    };

    var pool: ObjectLockPool = .{};
    const reader = pool.get("project-assets", "large.bin");
    reader.lockSharedUncancelable(std.testing.io);
    var task: BarrierTask = .{ .pool = &pool, .io = std.testing.io };
    var future = try std.testing.io.concurrent(BarrierTask.run, .{&task});

    task.state_mutex.lockUncancelable(std.testing.io);
    while (!task.started) task.state_changed.waitUncancelable(std.testing.io, &task.state_mutex);
    try std.testing.expect(!task.acquired);
    task.state_mutex.unlock(std.testing.io);

    reader.unlockShared(std.testing.io);
    future.await(std.testing.io);
    try std.testing.expect(task.acquired);
}
