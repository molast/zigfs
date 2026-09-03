const std = @import("std");
const multipart_domain = @import("../domain/multipart.zig");

pub const Error = error{
    OutOfMemory,
    NotFound,
    Conflict,
    InvalidValue,
    CorruptMetadata,
    Unavailable,
};

pub const ExpectedGeneration = union(enum) {
    missing,
    exact: u64,
};

pub const Record = union(enum) {
    active: multipart_domain.Upload,
    tombstone: u64,

    pub fn deinit(self: Record, allocator: std.mem.Allocator) void {
        switch (self) {
            .active => |upload| upload.deinit(allocator),
            .tombstone => {},
        }
    }
};

pub const MultipartStore = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (*anyopaque, std.mem.Allocator, []const u8) Error!Record,
        put: *const fn (*anyopaque, std.mem.Allocator, multipart_domain.View, ExpectedGeneration) Error!u64,
        tombstone: *const fn (*anyopaque, std.mem.Allocator, []const u8, u64) Error!u64,
    };

    pub fn get(self: MultipartStore, allocator: std.mem.Allocator, upload_id: []const u8) Error!Record {
        return self.vtable.get(self.context, allocator, upload_id);
    }

    pub fn put(self: MultipartStore, allocator: std.mem.Allocator, value: multipart_domain.View, expected: ExpectedGeneration) Error!u64 {
        return self.vtable.put(self.context, allocator, value, expected);
    }

    pub fn tombstone(self: MultipartStore, allocator: std.mem.Allocator, upload_id: []const u8, expected_generation: u64) Error!u64 {
        return self.vtable.tombstone(self.context, allocator, upload_id, expected_generation);
    }
};
