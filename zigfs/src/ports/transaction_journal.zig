const std = @import("std");
const id = @import("../common/id.zig");
const metadata_record = @import("../metadata/record.zig");

pub const Error = error{
    OutOfMemory,
    CorruptJournal,
    Unavailable,
};

pub const State = enum(u8) {
    intent = 1,
    commit = 2,
    abort = 3,
};

pub const Entry = struct {
    transaction_id: id.Uuid,
    state: State,
    record_type: metadata_record.Type,
    generation: u64,
    previous_generation: ?u64,
    key_hash: [32]u8,
};

pub const ScanResult = struct {
    entries: []Entry,

    pub fn deinit(self: ScanResult, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }
};

pub const TransactionJournal = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        append: *const fn (context: *anyopaque, entry: Entry) Error!void,
        scan: *const fn (context: *anyopaque, allocator: std.mem.Allocator) Error!ScanResult,
    };

    pub fn append(self: TransactionJournal, entry: Entry) Error!void {
        return self.vtable.append(self.context, entry);
    }

    pub fn scan(
        self: TransactionJournal,
        allocator: std.mem.Allocator,
    ) Error!ScanResult {
        return self.vtable.scan(self.context, allocator);
    }
};
