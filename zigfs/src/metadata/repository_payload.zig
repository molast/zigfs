const std = @import("std");
pub const max_key_length = @import("metadata_engine").Limits.max_key_bytes;

pub fn isValidKey(key: []const u8) bool {
    return key.len != 0 and key.len <= max_key_length and std.mem.indexOfScalar(u8, key, 0) == null;
}
