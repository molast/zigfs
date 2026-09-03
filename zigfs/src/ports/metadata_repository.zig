const std = @import("std");
const metadata_record = @import("../metadata/record.zig");

pub const Error = error{
    OutOfMemory,
    NotFound,
    Conflict,
    InvalidKey,
    PayloadTooLarge,
    CorruptRecord,
    CorruptJournal,
    GenerationExhausted,
    Unavailable,
};

pub const ExpectedGeneration = union(enum) {
    any,
    missing,
    exact: u64,
};

pub const Record = struct {
    key: []u8,
    generation: u64,
    tombstone: bool,
    payload: []u8,

    pub fn deinit(self: Record, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.payload);
    }
};

pub const ScanResult = struct {
    records: []Record,

    pub fn deinit(self: ScanResult, allocator: std.mem.Allocator) void {
        for (self.records) |item| item.deinit(allocator);
        allocator.free(self.records);
    }
};

pub const MetadataRepository = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            record_type: metadata_record.Type,
            key: []const u8,
        ) Error!Record,
        put: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            record_type: metadata_record.Type,
            key: []const u8,
            expected_generation: ExpectedGeneration,
            payload: []const u8,
        ) Error!u64,
        tombstone: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            record_type: metadata_record.Type,
            key: []const u8,
            expected_generation: ExpectedGeneration,
        ) Error!u64,
        scan: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            record_type: metadata_record.Type,
        ) Error!ScanResult,
    };

    pub fn get(
        self: MetadataRepository,
        allocator: std.mem.Allocator,
        record_type: metadata_record.Type,
        key: []const u8,
    ) Error!Record {
        return self.vtable.get(self.context, allocator, record_type, key);
    }

    pub fn put(
        self: MetadataRepository,
        allocator: std.mem.Allocator,
        record_type: metadata_record.Type,
        key: []const u8,
        expected_generation: ExpectedGeneration,
        payload: []const u8,
    ) Error!u64 {
        return self.vtable.put(
            self.context,
            allocator,
            record_type,
            key,
            expected_generation,
            payload,
        );
    }

    pub fn scan(
        self: MetadataRepository,
        allocator: std.mem.Allocator,
        record_type: metadata_record.Type,
    ) Error!ScanResult {
        return self.vtable.scan(self.context, allocator, record_type);
    }

    pub fn tombstone(
        self: MetadataRepository,
        allocator: std.mem.Allocator,
        record_type: metadata_record.Type,
        key: []const u8,
        expected_generation: ExpectedGeneration,
    ) Error!u64 {
        return self.vtable.tombstone(
            self.context,
            allocator,
            record_type,
            key,
            expected_generation,
        );
    }
};
