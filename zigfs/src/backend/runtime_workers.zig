const std = @import("std");

pub const Sample = struct { count: usize, busy: usize };

/// Zig 0.17 Threaded adapter. Never cast an unknown Io implementation.
/// Linked worker records remain alive until Threaded.deinit, after sampler shutdown.
pub fn read(io: std.Io) ?Sample {
    var reference: std.Io.Threaded = undefined;
    if (io.vtable != reference.io().vtable) return null;
    const threaded: *std.Io.Threaded = @ptrCast(@alignCast(io.userdata orelse return null));
    threaded.mutex.lockUncancelable(io);
    defer threaded.mutex.unlock(io);
    var count: usize = 0;
    var next = threaded.worker_threads.load(.acquire);
    while (next) |worker| : (next = worker.next) count += 1;
    return .{ .count = count, .busy = threaded.busy_count };
}
