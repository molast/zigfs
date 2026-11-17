const std = @import("std");

pub const Segment = struct {
    base: u64,
    size: u64,
};

pub fn name(base: u64, buffer: *[32]u8) []const u8 {
    return std.fmt.bufPrint(buffer, "wal-{d:0>20}.segment", .{base}) catch unreachable;
}

pub fn list(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir) ![]Segment {
    var directory = try root.openDir(io, ".", .{ .iterate = true });
    defer directory.close(io);
    var result: std.ArrayList(Segment) = .empty;
    errdefer result.deinit(allocator);
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "wal-") or
            !std.mem.endsWith(u8, entry.name, ".segment")) continue;
        if (entry.name.len != 32 or entry.kind != .file) return error.CorruptRecord;
        const base = std.fmt.parseInt(u64, entry.name[4..24], 10) catch return error.CorruptRecord;
        var expected: [32]u8 = undefined;
        if (!std.mem.eql(u8, entry.name, name(base, &expected))) return error.CorruptRecord;
        const file = try root.openFile(io, entry.name, .{});
        defer file.close(io);
        try result.append(allocator, .{ .base = base, .size = (try file.stat(io)).size });
    }
    std.mem.sort(Segment, result.items, {}, struct {
        fn less(_: void, left: Segment, right: Segment) bool {
            return left.base < right.base;
        }
    }.less);
    return result.toOwnedSlice(allocator);
}
