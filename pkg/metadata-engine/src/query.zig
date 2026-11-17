const std = @import("std");
const port = @import("repository.zig");

pub const ScanOptions = struct {
    prefix: []const u8 = "",
    start_after: ?[]const u8 = null,
    limit: usize = 1000,
    max_bytes: usize = 1024 * 1024,
    /// Includes tombstones by default, just like MetadataRepository.scan.
    include_tombstones: bool = true,
    /// Supply a previous page's generation to reject a mixed-generation scan.
    expected_generation: ?u64 = null,
    /// Pair with expected_generation; omission means epoch zero for old callers.
    expected_gc_epoch: ?u48 = null,
};

pub const Page = struct {
    records: []port.Record,
    /// Exclusive resume key, including skipped tombstones. Null means exhausted.
    next_start_after: ?[]u8,
    generation: u64,
    gc_epoch: u48,
    visited: usize,

    pub fn deinit(self: Page, allocator: std.mem.Allocator) void {
        for (self.records) |record| record.deinit(allocator);
        allocator.free(self.records);
        if (self.next_start_after) |key| allocator.free(key);
    }
};
