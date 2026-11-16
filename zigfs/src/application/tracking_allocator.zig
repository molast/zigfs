const std = @import("std");
const Alignment = std.mem.Alignment;
const A = std.mem.Allocator;
const Counter = std.atomic.Value(u64);

/// Requested live bytes from the Application allocator; excludes libc and startup arena.
pub const TrackingAllocator = struct {
    pub const Site = struct { address: Counter = .init(0), allocations: Counter = .init(0), bytes: Counter = .init(0) };
    pub const Hotspot = struct { address: u64, allocations: u64, bytes: u64 };
    child: A,
    hotspots_enabled: std.atomic.Value(bool) = .init(false),
    sites: [64]Site = @splat(.{}),
    untracked_allocations: Counter = .init(0),

    live: Counter = .init(0),
    allocated_bytes: Counter = .init(0),
    freed_bytes: Counter = .init(0),
    peak: Counter = .init(0),
    allocations: Counter = .init(0),
    frees: Counter = .init(0),
    failures: Counter = .init(0),
    resizes: Counter = .init(0),

    fn record(self: *TrackingAllocator, address: usize, bytes: usize) void {
        if (!self.hotspots_enabled.load(.monotonic)) return;
        if (address == 0) {
            _ = self.untracked_allocations.fetchAdd(1, .monotonic);
            return;
        }
        for (&self.sites) |*site| {
            const key = site.address.load(.monotonic);
            if (key == address or (key == 0 and (site.address.cmpxchgStrong(0, address, .monotonic, .monotonic) orelse address) == address)) {
                _ = site.allocations.fetchAdd(1, .monotonic);
                _ = site.bytes.fetchAdd(bytes, .monotonic);
                return;
            }
        }
        _ = self.untracked_allocations.fetchAdd(1, .monotonic);
    }
    pub fn hotspots(self: *TrackingAllocator) [64]Hotspot {
        var result: [64]Hotspot = undefined;
        for (&result, &self.sites) |*out, *site| out.* = .{ .address = site.address.load(.monotonic), .allocations = site.allocations.load(.monotonic), .bytes = site.bytes.load(.monotonic) };
        return result;
    }

    pub fn allocator(self: *TrackingAllocator) A {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn grow(self: *TrackingAllocator, n: usize) void {
        _ = self.allocated_bytes.fetchAdd(n, .monotonic);
        const current = self.live.fetchAdd(n, .monotonic) + n;
        _ = self.peak.fetchMax(current, .monotonic);
    }
    fn change(self: *TrackingAllocator, old: usize, new: usize) void {
        if (new >= old) self.grow(new - old) else {
            _ = self.live.fetchSub(old - new, .monotonic);
            _ = self.freed_bytes.fetchAdd(old - new, .monotonic);
        }
        _ = self.resizes.fetchAdd(1, .monotonic);
    }
    fn alloc(ctx: *anyopaque, n: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.rawAlloc(n, alignment, ra) orelse {
            _ = self.failures.fetchAdd(1, .monotonic);
            return null;
        };
        self.grow(n);
        self.record(ra, n);
        _ = self.allocations.fetchAdd(1, .monotonic);
        return result;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, n: usize, ra: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, n, ra)) return false;
        self.change(memory.len, n);
        if (n > memory.len) self.record(ra, n - memory.len);
        return true;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.rawRemap(memory, alignment, n, ra) orelse return null;
        self.change(memory.len, n);
        if (n > memory.len) self.record(ra, n - memory.len);
        return result;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ra);
        _ = self.live.fetchSub(memory.len, .monotonic);
        _ = self.freed_bytes.fetchAdd(memory.len, .monotonic);
        _ = self.frees.fetchAdd(1, .monotonic);
    }
};

test "allocator tracks live requested bytes across realloc and free" {
    var tracker: TrackingAllocator = .{ .child = std.testing.allocator };
    const a = tracker.allocator();
    var bytes = try a.alloc(u8, 128);
    try std.testing.expectEqual(@as(u64, 128), tracker.live.load(.monotonic));
    bytes = try a.realloc(bytes, 1024);
    try std.testing.expectEqual(@as(u64, 1024), tracker.live.load(.monotonic));
    a.free(bytes);
    try std.testing.expectEqual(@as(u64, 0), tracker.live.load(.monotonic));
    try std.testing.expect(tracker.peak.load(.monotonic) >= 1024);
}

test "failed allocations do not increase live heap" {
    var buffer: [8]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    var tracker: TrackingAllocator = .{ .child = fixed.allocator() };
    try std.testing.expectError(error.OutOfMemory, tracker.allocator().alloc(u8, 64));
    try std.testing.expectEqual(@as(u64, 0), tracker.live.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), tracker.failures.load(.monotonic));
}

test "cumulative allocation bytes balance after realloc shrink and release" {
    var tracker: TrackingAllocator = .{ .child = std.testing.allocator };
    const a = tracker.allocator();
    var bytes = try a.alloc(u8, 128);
    bytes = try a.realloc(bytes, 2048);
    bytes = try a.realloc(bytes, 64);
    try std.testing.expectEqual(tracker.live.load(.monotonic), tracker.allocated_bytes.load(.monotonic) - tracker.freed_bytes.load(.monotonic));
    a.free(bytes);
    try std.testing.expectEqual(tracker.allocated_bytes.load(.monotonic), tracker.freed_bytes.load(.monotonic));
}

test "hotspots are opt-in and bounded, preserving counts when disabled" {
    var tracker: TrackingAllocator = .{ .child = std.testing.allocator };
    tracker.record(123, 64);
    try std.testing.expectEqual(@as(u64, 0), tracker.hotspots()[0].allocations);
    tracker.hotspots_enabled.store(true, .monotonic);
    for (1..66) |address| tracker.record(address, 128);
    tracker.record(1, 32);
    tracker.record(0, 32);
    try std.testing.expectEqual(@as(u64, 2), tracker.untracked_allocations.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 160), tracker.hotspots()[0].bytes);
    tracker.hotspots_enabled.store(false, .monotonic);
    tracker.record(1, 64);
    try std.testing.expectEqual(@as(u64, 160), tracker.hotspots()[0].bytes);
}
