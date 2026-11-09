const std = @import("std");
const durable = @import("../metadata/durable.zig");
const log = std.log.scoped(.storage_cleanup);
const attempts = 3;

// Only called for unreachable generations already moved into the trash namespace.
pub fn removeTrash(root: std.Io.Dir, io: std.Io, path: []const u8) error{Unavailable}!void {
    for (0..attempts) |attempt| {
        root.deleteTree(io, path) catch |err| {
            if (attempt + 1 == attempts) {
                log.err("operation=delete_trash path={s} attempts={d} error={t}; retry on next storage scan", .{ path, attempts, err });
                return error.Unavailable;
            }
            continue;
        };
        durable.syncParent(root, io, path) catch |err| {
            log.err("operation=sync_cleanup path={s} error={t}", .{ path, err });
            return error.Unavailable;
        };
        return;
    }
}

pub fn pruneEmpty(root: std.Io.Dir, io: std.Io, path: []const u8) void {
    for (0..attempts) |attempt| {
        root.deleteDir(io, path) catch |err| switch (err) {
            error.FileNotFound, error.DirNotEmpty => return,
            else => {
                if (attempt + 1 == attempts) log.err("operation=delete_empty_container path={s} attempts={d} error={t}; retry on next storage scan", .{ path, attempts, err });
                continue;
            },
        };
        durable.syncParent(root, io, path) catch |err| log.err("operation=sync_cleanup path={s} error={t}", .{ path, err });
        return;
    }
}

// Caller holds both publication lock pools. Never visits logical directory metadata
// or removes generation directories here; reachability GC owns those decisions.
pub fn rescan(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io) !void {
    for ([_][]const u8{ ".zigfs/trash/objects", ".zigfs/trash/multipart" }) |path| {
        var dir = try root.openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            const child = try std.fmt.allocPrint(a, "{s}/{s}", .{ path, entry.name });
            defer a.free(child);
            removeTrash(root, io, child) catch continue;
        }
    }
    try pruneContainers(a, root, io, "objects", 3);
    try pruneContainers(a, root, io, "multipart", 3);
}

fn pruneContainers(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, path: []const u8, depth: u8) !void {
    if (depth == 0) return;
    var dir = try root.openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const child = try std.fmt.allocPrint(a, "{s}/{s}", .{ path, entry.name });
        defer a.free(child);
        try pruneContainers(a, root, io, child, depth - 1);
        pruneEmpty(root, io, child);
    }
}

test "rescan clears trash and empty physical containers but preserves data and logical directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    for ([_][]const u8{ ".zigfs/trash/objects/orphan", ".zigfs/trash/multipart/orphan", "objects/empty/shard/object", "objects/live/shard/object/generation", "multipart/empty/upload/part", "metadata/directories/user-empty" }) |path| try tmp.dir.createDirPath(io, path);
    try rescan(std.testing.allocator, tmp.dir, io);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir(io, "objects/empty", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir(io, ".zigfs/trash/objects/orphan", .{}));
    var live = try tmp.dir.openDir(io, "objects/live/shard/object/generation", .{});
    live.close(io);
    var logical = try tmp.dir.openDir(io, "metadata/directories/user-empty", .{});
    logical.close(io);
    try rescan(std.testing.allocator, tmp.dir, io);
}
