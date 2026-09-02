const std = @import("std");

pub const Error = error{
    NotFound,
    Conflict,
    CorruptRecord,
    Unavailable,
};

pub const Record = struct {
    generation: u64,
    payload: []const u8,
};

pub const MetadataRepository = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            key: []const u8,
        ) (Error || std.mem.Allocator.Error)!Record,
        put: *const fn (
            context: *anyopaque,
            key: []const u8,
            expected_generation: ?u64,
            payload: []const u8,
        ) Error!u64,
    };

    pub fn get(
        self: MetadataRepository,
        allocator: std.mem.Allocator,
        key: []const u8,
    ) (Error || std.mem.Allocator.Error)!Record {
        return self.vtable.get(self.context, allocator, key);
    }

    pub fn put(
        self: MetadataRepository,
        key: []const u8,
        expected_generation: ?u64,
        payload: []const u8,
    ) Error!u64 {
        return self.vtable.put(self.context, key, expected_generation, payload);
    }
};
