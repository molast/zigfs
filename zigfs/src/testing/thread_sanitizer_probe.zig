//! Positive/negative controls for actual Zig TSan instrumentation.
const std = @import("std");

const Task = struct {
    io: std.Io,
    clean: bool,
    ready: std.atomic.Value(u32) = .init(0),
    mutex: std.Io.Mutex = .init,
    counter: u64 = 0,

    fn run(self: *@This()) void {
        _ = self.ready.fetchAdd(1, .seq_cst);
        while (self.ready.load(.seq_cst) < 2) std.atomic.spinLoopHint();
        for (0..10000) |_| {
            if (self.clean) self.mutex.lockUncancelable(self.io);
            const value: *volatile u64 = &self.counter;
            value.* += 1;
            if (self.clean) self.mutex.unlock(self.io);
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedProbeMode;
    const clean = std.mem.eql(u8, args[1], "clean");
    if (!clean and !std.mem.eql(u8, args[1], "race")) return error.UnknownProbeMode;
    var task: Task = .{ .io = init.io, .clean = clean };
    var first = try init.io.concurrent(Task.run, .{&task});
    var second = init.io.concurrent(Task.run, .{&task}) catch |err| {
        // Let the already-created worker leave its barrier on startup failure.
        _ = task.ready.fetchAdd(1, .seq_cst);
        first.await(init.io);
        return err;
    };
    first.await(init.io);
    second.await(init.io);
    if (clean and task.counter != 20000) return error.InvalidCounter;
}
