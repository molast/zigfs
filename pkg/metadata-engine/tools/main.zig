const std = @import("std");
const metadata = @import("metadata_engine");

/// Offline commands all take the exclusive database lock. inspect never creates
/// or truncates files; recover may discard only an incomplete final WAL frame.
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 3 or args.len > 5) {
        std.debug.print("usage: metadata-tool inspect|recover|checkpoint|gc DIRECTORY [max_records] [max_live_bytes]\n", .{});
        return error.InvalidArguments;
    }
    const inspect = std.mem.eql(u8, args[1], "inspect");
    const recover = std.mem.eql(u8, args[1], "recover");
    const checkpoint = std.mem.eql(u8, args[1], "checkpoint");
    const gc = std.mem.eql(u8, args[1], "gc");
    if (!inspect and !recover and !checkpoint and !gc) return error.InvalidArguments;
    var root = try std.Io.Dir.cwd().openDir(init.io, args[2], .{});
    defer root.close(init.io);
    var options: metadata.Options = .{ .read_only = inspect };
    if (args.len > 3) options.max_records = try std.fmt.parseInt(usize, args[3], 10);
    if (args.len > 4) {
        options.max_live_bytes = try std.fmt.parseInt(usize, args[4], 10);
        options.max_snapshot_bytes = options.max_live_bytes;
    }
    var engine = try metadata.Engine.openWithOptions(std.heap.smp_allocator, init.io, root, options);
    defer engine.deinit();
    if (checkpoint) try engine.checkpoint();
    if (gc) _ = try engine.collectTombstones();
    const json = try std.json.Stringify.valueAlloc(allocator, engine.stats(), .{});
    try std.Io.File.stdout().writeStreamingAll(init.io, json);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}
