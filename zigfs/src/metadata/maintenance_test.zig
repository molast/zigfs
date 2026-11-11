const std = @import("std");
const format = @import("format.zig");
const checkpoint = @import("checkpoint.zig");
const generation = @import("generation.zig");
const recovery = @import("recovery.zig");
const journal_mod = @import("local_journal.zig");
const LocalJournal = journal_mod.LocalTransactionJournal;
const LocalRepository = @import("local_repository.zig").LocalMetadataRepository;
const LocalRecovery = @import("local_recovery_store.zig").LocalRecoveryStore;
const fault = @import("../common/fault_injection.zig");
const io = std.testing.io;
const allocator = std.testing.allocator;

fn drain(repo: *LocalRepository, limit: usize) !usize {
    var removed: usize = 0;
    for (0..1000) |_| {
        const report = try repo.maintain(allocator, limit);
        try std.testing.expect(report.scanned_metadata_entries <= limit);
        try std.testing.expect(report.scanned_journal_entries <= limit);
        removed += report.removed_tombstones;
        if (!report.has_more) return removed;
    }
    return error.MaintenanceDidNotDrain;
}

test "rejected input and durable aborts do not disable maintenance" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try layout(tmp.dir);
    var journal = LocalJournal.init(tmp.dir, io);
    var repo = LocalRepository.init(tmp.dir, io, journal.interface());
    defer repo.deinit();
    try recover(tmp.dir, &journal, &repo);
    const oversized = try allocator.alloc(u8, @import("record.zig").max_payload_length);
    defer allocator.free(oversized);
    try std.testing.expectError(error.PayloadTooLarge, repo.interface().put(allocator, .object, "too-large", .missing, oversized));
    try std.testing.expectEqual(@as(u64, 0), try generation.load(tmp.dir, io));
    try std.testing.expectEqual(@as(usize, 0), try countFiles(tmp.dir, ".zigfs/journal", ".journal"));
    var fail = fault.FailOnce.init(.metadata_precommit_failed, 0);
    repo.setFaultInjectorForTesting(fail.interface());
    try std.testing.expectError(error.Unavailable, repo.interface().put(allocator, .object, "aborted", .missing, "payload"));
    const entries = try journal.interface().scan(allocator);
    defer entries.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), entries.entries.len);
    try std.testing.expectEqual(@import("../ports/transaction_journal.zig").State.abort, entries.entries[1].state);
    try std.testing.expectEqual(@as(usize, 0), try countFiles(tmp.dir, ".zigfs/tmp", ".record"));
    _ = try drain(&repo, 1);
    try std.testing.expectEqual(@as(usize, 0), try countFiles(tmp.dir, ".zigfs/journal", ".journal"));
    try recover(tmp.dir, &journal, &repo);
    try std.testing.expectError(error.NotFound, repo.interface().get(allocator, .object, "aborted"));
}

test "unsuccessful abort still requires recovery" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try layout(tmp.dir);
    var journal = LocalJournal.init(tmp.dir, io);
    var repo = LocalRepository.init(tmp.dir, io, journal.interface());
    defer repo.deinit();
    try recover(tmp.dir, &journal, &repo);
    const Failing = struct {
        fn trigger(_: *anyopaque, point: fault.Point) bool {
            return point == .metadata_precommit_failed or point == .metadata_abort_failed;
        }
    };
    var context: u8 = 0;
    repo.setFaultInjectorForTesting(.{ .context = &context, .trigger_fn = Failing.trigger });
    try std.testing.expectError(error.Unavailable, repo.interface().put(allocator, .object, "uncertain", .missing, "payload"));
    try std.testing.expectError(error.RecoveryRequired, repo.maintain(allocator, 10));
    try std.testing.expectEqual(@as(usize, 1), try countFiles(tmp.dir, ".zigfs/tmp", ".record"));
    var reopened = LocalRepository.init(tmp.dir, io, journal.interface());
    defer reopened.deinit();
    try recover(tmp.dir, &journal, &reopened);
    _ = try drain(&reopened, 1);
    try std.testing.expectError(error.NotFound, reopened.interface().get(allocator, .object, "uncertain"));
}

