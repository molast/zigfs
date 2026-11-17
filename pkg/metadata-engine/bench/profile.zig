//! Opt-in diagnostics. Counters measure requested engine allocations, not RSS
//! or caller-owned read results. Keep the tracker at a stable address until close.
const std = @import("std");
const metadata = @import("metadata_engine");
const Alignment = std.mem.Alignment;

pub const Tracker = struct {
    backing: std.mem.Allocator,
    live: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),
    allocations: std.atomic.Value(usize) = .init(0),

    pub fn allocator(self: *Tracker) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn add(self: *Tracker, size: usize) void {
        const current = self.live.fetchAdd(size, .monotonic) + size;
        _ = self.peak.fetchMax(current, .monotonic);
    }

    fn change(self: *Tracker, old: usize, new: usize) void {
        if (new >= old) self.add(new - old) else {
            _ = self.live.fetchSub(old - new, .monotonic);
        }
    }

    fn alloc(context: *anyopaque, size: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *Tracker = @ptrCast(@alignCast(context));
        const result = self.backing.rawAlloc(size, alignment, ra) orelse return null;
        self.add(size);
        _ = self.allocations.fetchAdd(1, .monotonic);
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: Alignment, size: usize, ra: usize) bool {
        const self: *Tracker = @ptrCast(@alignCast(context));
        if (!self.backing.rawResize(memory, alignment, size, ra)) return false;
        self.change(memory.len, size);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: Alignment, size: usize, ra: usize) ?[*]u8 {
        const self: *Tracker = @ptrCast(@alignCast(context));
        const result = self.backing.rawRemap(memory, alignment, size, ra) orelse return null;
        self.change(memory.len, size);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
        const self: *Tracker = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, ra);
        _ = self.live.fetchSub(memory.len, .monotonic);
    }

    pub fn report(self: *Tracker, stage: []const u8, stats: ?metadata.Stats) void {
        std.debug.print("memory stage={s} engine_live={d} engine_peak={d} allocations={d} logical_bytes={d} rss_bytes={d}\n", .{
            stage,                             self.live.load(.monotonic),                             self.peak.load(.monotonic),
            self.allocations.load(.monotonic), if (stats) |state| state.live_bytes else @as(usize, 0), rss(),
        });
    }
};

pub const Context = struct {
    tracker: *Tracker,
    engine: *metadata.Engine,

    pub fn mark(self: *Context, stage: []const u8) void {
        self.tracker.report(stage, self.engine.stats());
    }

    pub fn hook(context: *anyopaque, point: metadata.Point) void {
        const self: *Context = @ptrCast(@alignCast(context));
        // These hooks run outside the engine state lock; stats may acquire it.
        if (point == .checkpoint_captured) self.mark("snapshot_copy_live");
        if (point == .snapshot_written) self.mark("snapshot_written");
    }
};

fn rss() usize {
    if (@import("builtin").os.tag == .macos) {
        var info: std.c.mach_task_basic_info = undefined;
        var count = std.c.MACH.TASK.BASIC.INFO_COUNT;
        if (std.c.task_info(std.c.mach_task_self(), std.c.MACH.TASK.BASIC.INFO, @ptrCast(&info), &count) == 0)
            return @intCast(info.resident_size);
    }
    // Unsupported platforms report unavailable as zero, never as an estimate.
    return 0;
}
