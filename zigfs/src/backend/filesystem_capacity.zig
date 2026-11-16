const std = @import("std");
const builtin = @import("builtin");

extern fn zigfs_filesystem_capacity(fd: c_int, total: *u64, available: *u64, used: *u64) c_int;
extern fn zigfs_filesystem_health(fd: c_int, read_only: *c_int) c_int;

pub const Health = struct { online: bool, read_only: ?bool };

pub fn health(root: std.Io.Dir) ?Health {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return null;
    var read_only: c_int = 0;
    if (zigfs_filesystem_health(root.handle, &read_only) != 0) return .{ .online = false, .read_only = null };
    return .{ .online = true, .read_only = read_only != 0 };
}

pub const Capacity = struct { total: u64, available: u64, used: u64 };

/// Measures the filesystem containing ZigFS's opened data root, not the BFF host.
pub fn read(root: std.Io.Dir) ?Capacity {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return null;
    var capacity: Capacity = undefined;
    if (zigfs_filesystem_capacity(root.handle, &capacity.total, &capacity.available, &capacity.used) != 0) return null;
    return capacity;
}

test "filesystem capacity measures the opened data root" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const capacity = read(tmp.dir) orelse return error.TestUnexpectedResult;
    try std.testing.expect(capacity.total > 0);
    try std.testing.expect(capacity.available <= capacity.total);
    try std.testing.expect(capacity.used <= capacity.total);
    const status = health(tmp.dir) orelse return error.TestUnexpectedResult;
    try std.testing.expect(status.online);
    try std.testing.expectEqual(@as(?bool, false), status.read_only);
}

test "invalid filesystem handle is offline rather than a fabricated healthy disk" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const status = health(.{ .handle = -1 }) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!status.online);
    try std.testing.expect(status.read_only == null);
}