test "all metadata tombstones are reclaimed without weakening exact generation checks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try layout(tmp.dir);
    var journal = LocalJournal.init(tmp.dir, io);
    var repo = LocalRepository.init(tmp.dir, io, journal.interface());
    defer repo.deinit();
    try recover(tmp.dir, &journal, &repo);
    const kinds = [_]@import("record.zig").Type{ .multipart, .object, .directory, .bucket, .credential, .system };
    var deleted_generations: [kinds.len]u64 = undefined;
    for (kinds, 0..) |kind, i| {
        const gen = try repo.interface().put(allocator, kind, "recreate", .missing, "old");
        deleted_generations[i] = try repo.interface().tombstone(allocator, kind, "recreate", .{ .exact = gen });
        _ = try repo.interface().put(allocator, kind, "active", .missing, "must remain");
    }
    try std.testing.expectEqual(kinds.len, try drain(&repo, 2));
    try recover(tmp.dir, &journal, &repo);
    for (kinds, 0..) |kind, i| {
        try std.testing.expectError(error.NotFound, repo.interface().get(allocator, kind, "recreate"));
        try std.testing.expectError(error.Conflict, repo.interface().put(allocator, kind, "recreate", .{ .exact = deleted_generations[i] }, "stale"));
        const gen = try repo.interface().put(allocator, kind, "recreate", .missing, "new");
        try std.testing.expect(gen > deleted_generations[i]);
        const active = try repo.interface().get(allocator, kind, "active");
        defer active.deinit(allocator);
        try std.testing.expectEqualStrings("must remain", active.payload);
    }
}

test "bounded scans progress past active prefixes and revisit later deletions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try layout(tmp.dir);
    var journal = LocalJournal.init(tmp.dir, io);
    var repo = LocalRepository.init(tmp.dir, io, journal.interface());
    defer repo.deinit();
    try recover(tmp.dir, &journal, &repo);
    for (0..50) |i| {
        var buffer: [32]u8 = undefined;
        _ = try repo.interface().put(allocator, .multipart, try std.fmt.bufPrint(&buffer, "live-{d}", .{i}), .missing, "parts");
    }
    const gen = try repo.interface().put(allocator, .object, "deleted", .missing, "object");
    _ = try repo.interface().tombstone(allocator, .object, "deleted", .{ .exact = gen });
    try std.testing.expectEqual(@as(usize, 1), try drain(&repo, 3));
    const active = try repo.interface().get(allocator, .multipart, "live-0");
    defer active.deinit(allocator);
    _ = try repo.interface().tombstone(allocator, .multipart, "live-0", .{ .exact = active.generation });
    try std.testing.expectEqual(@as(usize, 1), try drain(&repo, 3));
    try std.testing.expectEqual(@as(usize, 49), try countFiles(tmp.dir, "metadata/multipart", ".record"));
}

test "reclamation preserves the previous generation of an unresolved resurrection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try layout(tmp.dir);
    var journal = LocalJournal.init(tmp.dir, io);
    var repo = LocalRepository.init(tmp.dir, io, journal.interface());
    defer repo.deinit();
    try recover(tmp.dir, &journal, &repo);
    const gen = try repo.interface().put(allocator, .object, "reused", .missing, "old");
    _ = try repo.interface().tombstone(allocator, .object, "reused", .{ .exact = gen });
    const Interleave = struct {
        repo: *LocalRepository,
        invoked: bool = false,
        fn trigger(context: *anyopaque, point: fault.Point) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (point == .metadata_commit_persisted) return true;
            if (point == .metadata_tombstone_observed and !self.invoked) {
                self.invoked = true;
                _ = self.repo.interface().put(allocator, .object, "reused", .any, "recovered new value") catch {};
            }
            return false;
        }
    };
    var interleave: Interleave = .{ .repo = &repo };
    repo.setFaultInjectorForTesting(.{ .context = &interleave, .trigger_fn = Interleave.trigger });
    try std.testing.expectError(error.RecoveryRequired, repo.maintain(allocator, 100));
    try std.testing.expect(interleave.invoked);
    var reopened = LocalRepository.init(tmp.dir, io, journal.interface());
    defer reopened.deinit();
    try recover(tmp.dir, &journal, &reopened);
    const record = try reopened.interface().get(allocator, .object, "reused");
    defer record.deinit(allocator);
    try std.testing.expectEqualStrings("recovered new value", record.payload);
}

