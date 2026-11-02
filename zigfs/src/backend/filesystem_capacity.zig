const std = @import("std");
const builtin = @import("builtin");

extern fn zigfs_filesystem_capacity(fd: c_int, total: *u64, available: *u64, used: *u64) c_int;

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
}
