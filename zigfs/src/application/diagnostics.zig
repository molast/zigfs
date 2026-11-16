const std = @import("std");
const Application = @import("mod.zig").Application;
const filesystem = @import("../backend/filesystem_capacity.zig");
const metrics = @import("runtime_metrics.zig");

pub const Snapshot = struct {
    storage: struct {
        state: enum { online, offline, unknown },
        online: ?u32,
        offline: ?u32,
        read_only: ?bool,
    },
    metadata: struct {
        ready: bool,
        buckets: ?usize,
        objects: ?usize,
        directories: ?usize,
        listings: metrics.OperationSnapshot,
    },
    http: struct {
        active_connections: u64,
        accepted_connections: u64,
        rejected_connections: u64,
        s3: metrics.OperationSnapshot,
        management: metrics.OperationSnapshot,
    },
};

// Reports the opened data filesystem and actual in-memory index, not host disk inventory.
pub fn read(app: *Application) ?Snapshot {
    const io = app.io orelse return null;
    const volume = if (app.data_root) |root| filesystem.health(root) else filesystem.Health{ .online = false, .read_only = null };
    const online = if (volume) |value| value.online else null;
    app.state_mutex.lockUncancelable(io);
    const ready = app.metadata_index != null and app.recovery_state.isReady();
    const buckets = if (app.metadata_index) |*index| index.buckets.items.len else null;
    const objects = if (app.metadata_index) |*index| index.objects.items.len else null;
    const directories = if (app.metadata_index) |*index| index.directories.items.len else null;
    app.state_mutex.unlock(io);
    return .{
        .storage = .{
            .state = if (online) |value| (if (value) .online else .offline) else .unknown,
            .online = if (online) |value| @intFromBool(value) else null,
            .offline = if (online) |value| @intFromBool(!value) else null,
            .read_only = if (volume) |value| value.read_only else null,
        },
        .metadata = .{ .ready = ready, .buckets = buckets, .objects = objects, .directories = directories, .listings = app.runtime_metrics.listings.snapshot(io) },
        .http = .{
            .active_connections = app.runtime_metrics.connections.load(.monotonic),
            .accepted_connections = app.runtime_metrics.accepted_connections.load(.monotonic),
            .rejected_connections = app.runtime_metrics.rejected_connections.load(.monotonic),
            .s3 = app.runtime_metrics.s3.snapshot(io),
            .management = app.runtime_metrics.management.snapshot(io),
        },
    };
}

test "diagnostics distinguish missing, ready and recovery-required index state" {
    var app = Application.initWithAllocator(.{}, std.testing.allocator);
    try std.testing.expect(read(&app) == null);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    app.io = std.testing.io;
    app.data_root = tmp.dir;
    const before = read(&app).?;
    try std.testing.expect(!before.metadata.ready);
    try std.testing.expect(before.metadata.buckets == null);
    app.metadata_index = @import("../metadata/index.zig").MetadataIndex.init(std.testing.allocator);
    defer app.metadata_index.?.deinit();
    app.recovery_state.markReady();
    const ready = read(&app).?;
    try std.testing.expect(ready.metadata.ready);
    try std.testing.expectEqual(@as(?usize, 0), ready.metadata.objects);
    try std.testing.expect(ready.metadata.listings.last_succeeded == null);
    app.recovery_state.markRequired(error.CorruptRecord);
    try std.testing.expect(!read(&app).?.metadata.ready);
    app.data_root = null;
    try std.testing.expectEqual(@as(?u32, 1), read(&app).?.storage.offline);
}
