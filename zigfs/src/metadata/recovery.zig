const std = @import("std");
const recovery_port = @import("../ports/recovery_store.zig");
const journal_port = @import("../ports/transaction_journal.zig");

pub const Status = enum {
    initializing,
    recovering,
    ready,
    recovery_required,
};

pub const Failure = enum {
    none,
    corrupt_journal,
    corrupt_record,
    inconsistent_journal,
    unrecoverable_transaction,
    unavailable,
    out_of_memory,
};

pub const State = struct {
    status: Status = .initializing,
    failure: Failure = .none,

    pub fn begin(self: *State) void {
        self.* = .{ .status = .recovering };
    }

    pub fn markReady(self: *State) void {
        self.* = .{ .status = .ready };
    }

    pub fn markRequired(self: *State, err: Error) void {
        self.* = .{
            .status = .recovery_required,
            .failure = failureFromError(err),
        };
    }

    pub fn isReady(self: State) bool {
        return self.status == .ready;
    }
};

pub const Error = error{
    OutOfMemory,
    CorruptJournal,
    CorruptRecord,
    InconsistentJournal,
    UnrecoverableTransaction,
    Unavailable,
};

pub const Report = struct {
    committed_transactions: usize = 0,
    rolled_back_transactions: usize = 0,
    orphan_temporaries_removed: usize = 0,
};

pub fn run(
    allocator: std.mem.Allocator,
    journal: journal_port.TransactionJournal,
    store: recovery_port.RecoveryStore,
) Error!Report {
    const scan = journal.scan(allocator) catch |err| return mapJournalError(err);
    defer scan.deinit(allocator);
    std.mem.sort(journal_port.Entry, scan.entries, {}, lessThanTransactionId);
    try validateJournal(scan.entries);
    std.mem.sort(journal_port.Entry, scan.entries, {}, lessThanRecoveryOrder);

    var report: Report = .{};
    var start: usize = 0;
    var previous_generation: ?u64 = null;
    while (start < scan.entries.len) {
        const transaction = scan.entries[start];
        var end = start + 1;
        while (end < scan.entries.len and sameTransactionId(
            transaction,
            scan.entries[end],
        )) : (end += 1) {}

        if (previous_generation == transaction.generation) {
            return error.InconsistentJournal;
        }
        previous_generation = transaction.generation;

        var has_intent = false;
        var has_commit = false;
        var has_abort = false;
        for (scan.entries[start..end]) |entry| {
            if (!sameTransaction(transaction, entry)) return error.InconsistentJournal;
            switch (entry.state) {
                .intent => {
                    if (has_intent) return error.InconsistentJournal;
                    has_intent = true;
                },
                .commit => {
                    if (has_commit) return error.InconsistentJournal;
                    has_commit = true;
                },
                .abort => {
                    if (has_abort) return error.InconsistentJournal;
                    has_abort = true;
                },
            }
        }
        if (!has_intent) return error.InconsistentJournal;

        if (has_abort) {
            try removeTemporary(store, transaction);
            report.rolled_back_transactions += 1;
        } else if (has_commit) {
            try recoverCommitted(allocator, store, transaction);
            report.committed_transactions += 1;
        } else {
            var abort_entry = transaction;
            abort_entry.state = .abort;
            journal.append(abort_entry) catch |err| return mapJournalError(err);
            try removeTemporary(store, transaction);
            report.rolled_back_transactions += 1;
        }
        start = end;
    }

    report.orphan_temporaries_removed = store.cleanupOrphans(allocator) catch |err| {
        return mapStoreError(err);
    };
    return report;
}

pub fn failureFromError(err: Error) Failure {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.CorruptJournal => .corrupt_journal,
        error.CorruptRecord => .corrupt_record,
        error.InconsistentJournal => .inconsistent_journal,
        error.UnrecoverableTransaction => .unrecoverable_transaction,
        error.Unavailable => .unavailable,
    };
}

