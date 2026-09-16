const std = @import("std");
const bucket_domain = @import("bucket.zig");
const object_domain = @import("object.zig");

pub const max_key_length = object_domain.max_key_length;

pub const Directory = struct {
    bucket_name: []u8,
    key: []u8,
    created_at_unix_seconds: i64,
    last_modified_unix_seconds: i64,
    generation: u64,

    pub fn deinit(self: Directory, allocator: std.mem.Allocator) void {
        allocator.free(self.bucket_name);
        allocator.free(self.key);
    }
};

pub const ValidationError = error{
    InvalidBucketName,
    InvalidDirectoryKey,
};

pub fn validate(bucket_name: []const u8, key: []const u8) ValidationError!void {
    bucket_domain.validateName(bucket_name) catch return error.InvalidBucketName;
    object_domain.validateKey(key) catch return error.InvalidDirectoryKey;
    if (key[key.len - 1] != '/') return error.InvalidDirectoryKey;
}

pub fn parentKeys(allocator: std.mem.Allocator, key: []const u8) std.mem.Allocator.Error![][]u8 {
    var result: std.ArrayList([]u8) = .empty;
    errdefer {
        for (result.items) |item| allocator.free(item);
        result.deinit(allocator);
    }
    var offset: usize = 0;
    while (std.mem.indexOfScalarPos(u8, key, offset, '/')) |slash| {
        const end = slash + 1;
        // A key ending in '/' names a directory itself. It is not its own
        // parent, so only return ancestors strictly above the requested key.
        if (end >= key.len) break;
        const parent = allocator.dupe(u8, key[0..end]) catch return error.OutOfMemory;
        result.append(allocator, parent) catch {
            allocator.free(parent);
            return error.OutOfMemory;
        };
        offset = end;
        if (offset >= key.len) break;
    }
    return result.toOwnedSlice(allocator);
}

test "directory validation and parent paths" {
    try validate("photos", "images/");
    try std.testing.expectError(error.InvalidDirectoryKey, validate("photos", "images"));
    const parents = try parentKeys(std.testing.allocator, "a/b/file.txt");
    defer {
        for (parents) |parent| std.testing.allocator.free(parent);
        std.testing.allocator.free(parents);
    }
    try std.testing.expectEqual(@as(usize, 2), parents.len);
    try std.testing.expectEqualStrings("a/", parents[0]);
    try std.testing.expectEqualStrings("a/b/", parents[1]);

    const directory_parents = try parentKeys(std.testing.allocator, "a/b/");
    defer {
        for (directory_parents) |parent| std.testing.allocator.free(parent);
        std.testing.allocator.free(directory_parents);
    }
    try std.testing.expectEqual(@as(usize, 1), directory_parents.len);
    try std.testing.expectEqualStrings("a/", directory_parents[0]);

    const root_parents = try parentKeys(std.testing.allocator, "images/");
    defer std.testing.allocator.free(root_parents);
    try std.testing.expectEqual(@as(usize, 0), root_parents.len);
}
