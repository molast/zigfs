const std = @import("std");
const directory_domain = @import("../domain/directory.zig");

pub const Error = error{
    OutOfMemory,
    NotFound,
    Conflict,
    InvalidValue,
    CorruptMetadata,
    Unavailable,
};

pub const ExpectedGeneration = union(enum) {
    /// No active directory; a tombstone may be replaced with generation checks.
    missing,
    exact: u64,
};

pub const DirectoryStore = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8) Error!directory_domain.Directory,
        put: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8, i64, i64, ExpectedGeneration) Error!u64,
        tombstone: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8, u64) Error!u64,
    };

    pub fn get(self: DirectoryStore, allocator: std.mem.Allocator, bucket: []const u8, key: []const u8) Error!directory_domain.Directory {
        return self.vtable.get(self.context, allocator, bucket, key);
    }

    pub fn put(self: DirectoryStore, allocator: std.mem.Allocator, bucket: []const u8, key: []const u8, created_at: i64, modified_at: i64, expected: ExpectedGeneration) Error!u64 {
        return self.vtable.put(self.context, allocator, bucket, key, created_at, modified_at, expected);
    }

    pub fn tombstone(self: DirectoryStore, allocator: std.mem.Allocator, bucket: []const u8, key: []const u8, generation: u64) Error!u64 {
        return self.vtable.tombstone(self.context, allocator, bucket, key, generation);
    }
};