test "reclamation coordinates with business read and conditional write sequences" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try layout(tmp.dir);
    var journal = LocalJournal.init(tmp.dir, io);
    var repo = LocalRepository.init(tmp.dir, io, journal.interface());
    defer repo.deinit();
    try recover(tmp.dir, &journal, &repo);
    var guard: std.Io.Mutex = .init;
    repo.reclamation_guard = &guard;
    const gen = try repo.interface().put(allocator, .directory, "same-name", .missing, "old");
    const deleted = try repo.interface().tombstone(allocator, .directory, "same-name", .{ .exact = gen });
    const Task = struct {
        repo: *LocalRepository,
        observed: std.Io.Event = .unset,
        failure: ?anyerror = null,
        fn trigger(context: *anyopaque, point: fault.Point) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (point == .metadata_tombstone_observed) self.observed.set(io);
            return false;
        }
        fn run(self: *@This()) void {
            _ = self.repo.maintain(allocator, 100) catch |err| {
                self.failure = err;
            };
            self.observed.set(io);
        }
    };
    var task: Task = .{ .repo = &repo };
    repo.setFaultInjectorForTesting(.{ .context = &task, .trigger_fn = Task.trigger });
    guard.lockUncancelable(io);
    var locked = true;
    defer if (locked) guard.unlock(io);
    var future = try io.concurrent(Task.run, .{&task});
    try task.observed.wait(io);
    const recreated = repo.interface().put(allocator, .directory, "same-name", .{ .exact = deleted }, "recreated");
    guard.unlock(io);
    locked = false;
    future.await(io);
    _ = try recreated;
    try std.testing.expect(task.failure == null);
    const record = try repo.interface().get(allocator, .directory, "same-name");
    defer record.deinit(allocator);
    try std.testing.expectEqualStrings("recreated", record.payload);
}

fn layout(root: std.Io.Dir) !void {
    for ([_][]const u8{ ".zigfs/journal", ".zigfs/tmp", ".zigfs/system/configuration/records", ".zigfs/system/credentials", "metadata/multipart", "metadata/objects", "metadata/buckets", "metadata/directories" }) |dir| {
        try root.createDirPath(io, dir);
    }
    _ = try format.loadOrCreate(root, io);
}

fn recover(root: std.Io.Dir, journal: *LocalJournal, repo: *LocalRepository) !void {
    repo.deinit();
    var store = LocalRecovery.init(root, io);
    _ = try recovery.run(allocator, journal.interface(), store.interface());
    try repo.markRecovered(allocator);
}

fn countFiles(root: std.Io.Dir, path: []const u8, suffix: []const u8) !usize {
    var dir = try root.openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, suffix)) count += 1;
    }
    return count;
}

