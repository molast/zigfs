const std = @import("std");

/// Retains the directory stream between bounded maintenance passes. Entry names
/// are borrowed until next(). Reset after EOF so later insertions are revisited.
pub const Cursor = struct {
    dir: ?std.Io.Dir = null,
    iterator: std.Io.Dir.Iterator = undefined,

    pub fn next(self: *Cursor, root: std.Io.Dir, io: std.Io, path: []const u8) !?std.Io.Dir.Entry {
        if (self.dir == null) {
            self.dir = try root.openDir(io, path, .{ .iterate = true });
            self.iterator = self.dir.?.iterate();
        }
        return self.iterator.next(io);
    }

    pub fn reset(self: *Cursor, io: std.Io) void {
        if (self.dir) |dir| dir.close(io);
        self.dir = null;
    }
};
