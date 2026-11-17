//! Benchmark-only macOS durability control. Does not change Engine defaults.
const std = @import("std");
const builtin = @import("builtin");

// Installed once before any worker starts, then read-only until all workers stop.
var original: std.Io = undefined;
var table: std.Io.VTable = undefined;

pub fn wrap(io: std.Io) !std.Io {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    original = io;
    table = io.vtable.*;
    table.fileSync = sync;
    return .{ .userdata = io.userdata, .vtable = &table };
}

fn sync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
    if (builtin.os.tag != .macos) unreachable;
    // Directories retain the engine's directory-sync behavior. Ordinary files
    // require FULLFSYNC; do not silently downgrade this comparison on failure.
    const stat = file.stat(original) catch return error.InputOutput;
    if (stat.kind == .directory) return original.vtable.fileSync(userdata, file);
    while (true) {
        switch (std.c.errno(std.c.fcntl(file.handle, std.c.F.FULLFSYNC))) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.InputOutput,
        }
    }
}
