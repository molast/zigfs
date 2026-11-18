//! Intentionally faulty child process. Never import into the server or test runner.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedProbeMode;
    const mode = args[1];
    var checked: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{
        .stack_trace_frames = 16,
        .check_write_after_free = true,
    });
    const a = checked.allocator();
    // Keep a second allocation alive so the small-allocation bucket is not unmapped
    // before delayed write-after-free checking at teardown.
    const keeper = try a.alloc(u8, 64);
    const bytes = try a.alloc(u8, 64);
    @memset(bytes, 42);
    const raw: [*]volatile u8 = bytes.ptr;
    if (std.mem.eql(u8, mode, "clean")) {
        a.free(bytes);
    } else if (std.mem.eql(u8, mode, "leak")) {
        // Checked at teardown; do not free this allocation.
    } else if (std.mem.eql(u8, mode, "double-free")) {
        a.free(bytes);
        a.free(bytes);
    } else if (std.mem.eql(u8, mode, "use-after-free")) {
        a.free(bytes);
        raw[0] = 42;
    } else if (std.mem.eql(u8, mode, "buffer-overflow")) {
        // Bypass slice bounds checks to exercise allocator footer validation.
        // Flip the existing byte: writing zero can leave a zero footer byte unchanged.
        raw[64] ^= 0xff;
        a.free(bytes);
    } else return error.UnknownProbeMode;
    a.free(keeper);
    const leaks = checked.deinit();
    if (leaks != 0) return error.DiagnosticLeakDetected;
    std.debug.print("probe completed without detected faults\n", .{});
}
