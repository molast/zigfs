const std = @import("std");
const durable = @import("durable.zig");

// std.Io.File.Atomic uses exactly 16 lower-case hex characters for a named
// temporary. These are reserved in these internal directories; no authoritative
// metadata has this name. Never recurse into object data or arbitrary sidecars.
pub const directories = [_][]const u8{
    ".zigfs",
    ".zigfs/journal",
    ".zigfs/system",
    ".zigfs/system/configuration",
    ".zigfs/config",
    ".zigfs/config/kms_config.json",
    ".zigfs/system/object-tags",
    ".zigfs/system/bucket-policies",
    ".zigfs/system/audit-archive",
};

pub fn isTemporaryName(name: []const u8) bool {
    if (name.len != 16) return false;
    for (name) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

/// Startup only, after taking the exclusive data-root lock and before starting
/// any writers. An online sweep could delete a live atomic publication.
pub fn run(root: std.Io.Dir, io: std.Io) !usize {
    var removed: usize = 0;
    for (directories) |path| {
        var dir = root.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer dir.close(io);
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind != .file or !isTemporaryName(entry.name)) continue;
            try dir.deleteFile(io, entry.name);
            removed += 1;
        }
        try durable.syncDirectory(dir, io);
    }
    return removed;
}

test "atomic orphan cleanup preserves authoritative files and unrelated namespaces" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    for (directories) |path| {
        var dir = try tmp.dir.createDirPathOpen(io, path, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = "0123456789abcdef", .data = "interrupted publication" });
        try dir.writeFile(io, .{ .sub_path = "checkpoint.meta", .data = "authoritative" });
        try dir.createDir(io, "fedcba9876543210", .default_dir);
    }
    try tmp.dir.createDirPath(io, "objects");
    try tmp.dir.writeFile(io, .{ .sub_path = "objects/0123456789abcdef", .data = "object data" });
    try std.testing.expectEqual(directories.len, try run(tmp.dir, io));
    try std.testing.expectEqual(@as(usize, 0), try run(tmp.dir, io));
    _ = try tmp.dir.statFile(io, "objects/0123456789abcdef", .{});
    for (directories) |path| {
        var dir = try tmp.dir.openDir(io, path, .{});
        defer dir.close(io);
        _ = try dir.statFile(io, "checkpoint.meta", .{});
        _ = try dir.statFile(io, "fedcba9876543210", .{});
    }
}
