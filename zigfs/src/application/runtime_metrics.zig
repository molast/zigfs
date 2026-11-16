const std = @import("std");

pub const OperationSnapshot = struct {
    active: u64 = 0,
    completed: u64 = 0,
    failed: u64 = 0,
    last_duration_ms: ?u64 = null,
    last_succeeded: ?bool = null,
};

pub const Operations = struct {
    mutex: std.Io.Mutex = .init,
    value: OperationSnapshot = .{},

    pub fn begin(self: *Operations, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.value.active += 1;
    }

    pub fn finish(self: *Operations, io: std.Io, succeeded: bool, duration_ms: u64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.value.active -= 1;
        self.value.completed += 1;
        if (!succeeded) self.value.failed += 1;
        self.value.last_duration_ms = duration_ms;
        self.value.last_succeeded = succeeded;
    }

    pub fn snapshot(self: *Operations, io: std.Io) OperationSnapshot {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.value;
    }
};

pub const Runtime = struct {
    connections: std.atomic.Value(u64) = .init(0),
    accepted_connections: std.atomic.Value(u64) = .init(0),
    rejected_connections: std.atomic.Value(u64) = .init(0),
    s3: Operations = .{},
    management: Operations = .{},
    listings: Operations = .{},
};

test "operation metrics retain concurrent activity and real completion outcomes" {
    var operations: Operations = .{};
    const io = std.testing.io;
    try std.testing.expect(operations.snapshot(io).last_succeeded == null);
    operations.begin(io);
    operations.begin(io);
    operations.finish(io, false, 7);
    const partial = operations.snapshot(io);
    try std.testing.expectEqual(@as(u64, 1), partial.active);
    try std.testing.expectEqual(@as(u64, 1), partial.failed);
    operations.finish(io, true, 2);
    const final = operations.snapshot(io);
    try std.testing.expectEqual(@as(u64, 0), final.active);
    try std.testing.expectEqual(@as(u64, 2), final.completed);
    try std.testing.expectEqual(@as(?u64, 2), final.last_duration_ms);
    try std.testing.expectEqual(@as(?bool, true), final.last_succeeded);
}