fn recoverCommitted(
    allocator: std.mem.Allocator,
    store: recovery_port.RecoveryStore,
    transaction: journal_port.Entry,
) Error!void {
    const current_generation = store.currentGeneration(allocator, transaction) catch |err| {
        return mapStoreError(err);
    };
    if (current_generation) |current| {
        if (current > transaction.generation) {
            return removeTemporary(store, transaction);
        }
        if (current == transaction.generation) {
            store.stabilizeCurrent(transaction) catch |err| return mapStoreError(err);
            return removeTemporary(store, transaction);
        }
        if (transaction.previous_generation == null or
            current != transaction.previous_generation.?)
        {
            return error.UnrecoverableTransaction;
        }
    } else if (transaction.previous_generation != null) {
        return error.UnrecoverableTransaction;
    }

    const temporary = store.inspectTemporary(allocator, transaction) catch |err| {
        return mapStoreError(err);
    };
    if (temporary != .valid) return error.UnrecoverableTransaction;
    store.publishTemporary(transaction) catch |err| return mapStoreError(err);
}

fn removeTemporary(
    store: recovery_port.RecoveryStore,
    transaction: journal_port.Entry,
) Error!void {
    store.removeTemporary(transaction) catch |err| return mapStoreError(err);
}

fn lessThanTransactionId(_: void, left: journal_port.Entry, right: journal_port.Entry) bool {
    const id_order = std.mem.order(u8, &left.transaction_id, &right.transaction_id);
    if (id_order != .eq) return id_order == .lt;
    return @intFromEnum(left.state) < @intFromEnum(right.state);
}

fn lessThanRecoveryOrder(_: void, left: journal_port.Entry, right: journal_port.Entry) bool {
    if (left.generation != right.generation) return left.generation > right.generation;
    const id_order = std.mem.order(u8, &left.transaction_id, &right.transaction_id);
    if (id_order != .eq) return id_order == .lt;
    return @intFromEnum(left.state) < @intFromEnum(right.state);
}

fn validateJournal(entries: []const journal_port.Entry) Error!void {
    var start: usize = 0;
    while (start < entries.len) {
        const transaction = entries[start];
        var end = start + 1;
        while (end < entries.len and sameTransactionId(
            transaction,
            entries[end],
        )) : (end += 1) {}

        var has_intent = false;
        var has_commit = false;
        var has_abort = false;
        for (entries[start..end]) |entry| {
            if (!sameTransaction(transaction, entry)) return error.InconsistentJournal;
            switch (entry.state) {
                .intent => {
                    if (has_intent) return error.InconsistentJournal;
                    has_intent = true;
                },
                .commit => {
                    if (has_commit) return error.InconsistentJournal;
                    has_commit = true;
                },
                .abort => {
                    if (has_abort) return error.InconsistentJournal;
                    has_abort = true;
                },
            }
        }
        if (!has_intent) return error.InconsistentJournal;
        start = end;
    }
}

fn sameTransactionId(left: journal_port.Entry, right: journal_port.Entry) bool {
    return std.mem.eql(u8, &left.transaction_id, &right.transaction_id);
}

fn sameTransaction(left: journal_port.Entry, right: journal_port.Entry) bool {
    return left.record_type == right.record_type and
        left.generation == right.generation and
        left.previous_generation == right.previous_generation and
        std.mem.eql(u8, &left.key_hash, &right.key_hash);
}

fn mapJournalError(err: journal_port.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CorruptJournal => error.CorruptJournal,
        error.Unavailable => error.Unavailable,
    };
}

fn mapStoreError(err: recovery_port.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CorruptRecord => error.CorruptRecord,
        error.Unavailable => error.Unavailable,
    };
}

test "state records a stable recovery failure classification" {
    var state: State = .{};
    try std.testing.expectEqual(Status.initializing, state.status);
    state.begin();
    try std.testing.expectEqual(Status.recovering, state.status);
    state.markRequired(error.CorruptJournal);
    try std.testing.expectEqual(Status.recovery_required, state.status);
    try std.testing.expectEqual(Failure.corrupt_journal, state.failure);
    try std.testing.expect(!state.isReady());
}

const LocalTransactionJournal = @import("local_journal.zig").LocalTransactionJournal;
const LocalRecoveryStore = @import("local_recovery_store.zig").LocalRecoveryStore;
const layout = @import("local_layout.zig");
const metadata_record = @import("record.zig");
const repository_payload = @import("repository_payload.zig");

