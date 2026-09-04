const std = @import("std");
const durable = @import("durable.zig");
const generation = @import("generation.zig");
const fault_injection = @import("../common/fault_injection.zig");
const layout = @import("local_layout.zig");
const metadata_record = @import("record.zig");
const repository_payload = @import("repository_payload.zig");
const id = @import("../common/id.zig");
const repository_port = @import("../ports/metadata_repository.zig");
const journal_port = @import("../ports/transaction_journal.zig");

pub const LocalMetadataRepository = struct {
    root: std.Io.Dir,
    io: std.Io,
    journal: journal_port.TransactionJournal,
    mutex: std.Io.Mutex = .init,
    fault_injector: fault_injection.Injector = .disabled,

    pub fn init(
        root: std.Io.Dir,
        io: std.Io,
        journal: journal_port.TransactionJournal,
    ) LocalMetadataRepository {
        return .{ .root = root, .io = io, .journal = journal };
    }

    pub fn setFaultInjectorForTesting(
        self: *LocalMetadataRepository,
        injector: fault_injection.Injector,
    ) void {
        self.fault_injector = injector;
    }

    pub fn interface(self: *LocalMetadataRepository) repository_port.MetadataRepository {
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
        const self: *LocalMetadataRepository = @ptrCast(@alignCast(context));
        if (!repository_payload.isValidKey(key)) return error.InvalidKey;
        return (try self.readByKey(allocator, record_type, key)) orelse error.NotFound;
    }

    fn putImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        record_type: metadata_record.Type,
        key: []const u8,
        expected_generation: repository_port.ExpectedGeneration,
        payload: []const u8,
    ) repository_port.Error!u64 {
        return commitImpl(
            context,
            allocator,
            record_type,
            key,
            expected_generation,
            payload,
            false,
        );
    }

    fn tombstoneImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        record_type: metadata_record.Type,
        key: []const u8,
        expected_generation: repository_port.ExpectedGeneration,
    ) repository_port.Error!u64 {
        return commitImpl(
            context,
            allocator,
            record_type,
            key,
            expected_generation,
            "",
            true,
        );
    }

    fn commitImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        record_type: metadata_record.Type,
        key: []const u8,
        expected_generation: repository_port.ExpectedGeneration,
        payload: []const u8,
        tombstone: bool,
    ) repository_port.Error!u64 {
        const self: *LocalMetadataRepository = @ptrCast(@alignCast(context));
        if (!repository_payload.isValidKey(key)) return error.InvalidKey;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const current = try self.readByKey(allocator, record_type, key);
        defer if (current) |item| item.deinit(allocator);
        const previous_generation: ?u64 = if (current) |item| item.generation else null;
        switch (expected_generation) {
            .any => {},
            .missing => if (current != null) return error.Conflict,
            .exact => |expected| if (previous_generation == null or previous_generation.? != expected) {
                return error.Conflict;
            },
        }

        const next_generation = generation.allocate(self.root, self.io) catch |err| switch (err) {
            error.GenerationExhausted => return error.GenerationExhausted,
            error.InvalidLength,
            error.InvalidMagic,
            error.UnsupportedMajorVersion,
            error.UnsupportedFlags,
            error.ChecksumMismatch,
            => return error.CorruptRecord,
            else => return error.Unavailable,
        };
        const transaction_id = id.randomV4(self.io) catch return error.Unavailable;
        const key_hash = layout.hashKey(key);
        const journal_entry: journal_port.Entry = .{
            .transaction_id = transaction_id,
            .state = .intent,
            .record_type = record_type,
            .generation = next_generation,
            .previous_generation = previous_generation,
            .key_hash = key_hash,
        };
        self.journal.append(journal_entry) catch |err| return mapJournalError(err);
        if (self.fault_injector.trigger(.journal_intent_persisted)) {
            return error.Unavailable;
        }

        const inner_payload = (if (tombstone)
            repository_payload.encodeTombstone(allocator, key)
        else
            repository_payload.encode(allocator, key, payload)) catch |err| switch (err) {
            error.OutOfMemory => {
                self.appendAbort(journal_entry);
                return error.OutOfMemory;
            },
            error.InvalidKey => {
                self.appendAbort(journal_entry);
                return error.InvalidKey;
            },
            error.PayloadTooLarge => {
                self.appendAbort(journal_entry);
                return error.PayloadTooLarge;
            },
        };
        defer allocator.free(inner_payload);
        const encoded = metadata_record.encode(
            allocator,
            record_type,
            next_generation,
            inner_payload,
        ) catch |err| switch (err) {
            error.OutOfMemory => {
                self.appendAbort(journal_entry);
                return error.OutOfMemory;
            },
            error.PayloadTooLarge => {
                self.appendAbort(journal_entry);
                return error.PayloadTooLarge;
            },
        };
        defer allocator.free(encoded);

        var temporary_path_buffer: [layout.max_path_length]u8 = undefined;
        const temporary_path = layout.temporaryPath(
            next_generation,
            transaction_id,
            &temporary_path_buffer,
        ) catch {
            self.appendAbort(journal_entry);
            return error.Unavailable;
        };
        var committed = false;
        errdefer if (!committed) self.root.deleteFile(self.io, temporary_path) catch {};
        self.writeTemporary(temporary_path, encoded) catch |err| {
            self.appendAbort(journal_entry);
            return err;
        };
        if (self.fault_injector.trigger(.metadata_temporary_synced)) {
            committed = true;
            return error.Unavailable;
        }

        var commit_entry = journal_entry;
        commit_entry.state = .commit;
        self.journal.append(commit_entry) catch |err| {
            self.appendAbort(journal_entry);
            return mapJournalError(err);
        };
        committed = true;
        if (self.fault_injector.trigger(.metadata_commit_persisted)) {
            return error.Unavailable;
        }

        var record_path_buffer: [layout.max_path_length]u8 = undefined;
        const record_path = layout.recordPath(record_type, key_hash, &record_path_buffer) catch {
            return error.Unavailable;
        };
        self.root.rename(temporary_path, self.root, record_path, self.io) catch {
            return error.Unavailable;
        };
        if (self.fault_injector.trigger(.metadata_record_published)) {
            return error.Unavailable;
        }
        durable.syncParent(self.root, self.io, record_path) catch return error.Unavailable;
        durable.syncParent(self.root, self.io, temporary_path) catch return error.Unavailable;
        return next_generation;
    }

    fn scanImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        record_type: metadata_record.Type,
    ) repository_port.Error!repository_port.ScanResult {
        const self: *LocalMetadataRepository = @ptrCast(@alignCast(context));
        var directory = self.root.openDir(self.io, layout.typeDirectory(record_type), .{ .iterate = true }) catch {
            return error.Unavailable;
        };
        defer directory.close(self.io);

        var records: std.ArrayList(repository_port.Record) = .empty;
        errdefer {
            for (records.items) |item| item.deinit(allocator);
            records.deinit(allocator);
        }
        var iterator = directory.iterate();
        while (iterator.next(self.io) catch return error.Unavailable) |directory_entry| {
            if (directory_entry.kind != .file or
                !std.mem.endsWith(u8, directory_entry.name, ".record"))
            {
                continue;
            }
            const item = try self.readPath(allocator, record_type, layout.typeDirectory(record_type), directory_entry.name);
            records.append(allocator, item) catch {
                item.deinit(allocator);
                return error.OutOfMemory;
            };
        }
        std.mem.sort(repository_port.Record, records.items, {}, lessThanRecord);
        return .{ .records = records.toOwnedSlice(allocator) catch return error.OutOfMemory };
    }

    fn readByKey(
        self: *LocalMetadataRepository,
        allocator: std.mem.Allocator,
        record_type: metadata_record.Type,
        key: []const u8,
    ) repository_port.Error!?repository_port.Record {
        const key_hash = layout.hashKey(key);
        var path_buffer: [layout.max_path_length]u8 = undefined;
        const path = layout.recordPath(record_type, key_hash, &path_buffer) catch return error.Unavailable;
        const item = self.readFullPath(allocator, record_type, path) catch |err| switch (err) {
            error.NotFound => return null,
            else => return err,
        };
        if (!std.mem.eql(u8, item.key, key)) {
            item.deinit(allocator);
            return error.CorruptRecord;
        }
        return item;
    }

    fn readPath(
        self: *LocalMetadataRepository,
        allocator: std.mem.Allocator,
        record_type: metadata_record.Type,
        directory: []const u8,
        name: []const u8,
    ) repository_port.Error!repository_port.Record {
        var path_buffer: [layout.max_path_length]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ directory, name }) catch {
            return error.Unavailable;
        };
        const item = try self.readFullPath(allocator, record_type, path);
        const key_hash = layout.hashKey(item.key);
        var expected_path_buffer: [layout.max_path_length]u8 = undefined;
        const expected_path = layout.recordPath(record_type, key_hash, &expected_path_buffer) catch {
            item.deinit(allocator);
            return error.CorruptRecord;
        };
        if (!std.mem.eql(u8, name, std.fs.path.basename(expected_path))) {
            item.deinit(allocator);
            return error.CorruptRecord;
        }
        return item;
    }

    fn readFullPath(
        self: *LocalMetadataRepository,
        allocator: std.mem.Allocator,
        record_type: metadata_record.Type,
        path: []const u8,
    ) repository_port.Error!repository_port.Record {
        const max_file_length = metadata_record.header_length +
            metadata_record.max_payload_length +
            metadata_record.checksum_length;
        const bytes = self.root.readFileAlloc(
            self.io,
            path,
            allocator,
            .limited(max_file_length),
        ) catch |err| switch (err) {
            error.FileNotFound => return error.NotFound,
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => return error.CorruptRecord,
            else => return error.Unavailable,
        };
        defer allocator.free(bytes);
        const envelope = metadata_record.decode(bytes) catch return error.CorruptRecord;
        if (envelope.record_type != record_type or envelope.generation == 0) {
            return error.CorruptRecord;
        }
        const decoded = repository_payload.decode(envelope.payload) catch return error.CorruptRecord;
        const owned_key = allocator.dupe(u8, decoded.key) catch return error.OutOfMemory;
        errdefer allocator.free(owned_key);
        const owned_payload = allocator.dupe(u8, decoded.payload) catch return error.OutOfMemory;
        return .{
            .key = owned_key,
            .generation = envelope.generation,
            .tombstone = decoded.tombstone,
            .payload = owned_payload,
        };
    }

    fn writeTemporary(
        self: *LocalMetadataRepository,
        path: []const u8,
        bytes: []const u8,
    ) repository_port.Error!void {
        var file = self.root.createFile(self.io, path, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
        }) catch return error.Unavailable;
        defer file.close(self.io);
        file.writeStreamingAll(self.io, bytes) catch return error.Unavailable;
        file.sync(self.io) catch return error.Unavailable;
        durable.syncParent(self.root, self.io, path) catch return error.Unavailable;
    }

    fn appendAbort(self: *LocalMetadataRepository, original: journal_port.Entry) void {
        var aborted = original;
        aborted.state = .abort;
        self.journal.append(aborted) catch {};
    }

    fn lessThanRecord(_: void, left: repository_port.Record, right: repository_port.Record) bool {
        return std.mem.order(u8, left.key, right.key) == .lt;
    }
};

