const std = @import("std");

pub const ApiOperation = @import("../transport/s3_protocol.zig").Operation;
pub const operation_count = @typeInfo(ApiOperation).@"enum".field_names.len;
pub const bounds = [_]u64{ 1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 30000 };

pub const OperationSnapshot = struct {
    uploaded_bytes: u64 = 0,
    downloaded_bytes: u64 = 0,
    active: u64 = 0,
    peak_active: u64 = 0,
    client_errors: u64 = 0,
    duration_ms: u64 = 0,
    histogram: [bounds.len + 1]u64 = @splat(0),
    completed: u64 = 0,
    failed: u64 = 0,
    last_duration_ms: ?u64 = null,
    last_succeeded: ?bool = null,
};

pub const Operations = struct {
    mutex: std.Io.Mutex = .init,
    value: OperationSnapshot = .{},

    pub fn payload(self: *Operations, io: std.Io, upload: u64, download: u64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.value.uploaded_bytes += upload;
        self.value.downloaded_bytes += download;
    }

    pub fn begin(self: *Operations, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.value.active += 1;
        self.value.peak_active = @max(self.value.peak_active, self.value.active);
    }

    pub fn finish(self: *Operations, io: std.Io, succeeded: bool, duration_ms: u64) void {
        self.finishStatus(io, if (succeeded) 200 else 500, duration_ms);
    }

    pub fn finishStatus(self: *Operations, io: std.Io, status: u16, duration_ms: u64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.value.active -= 1;
        self.value.duration_ms += duration_ms;
        var bucket: usize = 0;
        while (bucket < bounds.len and duration_ms > bounds[bucket]) : (bucket += 1) {}
        self.value.histogram[bucket] += 1;
        if (status >= 400 and status < 500) self.value.client_errors += 1;
        const succeeded = status < 500;
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
    uploaded_bytes: std.atomic.Value(u64) = .init(0),
    downloaded_bytes: std.atomic.Value(u64) = .init(0),
    connections: std.atomic.Value(u64) = .init(0),
    accepted_connections: std.atomic.Value(u64) = .init(0),
    rejected_connections: std.atomic.Value(u64) = .init(0),
    operations: [operation_count]Operations = @splat(.{}),
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
