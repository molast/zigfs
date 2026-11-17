const std = @import("std");
const builtin = @import("builtin");

pub const SyncParentError = std.Io.Dir.OpenError || std.Io.File.SyncError;

pub fn syncDirectory(dir: std.Io.Dir, io: std.Io) std.Io.File.SyncError!void {
    const directory_file: std.Io.File = .{
        .handle = dir.handle,
        .flags = .{ .nonblocking = false },
    };
    directory_file.sync(io) catch |err| {
        // Windows may report AccessDenied after flushing a directory because it
        // cannot update its access time. File sync errors remain strict.
        if (builtin.os.tag == .windows and err == error.AccessDenied) return;
        return err;
    };
}

pub fn syncParent(
    root: std.Io.Dir,
    io: std.Io,
    sub_path: []const u8,
) SyncParentError!void {
    const parent_path = std.fs.path.dirname(sub_path) orelse ".";
    // Linux opens non-iterating directories with O_PATH, which cannot be fsynced.
    var parent = try root.openDir(io, parent_path, .{ .iterate = true });
    defer parent.close(io);
    try syncDirectory(parent, io);
}
