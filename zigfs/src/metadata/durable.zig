const std = @import("std");

pub const SyncParentError = std.Io.Dir.OpenError || std.Io.File.SyncError;

pub fn syncDirectory(dir: std.Io.Dir, io: std.Io) std.Io.File.SyncError!void {
    const directory_file: std.Io.File = .{
        .handle = dir.handle,
        .flags = .{ .nonblocking = false },
    };
    try directory_file.sync(io);
}

pub fn syncParent(
    root: std.Io.Dir,
    io: std.Io,
    sub_path: []const u8,
) SyncParentError!void {
    const parent_path = std.fs.path.dirname(sub_path) orelse ".";
    var parent = try root.openDir(io, parent_path, .{});
    defer parent.close(io);
    try syncDirectory(parent, io);
}