test "maintenance bounds historical files and preserves active metadata across restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try layout(tmp.dir);
    var journal = LocalJournal.init(tmp.dir, io);
    var repo = LocalRepository.init(tmp.dir, io, journal.interface());
    defer repo.deinit();
    try recover(tmp.dir, &journal, &repo);
    _ = try repo.interface().put(allocator, .object, "object", .missing, "manifest references must survive");
    _ = try repo.interface().put(allocator, .multipart, "active", .missing, "parts");
    for (0..3) |_| {
        for (0..20) |i| {
            var key_buffer: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buffer, "upload-{d}", .{i});
            const gen = try repo.interface().put(allocator, .multipart, key, .missing, "part");
            _ = try repo.interface().tombstone(allocator, .multipart, key, .{ .exact = gen });
        }
        // A partial batch deliberately leaves unmatched old intent/commit files.
        const first = try repo.maintain(allocator, 1);
        try std.testing.expect(first.scanned_journal_entries <= 1);
        try std.testing.expect(first.scanned_metadata_entries <= 1);
        try recover(tmp.dir, &journal, &repo);
        const second = try repo.maintain(allocator, 1000);
        try std.testing.expectEqual(@as(usize, 20), first.removed_multipart_tombstones + second.removed_multipart_tombstones);
        try std.testing.expectEqual(@as(usize, 0), try countFiles(tmp.dir, ".zigfs/journal", ".journal"));
        try std.testing.expectEqual(@as(usize, 1), try countFiles(tmp.dir, "metadata/multipart", ".record"));
        try recover(tmp.dir, &journal, &repo);
    }
    const object = try repo.interface().get(allocator, .object, "object");
    defer object.deinit(allocator);
    try std.testing.expectEqualStrings("manifest references must survive", object.payload);
    const active = try repo.interface().get(allocator, .multipart, "active");
    defer active.deinit(allocator);
    try std.testing.expectEqualStrings("parts", active.payload);
    try std.testing.expect((try format.loadOrCreate(tmp.dir, io)).checkpoints);
}

test "every interrupted checkpoint and reclamation phase is restart recoverable" {
    const points = [_]fault.Point{ .checkpoint_written, .checkpoint_synced, .checkpoint_published, .checkpoint_durable, .checkpoint_format_enabled, .metadata_journal_pruned, .metadata_tombstone_pruned };
    for (points) |point| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try layout(tmp.dir);
        var journal = LocalJournal.init(tmp.dir, io);
        var repo = LocalRepository.init(tmp.dir, io, journal.interface());
        defer repo.deinit();
        try recover(tmp.dir, &journal, &repo);
        const gen = try repo.interface().put(allocator, .multipart, "done", .missing, "parts");
        _ = try repo.interface().tombstone(allocator, .multipart, "done", .{ .exact = gen });
        var failure = fault.FailOnce.init(point, 0);
        repo.setFaultInjectorForTesting(failure.interface());
        try std.testing.expectError(error.Unavailable, repo.maintain(allocator, 100));
        try std.testing.expect(failure.triggered);
        var reopened = LocalRepository.init(tmp.dir, io, journal.interface());
        defer reopened.deinit();
        try recover(tmp.dir, &journal, &reopened);
        _ = try reopened.maintain(allocator, 100);
        try std.testing.expectEqual(@as(usize, 0), try countFiles(tmp.dir, "metadata/multipart", ".record"));
        try std.testing.expectEqual(@as(usize, 0), try countFiles(tmp.dir, ".zigfs/journal", ".journal"));
        const last = try checkpoint.load(tmp.dir, io);
        const next = try reopened.interface().put(allocator, .multipart, "new", .missing, "new parts");
        try std.testing.expect(next > last);
        try recover(tmp.dir, &journal, &reopened);
        const value = try reopened.interface().get(allocator, .multipart, "new");
        defer value.deinit(allocator);
        try std.testing.expectEqualStrings("new parts", value.payload);
    }
}