fn createTestLayout(root: std.Io.Dir) !void {
    try root.createDirPath(std.testing.io, ".zigfs/system/configuration/records");
    try root.createDirPath(std.testing.io, ".zigfs/system/credentials");
    try root.createDirPath(std.testing.io, ".zigfs/journal");
    try root.createDirPath(std.testing.io, ".zigfs/tmp");
    try root.createDirPath(std.testing.io, "metadata/buckets");
    try root.createDirPath(std.testing.io, "metadata/objects");
    try root.createDirPath(std.testing.io, "metadata/multipart");
}

fn testTransaction(
    state: journal_port.State,
    generation: u64,
    previous_generation: ?u64,
    key: []const u8,
    discriminator: u8,
) journal_port.Entry {
    return .{
        .transaction_id = .{
            discriminator, 1, 2,  3,  4,  5,  0x46, 7,
            0x88,          9, 10, 11, 12, 13, 14,   15,
        },
        .state = state,
        .record_type = .object,
        .generation = generation,
        .previous_generation = previous_generation,
        .key_hash = layout.hashKey(key),
    };
}

fn writeEnvelope(
    root: std.Io.Dir,
    path: []const u8,
    transaction: journal_port.Entry,
    key: []const u8,
    payload: []const u8,
) !void {
    const inner = try repository_payload.encode(std.testing.allocator, key, payload);
    defer std.testing.allocator.free(inner);
    const encoded = try metadata_record.encode(
        std.testing.allocator,
        transaction.record_type,
        transaction.generation,
        inner,
    );
    defer std.testing.allocator.free(encoded);
    try root.writeFile(std.testing.io, .{ .sub_path = path, .data = encoded });
}

fn writeTemporary(
    root: std.Io.Dir,
    transaction: journal_port.Entry,
    key: []const u8,
) ![]const u8 {
    var path_buffer: [layout.max_path_length]u8 = undefined;
    const path = try layout.temporaryPath(
        transaction.generation,
        transaction.transaction_id,
        &path_buffer,
    );
    try writeEnvelope(root, path, transaction, key, "metadata");
    return std.testing.allocator.dupe(u8, path);
}

test "recovery rolls back an unfinished intent and is idempotent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createTestLayout(tmp.dir);

    var journal = LocalTransactionJournal.init(tmp.dir, std.testing.io);
    var store = LocalRecoveryStore.init(tmp.dir, std.testing.io);
    const intent = testTransaction(.intent, 1, null, "bucket/photo.jpg", 1);
    try journal.interface().append(intent);
    const temporary_path = try writeTemporary(tmp.dir, intent, "bucket/photo.jpg");
    defer std.testing.allocator.free(temporary_path);

    const first = try run(std.testing.allocator, journal.interface(), store.interface());
    try std.testing.expectEqual(@as(usize, 1), first.rolled_back_transactions);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, temporary_path, .{}),
    );

    const entries = try journal.interface().scan(std.testing.allocator);
    defer entries.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), entries.entries.len);
    try std.testing.expectEqual(journal_port.State.abort, entries.entries[1].state);

    const second = try run(std.testing.allocator, journal.interface(), store.interface());
    try std.testing.expectEqual(@as(usize, 1), second.rolled_back_transactions);
    try std.testing.expectEqual(@as(usize, 0), second.orphan_temporaries_removed);
}

test "recovery publishes a committed temporary record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createTestLayout(tmp.dir);

    var journal = LocalTransactionJournal.init(tmp.dir, std.testing.io);
    var store = LocalRecoveryStore.init(tmp.dir, std.testing.io);
    const intent = testTransaction(.intent, 2, 1, "bucket/recovered.txt", 2);
    var commit = intent;
    commit.state = .commit;
    try journal.interface().append(intent);
    try journal.interface().append(commit);
    var previous = intent;
    previous.generation = 1;
    previous.previous_generation = null;
    var record_path_buffer: [layout.max_path_length]u8 = undefined;
    const record_path = try layout.recordPath(
        intent.record_type,
        intent.key_hash,
        &record_path_buffer,
    );
    try writeEnvelope(tmp.dir, record_path, previous, "bucket/recovered.txt", "old");
    const temporary_path = try writeTemporary(tmp.dir, intent, "bucket/recovered.txt");
    defer std.testing.allocator.free(temporary_path);

    const first = try run(std.testing.allocator, journal.interface(), store.interface());
    try std.testing.expectEqual(@as(usize, 1), first.committed_transactions);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, temporary_path, .{}),
    );
    try std.testing.expectEqual(
        @as(?u64, 2),
        try store.interface().currentGeneration(std.testing.allocator, intent),
    );

    const second = try run(std.testing.allocator, journal.interface(), store.interface());
    try std.testing.expectEqual(@as(usize, 1), second.committed_transactions);
}

