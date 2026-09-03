const std = @import("std");
const durable = @import("durable.zig");
const layout = @import("local_layout.zig");
const metadata_record = @import("record.zig");
const repository_payload = @import("repository_payload.zig");
const recovery_port = @import("../ports/recovery_store.zig");
const journal_port = @import("../ports/transaction_journal.zig");

pub const LocalRecoveryStore = struct {
    root: std.Io.Dir,
    io: std.Io,

    pub fn init(root: std.Io.Dir, io: std.Io) LocalRecoveryStore {
        return .{ .root = root, .io = io };
    }

    pub fn interface(self: *LocalRecoveryStore) recovery_port.RecoveryStore {
        return .{ .context = self, .vtable = &.{
            .current_generation = currentGenerationImpl,
            .inspect_temporary = inspectTemporaryImpl,
            .publish_temporary = publishTemporaryImpl,
            .stabilize_current = stabilizeCurrentImpl,
            .remove_temporary = removeTemporaryImpl,
            .cleanup_orphans = cleanupOrphansImpl,
        } };
    }

    fn currentGenerationImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        transaction: journal_port.Entry,
    ) recovery_port.Error!?u64 {
        const self: *LocalRecoveryStore = @ptrCast(@alignCast(context));
        var path_buffer: [layout.max_path_length]u8 = undefined;
        const path = layout.recordPath(
            transaction.record_type,
            transaction.key_hash,
            &path_buffer,
        ) catch return error.Unavailable;
        return self.inspectRecord(allocator, path, transaction) catch |err| switch (err) {
            error.NotFound => null,
            error.OutOfMemory => error.OutOfMemory,
            error.CorruptRecord => error.CorruptRecord,
            error.Unavailable => error.Unavailable,
        };
    }

    fn inspectTemporaryImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        transaction: journal_port.Entry,
    ) recovery_port.Error!recovery_port.TemporaryState {
        const self: *LocalRecoveryStore = @ptrCast(@alignCast(context));
        var path_buffer: [layout.max_path_length]u8 = undefined;
        const path = layout.temporaryPath(
            transaction.generation,
            transaction.transaction_id,
            &path_buffer,
        ) catch return error.Unavailable;
        const temporary_generation = self.inspectRecord(allocator, path, transaction) catch |err| switch (err) {
            error.NotFound => return .missing,
            error.OutOfMemory => return error.OutOfMemory,
            error.CorruptRecord => return error.CorruptRecord,
            error.Unavailable => return error.Unavailable,
        };
        if (temporary_generation != transaction.generation) return error.CorruptRecord;
        return .valid;
    }

    fn publishTemporaryImpl(
        context: *anyopaque,
        transaction: journal_port.Entry,
    ) recovery_port.Error!void {
        const self: *LocalRecoveryStore = @ptrCast(@alignCast(context));
        var temporary_path_buffer: [layout.max_path_length]u8 = undefined;
        const temporary_path = layout.temporaryPath(
            transaction.generation,
            transaction.transaction_id,
            &temporary_path_buffer,
        ) catch return error.Unavailable;
        var record_path_buffer: [layout.max_path_length]u8 = undefined;
        const record_path = layout.recordPath(
            transaction.record_type,
            transaction.key_hash,
            &record_path_buffer,
        ) catch return error.Unavailable;

        self.root.rename(temporary_path, self.root, record_path, self.io) catch {
            return error.Unavailable;
        };
        durable.syncParent(self.root, self.io, record_path) catch return error.Unavailable;
        durable.syncParent(self.root, self.io, temporary_path) catch return error.Unavailable;
    }

    fn stabilizeCurrentImpl(
        context: *anyopaque,
        transaction: journal_port.Entry,
    ) recovery_port.Error!void {
        const self: *LocalRecoveryStore = @ptrCast(@alignCast(context));
        var path_buffer: [layout.max_path_length]u8 = undefined;
        const path = layout.recordPath(
            transaction.record_type,
            transaction.key_hash,
            &path_buffer,
        ) catch return error.Unavailable;
        durable.syncParent(self.root, self.io, path) catch return error.Unavailable;
    }

    fn removeTemporaryImpl(
        context: *anyopaque,
        transaction: journal_port.Entry,
    ) recovery_port.Error!void {
        const self: *LocalRecoveryStore = @ptrCast(@alignCast(context));
        var path_buffer: [layout.max_path_length]u8 = undefined;
        const path = layout.temporaryPath(
            transaction.generation,
            transaction.transaction_id,
            &path_buffer,
        ) catch return error.Unavailable;
        self.root.deleteFile(self.io, path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return error.Unavailable,
        };
        durable.syncParent(self.root, self.io, path) catch return error.Unavailable;
    }

    fn cleanupOrphansImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
    ) recovery_port.Error!usize {
        const self: *LocalRecoveryStore = @ptrCast(@alignCast(context));
        var temporary_directory = self.root.openDir(
            self.io,
            ".zigfs/tmp",
            .{ .iterate = true },
        ) catch return error.Unavailable;
        defer temporary_directory.close(self.io);

        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |name| allocator.free(name);
            names.deinit(allocator);
        }
        var iterator = temporary_directory.iterate();
        while (iterator.next(self.io) catch return error.Unavailable) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".record")) continue;
            const owned_name = allocator.dupe(u8, entry.name) catch return error.OutOfMemory;
            names.append(allocator, owned_name) catch {
                allocator.free(owned_name);
                return error.OutOfMemory;
            };
        }

        var removed: usize = 0;
        for (names.items) |name| {
            temporary_directory.deleteFile(self.io, name) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return error.Unavailable,
            };
            removed += 1;
        }
        if (removed > 0) {
            durable.syncParent(self.root, self.io, ".zigfs/tmp/orphan.record") catch {
                return error.Unavailable;
            };
        }
        return removed;
    }

    const InspectError = recovery_port.Error || error{NotFound};

    fn inspectRecord(
        self: *LocalRecoveryStore,
        allocator: std.mem.Allocator,
        path: []const u8,
        transaction: journal_port.Entry,
    ) InspectError!u64 {
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
        if (envelope.record_type != transaction.record_type or
            envelope.generation == 0)
        {
            return error.CorruptRecord;
        }
        const payload = repository_payload.decode(envelope.payload) catch {
            return error.CorruptRecord;
        };
        const key_hash = layout.hashKey(payload.key);
        if (!std.mem.eql(u8, &key_hash, &transaction.key_hash)) {
            return error.CorruptRecord;
        }
        return envelope.generation;
    }
};