test "failed commits block checkpoint advancement until restart recovery" {
    for ([_]fault.Point{ .journal_intent_persisted, .metadata_temporary_synced, .metadata_commit_persisted, .metadata_record_published }) |point| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try layout(tmp.dir);
        var journal = LocalJournal.init(tmp.dir, io);
        var repo = LocalRepository.init(tmp.dir, io, journal.interface());
        defer repo.deinit();
        try recover(tmp.dir, &journal, &repo);
        _ = try repo.maintain(allocator, 100);
        var failure = fault.FailOnce.init(point, 0);
        repo.setFaultInjectorForTesting(failure.interface());
        try std.testing.expectError(error.Unavailable, repo.interface().put(allocator, .multipart, "uncertain", .missing, "parts"));
        // Even successful subsequent writes cannot certify the earlier failure.
        _ = try repo.interface().put(allocator, .multipart, "later", .missing, "safe");
        try std.testing.expectError(error.RecoveryRequired, repo.maintain(allocator, 100));
        try std.testing.expectEqual(@as(u64, 0), try checkpoint.load(tmp.dir, io));
        var reopened = LocalRepository.init(tmp.dir, io, journal.interface());
        defer reopened.deinit();
        try recover(tmp.dir, &journal, &reopened);
        _ = try reopened.maintain(allocator, 100);
        if (point == .metadata_commit_persisted or point == .metadata_record_published) {
            const value = try reopened.interface().get(allocator, .multipart, "uncertain");
            defer value.deinit(allocator);
            try std.testing.expectEqualStrings("parts", value.payload);
        } else {
            try std.testing.expectError(error.NotFound, reopened.interface().get(allocator, .multipart, "uncertain"));
        }
    }
}

test "maintenance preserves writes published after its checkpoint" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try layout(tmp.dir);
    var journal = LocalJournal.init(tmp.dir, io);
    var repo = LocalRepository.init(tmp.dir, io, journal.interface());
    defer repo.deinit();
    try recover(tmp.dir, &journal, &repo);
    const gen = try repo.interface().put(allocator, .multipart, "reused", .missing, "old");
    _ = try repo.interface().tombstone(allocator, .multipart, "reused", .{ .exact = gen });
    const Interleave = struct {
        repo: *LocalRepository,
        invoked: bool = false,
        failed: bool = false,
        fn trigger(context: *anyopaque, point: fault.Point) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (point != .metadata_journal_pruned or self.invoked) return false;
            self.invoked = true;
            _ = self.repo.interface().put(allocator, .multipart, "reused", .any, "new active parts") catch {
                self.failed = true;
            };
            return false;
        }
    };
    var interleave: Interleave = .{ .repo = &repo };
    repo.setFaultInjectorForTesting(.{ .context = &interleave, .trigger_fn = Interleave.trigger });
    const report = try repo.maintain(allocator, 100);
    try std.testing.expect(interleave.invoked and !interleave.failed);
    try std.testing.expectEqual(@as(usize, 0), report.removed_multipart_tombstones);
    try recover(tmp.dir, &journal, &repo);
    const active = try repo.interface().get(allocator, .multipart, "reused");
    defer active.deinit(allocator);
    try std.testing.expect(active.generation > report.checkpoint_generation);
    try std.testing.expectEqualStrings("new active parts", active.payload);
}

test "required checkpoint rejects missing corrupt foreign or regressed state" {
    for (0..4) |mode| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try layout(tmp.dir);
        var journal = LocalJournal.init(tmp.dir, io);
        var repo = LocalRepository.init(tmp.dir, io, journal.interface());
        defer repo.deinit();
        try recover(tmp.dir, &journal, &repo);
        _ = try repo.interface().put(allocator, .multipart, "active", .missing, "parts");
        _ = try repo.maintain(allocator, 100);
        switch (mode) {
            0 => try tmp.dir.deleteFile(io, checkpoint.path),
            1 => try tmp.dir.writeFile(io, .{ .sub_path = checkpoint.path, .data = "corrupt" }),
            2 => {
                var metadata = try format.loadOrCreate(tmp.dir, io);
                metadata.instance_id[0] ^= 1;
                try tmp.dir.writeFile(io, .{ .sub_path = format.path, .data = &format.encode(metadata) });
            },
            3 => try tmp.dir.writeFile(io, .{ .sub_path = generation.path, .data = &generation.encode(0) }),
            else => unreachable,
        }
        var store = LocalRecovery.init(tmp.dir, io);
        try std.testing.expectError(error.CorruptJournal, recovery.run(allocator, journal.interface(), store.interface()));
    }
}
