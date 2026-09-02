const std = @import("std");

pub const ValidationError = error{ InvalidLength, ContainsNull };

pub fn validateKey(key: []const u8) ValidationError!void {
    if (key.len == 0 or key.len > 1024) return error.InvalidLength;
    if (std.mem.indexOfScalar(u8, key, 0) != null) return error.ContainsNull;
}

test "accept nested object key" {
    try validateKey("images/2026/cover.png");
}

test "reject empty object key" {
    try std.testing.expectError(error.InvalidLength, validateKey(""));
}
