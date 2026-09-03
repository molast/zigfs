const std = @import("std");
const journal_port = @import("transaction_journal.zig");

pub const Error = error{
    OutOfMemory,
    CorruptRecord,
    Unavailable,
};

pub const TemporaryState = enum {
    missing,
    valid,
};

pub const RecoveryStore = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        current_generation: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            transaction: journal_port.Entry,
        ) Error!?u64,
        inspect_temporary: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            transaction: journal_port.Entry,
        ) Error!TemporaryState,
        publish_temporary: *const fn (
            context: *anyopaque,
            transaction: journal_port.Entry,
        ) Error!void,
        stabilize_current: *const fn (
            context: *anyopaque,
            transaction: journal_port.Entry,
        ) Error!void,
        remove_temporary: *const fn (
            context: *anyopaque,
            transaction: journal_port.Entry,
        ) Error!void,
        cleanup_orphans: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
        ) Error!usize,
    };

    pub fn currentGeneration(
        self: RecoveryStore,
        allocator: std.mem.Allocator,
        transaction: journal_port.Entry,
    ) Error!?u64 {
        return self.vtable.current_generation(self.context, allocator, transaction);
    }

    pub fn inspectTemporary(
        self: RecoveryStore,
        allocator: std.mem.Allocator,
        transaction: journal_port.Entry,
    ) Error!TemporaryState {
        return self.vtable.inspect_temporary(self.context, allocator, transaction);
    }

    pub fn publishTemporary(
        self: RecoveryStore,
        transaction: journal_port.Entry,
    ) Error!void {
        return self.vtable.publish_temporary(self.context, transaction);
    }

    pub fn removeTemporary(
        self: RecoveryStore,
        transaction: journal_port.Entry,
    ) Error!void {
        return self.vtable.remove_temporary(self.context, transaction);
    }

    pub fn stabilizeCurrent(
        self: RecoveryStore,
        transaction: journal_port.Entry,
    ) Error!void {
        return self.vtable.stabilize_current(self.context, transaction);
    }

    pub fn cleanupOrphans(
        self: RecoveryStore,
        allocator: std.mem.Allocator,
    ) Error!usize {
        return self.vtable.cleanup_orphans(self.context, allocator);
    }
};
