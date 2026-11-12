const std = @import("std");
const cli = @import("zc");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    try cli.run(init.io, init.arena.allocator(), args[1..]);
}
