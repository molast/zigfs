const std = @import("std");

/// Optional aggregate diagnostics. Updated under the owning engine/runtime lock.
pub const Timing = struct {
    count: u64 = 0,
    total_ns: u64 = 0,
    max_ns: u64 = 0,

    pub fn record(self: *Timing, io: std.Io, start: ?std.Io.Timestamp) void {
        if (start) |value| {
            const elapsed = value.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
            const ns: u64 = @intCast(@max(0, elapsed));
            self.count +|= 1;
            self.total_ns +|= ns;
            self.max_ns = @max(self.max_ns, ns);
        }
    }
};

pub fn begin(enabled: bool, io: std.Io) ?std.Io.Timestamp {
    return if (enabled) std.Io.Clock.awake.now(io) else null;
}
