const std = @import("std");
const metadata_record = @import("../metadata/record.zig");
const repository_payload = @import("../metadata/repository_payload.zig");
const repository_port = @import("../ports/metadata_repository.zig");

pub const MemoryMetadataRepository = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(StoredRecord) = .empty,
    last_generation: u64 = 0,

    const StoredRecord = struct {
        record_type: metadata_record.Type,
        key: []u8,
        generation: u64,
        tombstone: bool,
        payload: []u8,
    };

    pub fn init(allocator: std.mem.Allocator) MemoryMetadataRepository {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MemoryMetadataRepository) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.payload);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn interface(self: *MemoryMetadataRepository) repository_port.MetadataRepository {
        return .{ .context = self, .vtable = &.{
            .get = getImpl,
            .put = putImpl,
            .tombstone = tombstoneImpl,
            .scan = scanImpl,
        } };
    }

    fn getImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        record_type: metadata_record.Type,
        key: []const u8,
    ) repository_port.Error!repository_port.Record {
        const self: *MemoryMetadataRepository = @ptrCast(@alignCast(context));
        const position = self.find(record_type, key) orelse return error.NotFound;
        return cloneRecord(allocator, self.entries.items[position]);
    }

    fn putImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        record_type: metadata_record.Type,
        key: []const u8,
        expected_generation: repository_port.ExpectedGeneration,
        payload: []const u8,
    ) repository_port.Error!u64 {
        _ = allocator;
        const self: *MemoryMetadataRepository = @ptrCast(@alignCast(context));
        return self.commit(record_type, key, expected_generation, payload, false);
    }

    fn tombstoneImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        record_type: metadata_record.Type,
        key: []const u8,
        expected_generation: repository_port.ExpectedGeneration,
    ) repository_port.Error!u64 {
        _ = allocator;
        const self: *MemoryMetadataRepository = @ptrCast(@alignCast(context));
        return self.commit(record_type, key, expected_generation, "", true);
    }

    fn scanImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        record_type: metadata_record.Type,
    ) repository_port.Error!repository_port.ScanResult {
        const self: *MemoryMetadataRepository = @ptrCast(@alignCast(context));
        var records: std.ArrayList(repository_port.Record) = .empty;
        errdefer {
            for (records.items) |record| record.deinit(allocator);
            records.deinit(allocator);
        }
        for (self.entries.items) |entry| {
            if (entry.record_type != record_type) continue;
            const cloned = try cloneRecord(allocator, entry);
            records.append(allocator, cloned) catch {
                cloned.deinit(allocator);
                return error.OutOfMemory;
            };
        }
        std.mem.sort(repository_port.Record, records.items, {}, lessThanRecord);
        return .{
            .records = records.toOwnedSlice(allocator) catch return error.OutOfMemory,
        };
    }

    fn commit(
        self: *MemoryMetadataRepository,
        record_type: metadata_record.Type,
        key: []const u8,
        expected_generation: repository_port.ExpectedGeneration,
        payload: []const u8,
        tombstone: bool,
    ) repository_port.Error!u64 {
        if (!repository_payload.isValidKey(key)) return error.InvalidKey;
        if (payload.len > metadata_record.max_payload_length) return error.PayloadTooLarge;
        const position = self.find(record_type, key);
        const current_generation: ?u64 = if (position) |index|
            self.entries.items[index].generation
        else
            null;
        switch (expected_generation) {
            .any => {},
            .missing => if (position != null) return error.Conflict,
            .exact => |expected| if (current_generation == null or
                current_generation.? != expected)
            {
                return error.Conflict;
            },
        }

        const generation = std.math.add(u64, self.last_generation, 1) catch {
            return error.GenerationExhausted;
        };
        const owned_payload = self.allocator.dupe(u8, payload) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_payload);
        if (position) |index| {
            self.allocator.free(self.entries.items[index].payload);
            self.entries.items[index].payload = owned_payload;
            self.entries.items[index].generation = generation;
            self.entries.items[index].tombstone = tombstone;
        } else {
            const owned_key = self.allocator.dupe(u8, key) catch return error.OutOfMemory;
            errdefer self.allocator.free(owned_key);
            self.entries.append(self.allocator, .{
                .record_type = record_type,
                .key = owned_key,
                .generation = generation,
                .tombstone = tombstone,
                .payload = owned_payload,
            }) catch return error.OutOfMemory;
        }
        self.last_generation = generation;
        return generation;
    }

    fn find(
        self: *const MemoryMetadataRepository,
        record_type: metadata_record.Type,
        key: []const u8,
    ) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.record_type == record_type and std.mem.eql(u8, entry.key, key)) {
                return index;
            }
        }
        return null;
    }
};

fn cloneRecord(
    allocator: std.mem.Allocator,
    stored: MemoryMetadataRepository.StoredRecord,
) repository_port.Error!repository_port.Record {
    const key = allocator.dupe(u8, stored.key) catch return error.OutOfMemory;
    errdefer allocator.free(key);
    const payload = allocator.dupe(u8, stored.payload) catch return error.OutOfMemory;
    return .{
        .key = key,
        .generation = stored.generation,
        .tombstone = stored.tombstone,
        .payload = payload,
    };
}

fn lessThanRecord(_: void, left: repository_port.Record, right: repository_port.Record) bool {
    return std.mem.order(u8, left.key, right.key) == .lt;
}

test "memory repository passes shared contract" {
    const contract = @import("../ports/metadata_repository_contract.zig");
    var repository = MemoryMetadataRepository.init(std.testing.allocator);
    defer repository.deinit();
    try contract.run(repository.interface());
}
