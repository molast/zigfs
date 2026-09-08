const std = @import("std");
const object_domain = @import("../domain/object.zig");

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

pub const Value = object_domain.View;

pub const Record = union(enum) {
    active: object_domain.Object,
    delete_marker: object_domain.DeleteMarker,
    tombstone: u64,

    pub fn deinit(self: Record, allocator: std.mem.Allocator) void {
        switch (self) {
            .active => |object| object.deinit(allocator),
            .delete_marker => |marker| marker.deinit(allocator),
            .tombstone => {},
        }
    }
};

pub const HistoryRecord = union(enum) {
    active: object_domain.History,
    tombstone: u64,

    pub fn deinit(self: HistoryRecord, allocator: std.mem.Allocator) void {
        switch (self) {
            .active => |history| history.deinit(allocator),
            .tombstone => {},
        }
    }
};

pub const ObjectStore = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            bucket: []const u8,
            key: []const u8,
        ) Error!Record,
        get_history: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            bucket: []const u8,
            key: []const u8,
        ) Error!HistoryRecord,
        put: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            value: Value,
            expected_generation: ExpectedGeneration,
        ) Error!u64,
        put_history: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            history: *const object_domain.History,
            expected_generation: ExpectedGeneration,
        ) Error!u64,
        tombstone: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            bucket: []const u8,
            key: []const u8,
            expected_generation: u64,
        ) Error!u64,
    };

    pub fn get(
        self: ObjectStore,
        allocator: std.mem.Allocator,
        bucket: []const u8,
        key: []const u8,
    ) Error!Record {
        return self.vtable.get(self.context, allocator, bucket, key);
    }

    pub fn put(
        self: ObjectStore,
        allocator: std.mem.Allocator,
        value: Value,
        expected_generation: ExpectedGeneration,
    ) Error!u64 {
        return self.vtable.put(self.context, allocator, value, expected_generation);
    }

    pub fn getHistory(
        self: ObjectStore,
        allocator: std.mem.Allocator,
        bucket: []const u8,
        key: []const u8,
    ) Error!HistoryRecord {
        return self.vtable.get_history(self.context, allocator, bucket, key);
    }

    pub fn putHistory(
        self: ObjectStore,
        allocator: std.mem.Allocator,
        history: *const object_domain.History,
        expected_generation: ExpectedGeneration,
    ) Error!u64 {
        return self.vtable.put_history(self.context, allocator, history, expected_generation);
    }

    pub fn tombstone(
        self: ObjectStore,
        allocator: std.mem.Allocator,
        bucket: []const u8,
        key: []const u8,
        expected_generation: u64,
    ) Error!u64 {
        return self.vtable.tombstone(
            self.context,
            allocator,
            bucket,
            key,
            expected_generation,
        );
    }
};
