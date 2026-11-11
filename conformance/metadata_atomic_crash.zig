//! Conformance-only child: pause with an unpublished, synced atomic temporary.
//! The Python parent sends SIGKILL, so no Zig defer/Atomic.deinit can run.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.InvalidArguments;
    var root = try std.Io.Dir.cwd().openDir(init.io, args[1], .{});
    defer root.close(init.io);
    var atomic = try root.createFileAtomic(init.io, args[2], .{ .replace = true });
    defer atomic.deinit(init.io);
    try atomic.file.writeStreamingAll(init.io, "interrupted atomic metadata publication");
    try atomic.file.sync(init.io);
    std.debug.print("READY\n", .{});
    var parked: std.Io.Event = .unset;
    try parked.wait(init.io);
}
