const std = @import("std");
const durable = @import("durable.zig");

/// Zig 0.17 File.Atomic reserves sixteen lowercase hex characters for its
/// named temporary files. Only this dedicated database directory is scanned,
/// after successful recovery and before any writers start. Never run online.
pub fn run(root: std.Io.Dir, io: std.Io) !usize {
    var directory = try root.openDir(io, ".", .{ .iterate = true });
    defer directory.close(io);
    var removed: usize = 0;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !temporaryName(entry.name)) continue;
        try directory.deleteFile(io, entry.name);
        removed += 1;
    }
    if (removed != 0) try durable.syncDirectory(directory, io);
    return removed;
}

fn temporaryName(name: []const u8) bool {
    if (name.len != 16) return false;
    for (name) |byte| {
        if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return false;
    }
    return true;
}