test "recovery resolves multiple unpublished commits newest first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createTestLayout(tmp.dir);

    var journal = LocalTransactionJournal.init(tmp.dir, std.testing.io);
    var store = LocalRecoveryStore.init(tmp.dir, std.testing.io);
    const older = testTransaction(.intent, 10, null, "bucket/race.txt", 200);
    var older_commit = older;
    older_commit.state = .commit;
    const newer = testTransaction(.intent, 11, null, "bucket/race.txt", 1);
    var newer_commit = newer;
    newer_commit.state = .commit;
    try journal.interface().append(older);
    try journal.interface().append(older_commit);
    try journal.interface().append(newer);
    try journal.interface().append(newer_commit);
    const older_path = try writeTemporary(tmp.dir, older, "bucket/race.txt");
    defer std.testing.allocator.free(older_path);
    const newer_path = try writeTemporary(tmp.dir, newer, "bucket/race.txt");
    defer std.testing.allocator.free(newer_path);

    const report = try run(std.testing.allocator, journal.interface(), store.interface());
    try std.testing.expectEqual(@as(usize, 2), report.committed_transactions);
    try std.testing.expectEqual(
        @as(?u64, 11),
        try store.interface().currentGeneration(std.testing.allocator, newer),
    );
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, older_path, .{}),
    );
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, newer_path, .{}),
    );
}

test "abort wins over commit and orphan temporary records are removed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createTestLayout(tmp.dir);

    var journal = LocalTransactionJournal.init(tmp.dir, std.testing.io);
    var store = LocalRecoveryStore.init(tmp.dir, std.testing.io);
    const intent = testTransaction(.intent, 3, null, "bucket/aborted.txt", 3);
    var commit = intent;
    commit.state = .commit;
    var abort_entry = intent;
    abort_entry.state = .abort;
    try journal.interface().append(intent);
    try journal.interface().append(commit);
    try journal.interface().append(abort_entry);
    const temporary_path = try writeTemporary(tmp.dir, intent, "bucket/aborted.txt");
    defer std.testing.allocator.free(temporary_path);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".zigfs/tmp/no-journal.record",
        .data = "orphan",
    });

    const report = try run(std.testing.allocator, journal.interface(), store.interface());
    try std.testing.expectEqual(@as(usize, 1), report.rolled_back_transactions);
    try std.testing.expectEqual(@as(usize, 1), report.orphan_temporaries_removed);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, temporary_path, .{}),
    );
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, ".zigfs/tmp/no-journal.record", .{}),
    );
}

test "recovery rejects corrupt journal and committed record" {
    var journal_tmp = std.testing.tmpDir(.{});
    defer journal_tmp.cleanup();
    try createTestLayout(journal_tmp.dir);
    try journal_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".zigfs/journal/corrupt.journal",
        .data = "corrupt",
    });
    var corrupt_journal = LocalTransactionJournal.init(journal_tmp.dir, std.testing.io);
    var empty_store = LocalRecoveryStore.init(journal_tmp.dir, std.testing.io);
    try std.testing.expectError(
        error.CorruptJournal,
        run(std.testing.allocator, corrupt_journal.interface(), empty_store.interface()),
    );

    var record_tmp = std.testing.tmpDir(.{});
    defer record_tmp.cleanup();
    try createTestLayout(record_tmp.dir);
    var journal = LocalTransactionJournal.init(record_tmp.dir, std.testing.io);
    var store = LocalRecoveryStore.init(record_tmp.dir, std.testing.io);
    const intent = testTransaction(.intent, 4, null, "bucket/corrupt.txt", 4);
    var commit = intent;
    commit.state = .commit;
    try journal.interface().append(intent);
    try journal.interface().append(commit);
    var record_path_buffer: [layout.max_path_length]u8 = undefined;
    const record_path = try layout.recordPath(
        intent.record_type,
        intent.key_hash,
        &record_path_buffer,
    );
    try record_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = record_path,
        .data = "corrupt",
    });
    try std.testing.expectError(
        error.CorruptRecord,
        run(std.testing.allocator, journal.interface(), store.interface()),
    );
}