fn mapJournalError(err: journal_port.Error) repository_port.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CorruptJournal => error.CorruptJournal,
        error.Unavailable => error.Unavailable,
    };
}

fn createTestLayout(root: std.Io.Dir, io: std.Io) !void {
    try root.createDirPath(io, ".zigfs/system/configuration/records");
    try root.createDirPath(io, ".zigfs/system/credentials");
    try root.createDirPath(io, ".zigfs/journal");
    try root.createDirPath(io, ".zigfs/tmp");
    try root.createDirPath(io, "metadata/buckets");
    try root.createDirPath(io, "metadata/objects");
    try root.createDirPath(io, "metadata/multipart");
}

test "local repository passes shared contract and survives reopen" {
    const LocalTransactionJournal = @import("local_journal.zig").LocalTransactionJournal;
    const contract = @import("../ports/metadata_repository_contract.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createTestLayout(tmp.dir, std.testing.io);

    var journal = LocalTransactionJournal.init(tmp.dir, std.testing.io);
    var local = LocalMetadataRepository.init(tmp.dir, std.testing.io, journal.interface());
    try contract.run(local.interface());

    var reopened_journal = LocalTransactionJournal.init(tmp.dir, std.testing.io);
    var reopened = LocalMetadataRepository.init(tmp.dir, std.testing.io, reopened_journal.interface());
    const persisted = try reopened.interface().get(std.testing.allocator, .bucket, "contract-primary");
    defer persisted.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("second", persisted.payload);
}

test "intent and temporary record are not visible before commit" {
    const LocalTransactionJournal = @import("local_journal.zig").LocalTransactionJournal;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createTestLayout(tmp.dir, std.testing.io);

    var journal = LocalTransactionJournal.init(tmp.dir, std.testing.io);
    var local = LocalMetadataRepository.init(tmp.dir, std.testing.io, journal.interface());
    const transaction_id: id.Uuid = .{ 0, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 };
    const key_hash = layout.hashKey("not-committed");
    try journal.interface().append(.{
        .transaction_id = transaction_id,
        .state = .intent,
        .record_type = .object,
        .generation = 1,
        .previous_generation = null,
        .key_hash = key_hash,
    });
    const inner = try repository_payload.encode(std.testing.allocator, "not-committed", "data");
    defer std.testing.allocator.free(inner);
    const encoded = try metadata_record.encode(std.testing.allocator, .object, 1, inner);
    defer std.testing.allocator.free(encoded);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".zigfs/tmp/uncommitted.record",
        .data = encoded,
    });

    try std.testing.expectError(
        error.NotFound,
        local.interface().get(std.testing.allocator, .object, "not-committed"),
    );
}

test "corrupt record is isolated from healthy records" {
    const LocalTransactionJournal = @import("local_journal.zig").LocalTransactionJournal;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createTestLayout(tmp.dir, std.testing.io);

    var journal = LocalTransactionJournal.init(tmp.dir, std.testing.io);
    var local = LocalMetadataRepository.init(tmp.dir, std.testing.io, journal.interface());
    const repository = local.interface();
    _ = try repository.put(std.testing.allocator, .object, "corrupt-me", .missing, "bad");
    _ = try repository.put(std.testing.allocator, .object, "healthy", .missing, "good");

    const key_hash = layout.hashKey("corrupt-me");
    var path_buffer: [layout.max_path_length]u8 = undefined;
    const path = try layout.recordPath(.object, key_hash, &path_buffer);
    const max_file_length = metadata_record.header_length +
        metadata_record.max_payload_length +
        metadata_record.checksum_length;
    const bytes = try tmp.dir.readFileAlloc(
        std.testing.io,
        path,
        std.testing.allocator,
        .limited(max_file_length),
    );
    defer std.testing.allocator.free(bytes);
    bytes[metadata_record.header_length] ^= 0xff;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });

    try std.testing.expectError(
        error.CorruptRecord,
        repository.get(std.testing.allocator, .object, "corrupt-me"),
    );
    const healthy = try repository.get(std.testing.allocator, .object, "healthy");
    defer healthy.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("good", healthy.payload);
}

test "scan rejects a valid record under the wrong hash name" {
    const LocalTransactionJournal = @import("local_journal.zig").LocalTransactionJournal;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createTestLayout(tmp.dir, std.testing.io);

    const inner = try repository_payload.encode(std.testing.allocator, "actual-key", "payload");
    defer std.testing.allocator.free(inner);
    const encoded = try metadata_record.encode(std.testing.allocator, .bucket, 1, inner);
    defer std.testing.allocator.free(encoded);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "metadata/buckets/wrong-hash.record",
        .data = encoded,
    });

    var journal = LocalTransactionJournal.init(tmp.dir, std.testing.io);
    var local = LocalMetadataRepository.init(tmp.dir, std.testing.io, journal.interface());
    try std.testing.expectError(
        error.CorruptRecord,
        local.interface().scan(std.testing.allocator, .bucket),
    );
}
