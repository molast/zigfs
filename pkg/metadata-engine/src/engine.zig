const std = @import("std");
const timing = @import("timing.zig");
const codec = @import("codec.zig");
const durable = @import("durable.zig");
const port = @import("repository.zig");
const Type = @import("types.zig").Type;
const ordered = @import("ordered_index.zig");
const segments = @import("segments.zig");
const Options = @import("options.zig").Options;
const Stats = @import("options.zig").Stats;
const query = @import("query.zig");
const Map = std.StringHashMapUnmanaged(*ordered.Node);
const wal_magic = "ZFMELOG1";
const snapshot_magic = "ZFMESNP1";

/// Keys/nodes remain live until Engine.deinit. Payload ownership is transferred
/// by snapshot_pinned; checkpoint_mutex prevents overlapping view lifetimes.
const SnapshotEntry = struct {
    entry: codec.Entry,
    node: *ordered.Node,

    fn release(self: SnapshotEntry, allocator: std.mem.Allocator) void {
        if (!self.node.snapshot_pinned.swap(false, .acq_rel)) {
            allocator.free(self.entry.record.payload);
        }
    }
};

pub const Mutation = struct {
    record_type: Type,
    key: []const u8,
    expected: port.ExpectedGeneration = .any,
    payload: []const u8 = "",
    tombstone: bool = false,
};

pub const Point = enum {
    after_append,
    before_sync,
    after_sync,
    archive_source_synced,
    archive_linked,
    after_archive,
    replacement_synced,
    wal_replaced,
    after_rotate,
    checkpoint_captured,
    snapshot_written,
    snapshot_synced,
    snapshot_published,
    after_snapshot,
    cleanup_started,
};

/// Optional diagnostic hook. Must not reenter the engine while the state lock
/// is held. Only checkpoint_captured/snapshot_written/snapshot_synced run
/// outside the state lock, as does cleanup_started. Used by crash probes.
pub const Hook = struct {
    context: *anyopaque,
    call: *const fn (*anyopaque, Point) void,
};

pub const GroupItem = struct {
    mutations: []const Mutation,
    result: port.Error!u64 = error.Unavailable,
};

/// Standalone synchronous store. The caller owns root and keeps it open until
/// deinit. Engine owns the lock, WAL, maps and record memory. Do not move an
/// Engine after exposing interface(), or deinit while calls are in flight.
pub const Engine = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    lock: std.Io.File,
    wal: std.Io.File,
    maps: [6]Map = @splat(.empty),
    indexes: [6]ordered.Index = @splat(.{}),
    options: Options = .{},
    counters: Stats = .{},
    checkpoint_mutex: std.Io.Mutex = .init,
    wal_base: u64 = 0,
    hook: ?Hook = null,
    mutex: std.Io.Mutex = .init,
    database_id: [16]u8 = undefined,
    generation: u64 = 0,
    wal_length: u64 = 80,
    recovery_required: bool = false,
    state_lock_start: ?std.Io.Timestamp = null,
    /// Deterministic persistence-boundary injection, only acted on in test builds.
    test_fault: ?enum { after_append, after_sync, after_snapshot, short_write, disk_full, sync_failure, directory_sync_failure, link_unsupported, archive_link_failure } = null,

    /// Test-only repeated failures; set before starting concurrent workers.
    test_cleanup_failure: ?struct {
        kind: enum { delete, sync },
        remaining: usize,
    } = null,

    /// Open a dedicated directory (not the ZigFS data root). A pre-existing WAL
    /// is validated before any recovery truncation or new writes are performed.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir) !Engine {
        return openWithOptions(allocator, io, root, .{});
    }

    pub fn openWithOptions(
        allocator: std.mem.Allocator,
        io: std.Io,
        root: std.Io.Dir,
        options: Options,
    ) !Engine {
        try options.validate();
        var new_directory = false;
        var lock = root.openFile(io, "LOCK", .{ .mode = if (options.read_only) .read_only else .read_write }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (options.read_only) return error.ReadOnly;
                const file = try root.createFile(io, "LOCK", .{ .read = true, .exclusive = true });
                new_directory = true;
                break :blk file;
            },
            else => return err,
        };
        errdefer lock.close(io);
        if (!try lock.tryLock(io, .exclusive)) return error.Busy;
        errdefer lock.unlock(io);
        var wal = root.openFile(io, "wal", .{ .mode = if (options.read_only) .read_only else .read_write }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (!new_directory) return error.CorruptRecord;
                if (options.read_only) return error.ReadOnly;
                // Missing WAL in a database with a snapshot is data loss, not initialization.
                if (root.openFile(io, "snapshot", .{})) |file| {
                    file.close(io);
                    return error.CorruptRecord;
                } else |snapshot_error| {
                    if (snapshot_error != error.FileNotFound) return snapshot_error;
                }
                var directory = try root.openDir(io, ".", .{ .iterate = true });
                defer directory.close(io);
                var iterator = directory.iterate();
                while (try iterator.next(io)) |entry| {
                    if (!std.mem.eql(u8, entry.name, "LOCK")) return error.DirectoryNotEmpty;
                }
                var database_id: [16]u8 = undefined;
                try io.randomSecure(&database_id);
                var file = try root.createFile(io, "wal", .{ .read = true, .exclusive = true });
                errdefer file.close(io);
                const header = fileHeader(wal_magic, database_id, 0, 0);
                try file.writePositionalAll(io, &header, 0);
                try file.sync(io);
                try durable.syncParent(root, io, "wal");
                break :blk file;
            },
            else => return err,
        };
        errdefer wal.close(io);
        var self: Engine = .{ .allocator = allocator, .io = io, .root = root, .lock = lock, .wal = wal, .options = options };
        errdefer self.freeMaps();
        try self.recover();
        if (!options.read_only) {
            self.lockState();
            const pruned = self.pruneLocked();
            self.unlockState();
            try pruned;
            self.counters.orphan_temporaries_removed = try @import("cleanup.zig").run(root, io);
        }
        return self;
    }

    pub fn deinit(self: *Engine) void {
        self.freeMaps();
        self.wal.close(self.io);
        self.lock.unlock(self.io);
        self.lock.close(self.io);
        self.* = undefined;
    }

    pub fn interface(self: *Engine) port.MetadataRepository {
        return .{ .context = self, .vtable = &.{
            .get = getImpl,
            .put = putImpl,
            .tombstone = tombstoneImpl,
            .scan = scanImpl,
        } };
    }

    /// Atomic batch: all predicates observe pre-transaction state; duplicate
    /// (type,key) mutations are rejected. Every affected record shares one new
    /// generation. All allocations occur before WAL append; publication cannot
    /// fail after sync. On I/O failure, the result may be committed on recovery.
    pub fn commit(self: *Engine, mutations: []const Mutation) port.Error!u64 {
        self.lockState();
        defer self.unlockState();
        try self.beforeCommit();
        return self.commitLocked(mutations, true);
    }

    /// FIFO caller order; transactions remain independently atomic. Readers are
    /// excluded until the final sync. If sync fails, no successful result is
    /// returned and the whole engine is frozen, even if a prefix reached disk.
    pub fn commitGroup(self: *Engine, items: []GroupItem) void {
        self.lockState();
        defer self.unlockState();
        self.beforeCommit() catch |err| {
            for (items) |*item| item.result = err;
            return;
        };
        var successful: usize = 0;
        for (items) |*item| {
            item.result = self.commitLocked(item.mutations, false);
            if (item.result) |_| {
                successful += 1;
            } else |_| {}
        }
        if (successful == 0) return;
        self.counters.groups += 1;
        if (!self.recovery_required) {
            self.syncWal() catch {
                self.recovery_required = true;
            };
        }
        if (!self.recovery_required) self.counters.commits += successful;
        if (self.recovery_required) {
            for (items) |*item| {
                if (item.result) |_| {
                    item.result = error.Unavailable;
                } else |_| {}
            }
        }
    }

    fn beforeCommit(self: *Engine) port.Error!void {
        if (self.options.read_only) return error.ReadOnly;
        if (self.recovery_required) return error.Unavailable;
        if (self.wal_length >= self.options.segment_bytes and self.generation > self.wal_base) {
            self.rotateLocked() catch |err| {
                if (err == error.ResourceLimit) return error.ResourceLimit;
                self.recovery_required = true;
                return error.Unavailable;
            };
        }
    }

    fn commitLocked(self: *Engine, mutations: []const Mutation, sync: bool) port.Error!u64 {
        if (self.recovery_required) return error.Unavailable;
        if (mutations.len == 0 or mutations.len > codec.Limits.max_mutations) return error.PayloadTooLarge;
        const next = std.math.add(u64, self.generation, 1) catch return error.GenerationExhausted;
        var entries: std.ArrayList(codec.Entry) = .empty;
        defer entries.deinit(self.allocator);
        var transferred = false;
        // Prepared updates borrow keys from the locked pretransaction map. No
        // publication occurs on failure, so map membership identifies ownership.
        defer if (!transferred) {
            for (entries.items) |entry| {
                if (!self.maps[typeIndex(entry.record_type)].contains(entry.record.key)) self.allocator.free(entry.record.key);
                self.allocator.free(entry.record.payload);
            }
        };
        var encoded_length: usize = codec.header_length + codec.checksum_length;
        for (mutations) |mutation| {
            if (!codec.validKey(mutation.key)) return error.InvalidKey;
            if (mutation.payload.len > codec.Limits.max_frame_bytes) return error.PayloadTooLarge;
            encoded_length += 12 + mutation.key.len + mutation.payload.len;
            if (encoded_length > codec.Limits.max_frame_bytes) return error.PayloadTooLarge;
            if (mutation.tombstone and mutation.payload.len != 0) return error.InvalidKey;
            for (entries.items) |previous| {
                if (previous.record_type == mutation.record_type and
                    std.mem.eql(u8, previous.record.key, mutation.key)) return error.InvalidKey;
            }
            const index = typeIndex(mutation.record_type);
            const current = self.maps[index].get(mutation.key);
            switch (mutation.expected) {
                .any => {},
                .missing => if (current != null) return error.Conflict,
                .exact => |expected| {
                    if (current == null or current.?.generation != expected) return error.Conflict;
                },
            }
            const key = if (current) |node| @constCast(node.key) else try self.allocator.dupe(u8, mutation.key);
            errdefer if (current == null) self.allocator.free(key);
            const payload = try self.allocator.dupe(u8, mutation.payload);
            errdefer self.allocator.free(payload);
            try entries.append(self.allocator, .{
                .record_type = mutation.record_type,
                .record = .{ .key = key, .payload = payload, .generation = next, .tombstone = mutation.tombstone },
            });
        }
        const nodes = self.reserve(entries.items) catch |err| return mapError(err);
        defer self.allocator.free(nodes);
        defer if (!transferred) {
            for (nodes) |node| if (node) |value| self.allocator.destroy(value);
        };
        const bytes = codec.encode(self.allocator, entries.items, next) catch |err| return mapError(err);
        defer self.allocator.free(bytes);
        if (bytes.len > self.options.max_wal_bytes -| self.counters.wal_bytes -| 80) {
            // Do not schedule endless checkpoints for a transaction that cannot
            // fit even in an empty WAL. Quota pressure is separate from live-data
            // and snapshot memory limits.
            if (bytes.len <= self.options.max_wal_bytes -| 160 and
                (self.generation > self.counters.checkpoint_generation or self.counters.cleanup_pending))
            {
                self.counters.wal_pressure = true;
            }
            return error.ResourceLimit;
        }
        // Any failure beyond this boundary poisons this instance. Do not append
        // after an uncertain write or return stale data from the memory view.
        self.recovery_required = true;
        if (@import("builtin").is_test) {
            if (self.test_fault == .disk_full) return error.Unavailable;
            if (self.test_fault == .short_write) {
                self.wal.writePositionalAll(self.io, bytes[0 .. bytes.len / 2], self.wal_length) catch {};
                return error.Unavailable;
            }
        }
        const append_start = timing.begin(self.options.diagnostics, self.io);
        self.wal.writePositionalAll(self.io, bytes, self.wal_length) catch return error.Unavailable;
        self.counters.phases.wal_append.record(self.io, append_start);
        self.at(.after_append);
        if (@import("builtin").is_test and self.test_fault == .after_append) return error.Unavailable;
        if (sync) self.syncWal() catch return error.Unavailable;
        for (entries.items, nodes) |entry, node| self.publish(entry, node);
        transferred = true;
        self.generation = next;
        self.wal_length += bytes.len;
        self.counters.wal_bytes += bytes.len;
        if (sync) self.counters.commits += 1;
        self.recovery_required = false;
        return next;
    }

    fn syncWal(self: *Engine) !void {
        const start = timing.begin(self.options.diagnostics, self.io);
        defer self.counters.phases.wal_sync.record(self.io, start);
        self.at(.before_sync);
        if (@import("builtin").is_test and self.test_fault == .sync_failure) return error.Unavailable;
        try self.wal.sync(self.io);
        self.counters.syncs += 1;
        self.at(.after_sync);
        if (@import("builtin").is_test and self.test_fault == .after_sync) return error.Unavailable;
    }

    fn at(self: *Engine, point: Point) void {
        if (self.hook) |hook| hook.call(hook.context, point);
    }

    /// Pin a consistent view while holding the state lock, rotate the WAL at
    /// its boundary, then stream the snapshot without blocking readers/writers.
    /// A separate mutex serializes snapshot installation and reclamation.
    pub fn checkpoint(self: *Engine) !void {
        self.checkpoint_mutex.lockUncancelable(self.io);
        defer self.checkpoint_mutex.unlock(self.io);
        self.lockState();
        var locked = true;
        defer if (locked) self.unlockState();
        if (self.options.read_only) return error.ReadOnly;
        if (self.recovery_required) return error.Unavailable;
        if (self.counters.cleanup_pending) {
            self.counters.cleanup_retries += 1;
            try self.pruneLocked();
            // Cleanup released the state lock; a concurrent failed commit may
            // have frozen this instance while filesystem I/O was in progress.
            if (self.recovery_required) return error.Unavailable;
        }
        if (self.counters.live_bytes > self.options.max_snapshot_bytes) return error.ResourceLimit;
        const capture_start = timing.begin(self.options.diagnostics, self.io);
        // Capture immutable record metadata and pin its payload. Only values
        // overwritten while the view exists need deferred reclamation.
        const entries = try self.allocator.alloc(SnapshotEntry, self.counters.records);
        defer self.allocator.free(entries);
        var captured: usize = 0;
        defer for (entries[0..captured]) |view| view.release(self.allocator);
        for (self.indexes, 0..) |index, namespace| {
            var iterator = index.iterator("", false);
            while (iterator.nextNode()) |node| {
                const mutable_node = @constCast(node);
                std.debug.assert(!mutable_node.snapshot_pinned.load(.monotonic));
                entries[captured] = .{
                    .entry = .{
                        .record_type = @fromBackingInt(@intCast(namespace + 1)),
                        .record = node.record(),
                    },
                    .node = mutable_node,
                };
                mutable_node.snapshot_pinned.store(true, .release);
                captured += 1;
            }
        }
        self.counters.phases.snapshot_capture.record(self.io, capture_start);
        const boundary = self.generation;
        const captured_dirty_bytes = self.counters.dirty_bytes;
        self.rotateLocked() catch |err| {
            if (err != error.ResourceLimit) self.recovery_required = true;
            return err;
        };
        self.unlockState();
        locked = false;
        self.at(.checkpoint_captured);
        var snapshot = try self.root.createFileAtomic(self.io, "snapshot", .{ .replace = true });
        defer snapshot.deinit(self.io);
        const header = fileHeader(snapshot_magic, self.database_id, boundary, entries.len);
        var write_buffer: [64 * 1024]u8 = undefined;
        var writer = snapshot.file.writer(self.io, &write_buffer);
        try writer.interface.writeAll(&header);
        for (entries) |view| {
            const entry = view.entry;
            const bytes = try codec.encode(self.allocator, &.{entry}, entry.record.generation);
            defer self.allocator.free(bytes);
            try writer.interface.writeAll(bytes);
        }
        // Flush before both the diagnostic boundary and fsync: buffered data
        // must reach the file before the durable snapshot can be installed.
        try writer.interface.flush();
        self.at(.snapshot_written);
        try snapshot.file.sync(self.io);
        self.at(.snapshot_synced);
        self.lockState();
        locked = true;
        const install_start = timing.begin(self.options.diagnostics, self.io);

        if (self.recovery_required) return error.Unavailable;
        self.recovery_required = true;
        try snapshot.replace(self.io);
        self.at(.snapshot_published);
        if (@import("builtin").is_test and self.test_fault == .directory_sync_failure) return error.Unavailable;
        try durable.syncParent(self.root, self.io, "snapshot");
        self.at(.after_snapshot);
        if (@import("builtin").is_test and self.test_fault == .after_snapshot) return error.Unavailable;
        self.counters.checkpoint_generation = boundary;
        self.counters.dirty_bytes -|= captured_dirty_bytes;
        self.counters.checkpoints += 1;
        self.recovery_required = false;
        self.counters.phases.snapshot_install.record(self.io, install_start);
        try self.pruneLocked();
        // Release pins and retired payloads outside the state lock. The view
        // array and stable keys do not depend on the current record version.
        self.unlockState();
        locked = false;
    }

    fn rotateLocked(self: *Engine) !void {
        if (self.generation == self.wal_base) return;
        const start = timing.begin(self.options.diagnostics, self.io);
        defer self.counters.phases.rotation.record(self.io, start);
        if (self.counters.wal_bytes > self.options.max_wal_bytes - 80) {
            self.counters.wal_pressure = true;
            return error.ResourceLimit;
        }
        // Seal the active inode before linking its numbered archive. Until the
        // new WAL is installed, active.base remains authoritative. Failed or
        // interrupted rotations must never append to the aliased old inode.
        try self.wal.sync(self.io);
        self.at(.archive_source_synced);
        var path_buffer: [32]u8 = undefined;
        const path = segments.name(self.wal_base, &path_buffer);
        var old_size: u64 = 0;
        if (self.root.openFile(self.io, path, .{})) |old| {
            defer old.close(self.io);
            old_size = (try old.stat(self.io)).size;
        } else |err| {
            if (err != error.FileNotFound) return err;
        }
        // A redundant archive can only belong to the current active base. It
        // is not needed for recovery while this WAL is still authoritative.
        if (old_size != 0) try self.root.deleteFile(self.io, path);
        self.linkArchive(path) catch |err| switch (err) {
            error.OperationUnsupported => try self.copyArchive(path),
            else => return err,
        };
        self.at(.archive_linked);
        try durable.syncParent(self.root, self.io, path);
        self.at(.after_archive);
        var replacement = try self.root.createFileAtomic(self.io, "wal", .{ .replace = true });
        defer replacement.deinit(self.io);
        const header = fileHeader(wal_magic, self.database_id, self.generation, 0);
        try replacement.file.writeStreamingAll(self.io, &header);
        try replacement.file.sync(self.io);
        self.at(.replacement_synced);
        try replacement.replace(self.io);
        self.at(.wal_replaced);
        try durable.syncParent(self.root, self.io, "wal");
        self.at(.after_rotate);
        const wal = try self.root.openFile(self.io, "wal", .{ .mode = .read_write });
        self.wal.close(self.io);
        self.wal = wal;
        self.wal_base = self.generation;
        self.wal_length = 80;
        self.counters.wal_bytes = self.counters.wal_bytes - old_size + 80;
        self.counters.rotations += 1;
    }

    fn linkArchive(self: *Engine, path: []const u8) !void {
        if (@import("builtin").is_test) {
            if (self.test_fault == .link_unsupported) return error.OperationUnsupported;
            if (self.test_fault == .archive_link_failure) return error.Unavailable;
        }
        try self.root.hardLink("wal", self.root, path, self.io, .{});
        self.counters.linked_rotations += 1;
    }

    /// Filesystems without hard links keep the previously verified copy path.
    /// Permission, quota and I/O failures are never hidden by this fallback.
    fn copyArchive(self: *Engine, path: []const u8) !void {
        var archive = try self.root.createFileAtomic(self.io, path, .{ .replace = true });
        defer archive.deinit(self.io);
        var buffer: [64 * 1024]u8 = undefined;
        var offset: u64 = 0;
        while (offset < self.wal_length) {
            const count: usize = @intCast(@min(buffer.len, self.wal_length - offset));
            if (try self.wal.readPositionalAll(self.io, buffer[0..count], offset) != count) return error.CorruptRecord;
            try archive.file.writeStreamingAll(self.io, buffer[0..count]);
            offset += count;
        }
        try archive.file.sync(self.io);
        try archive.replace(self.io);
        self.counters.rotation_copy_bytes +|= self.wal_length;
    }

    /// Retry reclamation without making another snapshot. Shares lock ordering
    /// with checkpoint, and never expands the persisted checkpoint boundary.
    pub fn retryCleanup(self: *Engine) !void {
        self.checkpoint_mutex.lockUncancelable(self.io);
        defer self.checkpoint_mutex.unlock(self.io);
        self.lockState();
        defer self.unlockState();
        if (self.options.read_only) return error.ReadOnly;
        if (self.recovery_required) return error.Unavailable;
        if (!self.counters.cleanup_pending) return;
        self.counters.cleanup_retries += 1;
        try self.pruneLocked();
    }

    /// Caller holds state lock and (online) checkpoint_mutex. Freeze the segment
    /// eligibility boundary under lock; release it only for filesystem cleanup.
    /// Writers only create segments at/above this wal_base, so selected sealed
    /// segments cannot be replaced or reused by concurrent rotation. Redundant
    /// current/future segments occur only at open, before writers are exposed.
    fn pruneLocked(self: *Engine) !void {
        self.counters.cleanup_pending = true;
        const files = try segments.list(self.allocator, self.io, self.root);
        defer self.allocator.free(files);
        const active_base = self.wal_base;
        const checkpoint_generation = self.counters.checkpoint_generation;
        const cleanup_start = timing.begin(self.options.diagnostics, self.io);
        self.unlockState();
        const removed = self.removeCoveredSegments(files, active_base, checkpoint_generation);
        self.lockState();
        self.counters.phases.cleanup_io.record(self.io, cleanup_start);
        try removed;
        self.counters.cleanup_pending = false;
        if (self.generation == self.counters.checkpoint_generation) self.counters.wal_pressure = false;
    }

    fn removeCoveredSegments(self: *Engine, files: []const segments.Segment, active_base: u64, checkpoint_generation: u64) !void {
        self.at(.cleanup_started);
        for (files, 0..) |segment, index| {
            const end = if (index + 1 < files.len) @min(files[index + 1].base, active_base) else active_base;
            if (segment.base < active_base and end > checkpoint_generation) continue;
            if (@import("builtin").is_test) {
                self.lockState();
                const fail = self.consumeCleanupFailure(.delete);
                self.unlockState();
                if (fail) return error.Unavailable;
            }
            var path_buffer: [32]u8 = undefined;
            try self.root.deleteFile(self.io, segments.name(segment.base, &path_buffer));
            self.lockState();
            self.counters.wal_bytes -= segment.size;
            self.unlockState();
        }
        if (@import("builtin").is_test) {
            self.lockState();
            const fail = self.consumeCleanupFailure(.sync);
            self.unlockState();
            if (fail) return error.Unavailable;
        }
        try durable.syncParent(self.root, self.io, "wal");
    }

    fn consumeCleanupFailure(self: *Engine, kind: enum { delete, sync }) bool {
        if (self.test_cleanup_failure) |*fault| {
            const matches = switch (kind) {
                .delete => fault.kind == .delete,
                .sync => fault.kind == .sync,
            };
            if (matches and fault.remaining > 0) {
                fault.remaining -= 1;
                return true;
            }
        }
        return false;
    }

    fn recover(self: *Engine) !void {
        const wal_header = try readFileHeader(self.wal, self.io, wal_magic);
        self.database_id = wal_header.database_id;
        self.wal_base = wal_header.generation;
        if (wal_header.count != 0) return error.CorruptRecord;
        const snapshot = self.root.openFile(self.io, "snapshot", .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (snapshot) |file| {
            defer file.close(self.io);
            const header = try readFileHeader(file, self.io, snapshot_magic);
            if (!std.mem.eql(u8, &header.database_id, &self.database_id)) return error.CorruptRecord;
            try self.loadSnapshot(file, header.count, header.generation);
            self.generation = header.generation;
            self.counters.checkpoint_generation = header.generation;
        }
        const files = try segments.list(self.allocator, self.io, self.root);
        defer self.allocator.free(files);
        self.counters.wal_bytes = (try self.wal.stat(self.io)).size;
        for (files) |segment| self.counters.wal_bytes += segment.size;
        for (files, 0..) |segment, index| {
            if (segment.base >= self.wal_base) continue; // Uninstalled rotation.
            const end = if (index + 1 < files.len) @min(files[index + 1].base, self.wal_base) else self.wal_base;
            if (end <= self.counters.checkpoint_generation) continue;
            if (segment.base > self.generation) return error.CorruptRecord;
            var path_buffer: [32]u8 = undefined;
            const file = try self.root.openFile(self.io, segments.name(segment.base, &path_buffer), .{});
            defer file.close(self.io);
            const header = try readFileHeader(file, self.io, wal_magic);
            if (header.generation != segment.base or header.count != 0 or
                !std.mem.eql(u8, &header.database_id, &self.database_id)) return error.CorruptRecord;
            const replayed = try self.replay(file, segment.base);
            if (replayed.generation != end or replayed.length != (try file.stat(self.io)).size) return error.CorruptRecord;
        }
        if (self.generation < self.wal_base) return error.CorruptRecord;
        const replayed = try self.replay(self.wal, self.wal_base);
        if (replayed.generation < self.counters.checkpoint_generation) return error.CorruptRecord;
        const actual_length = (try self.wal.stat(self.io)).size;
        self.counters.incomplete_tail_bytes = actual_length - replayed.length;
        if (actual_length != replayed.length and !self.options.read_only) {
            try self.wal.setLength(self.io, replayed.length);
            try self.wal.sync(self.io);
            self.counters.wal_bytes -= actual_length - replayed.length;
        }
        self.wal_length = replayed.length;
    }

    fn loadSnapshot(self: *Engine, file: std.Io.File, count: u64, boundary: u64) !void {
        const size = (try file.stat(self.io)).size;
        // Even the smallest valid frame needs a key byte. Bound untrusted counts
        // before reserving memory, then validate every frame and quota first.
        if (size < 80 or count > (size - 80) / 109) return error.CorruptRecord;
        if (count > self.options.max_records) return error.ResourceLimit;
        var frames: FrameReader = .{ .file = file, .io = self.io, .allocator = self.allocator };
        defer frames.deinit();
        var decoder: codec.ViewDecoder = .{};
        defer decoder.deinit(self.allocator);
        var counts: [6]u32 = @splat(0);
        var live_bytes: usize = 0;
        var offset: u64 = 80;
        for (0..count) |_| {
            const bytes = (try frames.next()) orelse return error.CorruptRecord;
            const views = try decoder.decode(self.allocator, bytes);
            if (views.len != 1 or views[0].generation > boundary) return error.CorruptRecord;
            const view = views[0];
            const index = typeIndex(view.record_type);
            counts[index] = std.math.add(u32, counts[index], 1) catch return error.ResourceLimit;
            live_bytes = std.math.add(usize, live_bytes, view.key.len + view.payload.len) catch return error.ResourceLimit;
            if (live_bytes > self.options.max_live_bytes) return error.ResourceLimit;
            offset += bytes.len;
        }
        if (offset != size) return error.CorruptRecord;
        for (&self.maps, counts) |*map, capacity| try map.ensureTotalCapacity(self.allocator, capacity);
        frames.start = 0;
        frames.end = 0;
        frames.offset = 80;
        const nodes = try self.allocator.alloc(*ordered.Node, @intCast(count));
        defer self.allocator.free(nodes);
        var starts: [6]usize = @splat(0);
        for (1..6) |index| starts[index] = starts[index - 1] + counts[index - 1];
        var loaded: [6]usize = @splat(0);
        var sorted: [6]bool = @splat(true);
        for (0..count) |_| {
            const bytes = (try frames.next()) orelse return error.CorruptRecord;
            const views = try decoder.decode(self.allocator, bytes);
            if (views.len != 1 or views[0].generation > boundary) return error.CorruptRecord;
            const view = views[0];
            const index = typeIndex(view.record_type);
            const map = &self.maps[index];
            if (loaded[index] >= counts[index]) return error.CorruptRecord;
            if (map.contains(view.key)) return error.CorruptRecord;
            const node = try self.allocator.create(ordered.Node);
            errdefer self.allocator.destroy(node);
            const key = try self.allocator.dupe(u8, view.key);
            errdefer self.allocator.free(key);
            node.* = .{
                .key = key,
                .payload = try self.allocator.dupe(u8, view.payload),
                .generation = view.generation,
                .tombstone = view.tombstone,
            };
            // Map owns all loaded nodes even before AVL construction, so open's
            // error cleanup also covers partial loads and duplicate records.
            map.putAssumeCapacityNoClobber(key, node);
            const position = starts[index] + loaded[index];
            if (loaded[index] != 0 and std.mem.order(u8, nodes[position - 1].key, key) != .lt) {
                sorted[index] = false;
            }
            nodes[position] = node;
            loaded[index] += 1;
        }
        for (&self.indexes, 0..) |*index, namespace| {
            const items = nodes[starts[namespace]..][0..loaded[namespace]];
            // v1/v2 do not promise ordering. New snapshots are sorted, but only
            // skip sorting after checking actual order while loading the file.
            if (!sorted[namespace]) {
                std.mem.sort(*ordered.Node, items, {}, struct {
                    fn less(_: void, left: *ordered.Node, right: *ordered.Node) bool {
                        return std.mem.order(u8, left.key, right.key) == .lt;
                    }
                }.less);
            }
            index.buildSorted(items);
        }
        self.counters.records = @intCast(count);
        self.counters.live_bytes = live_bytes;
    }

    fn replay(self: *Engine, file: std.Io.File, base: u64) !struct { generation: u64, length: u64 } {
        var previous = base;
        var offset: u64 = 80;
        var frames: FrameReader = .{ .file = file, .io = self.io, .allocator = self.allocator };
        defer frames.deinit();
        while (try frames.next()) |bytes| {
            const header = try codec.decodeHeader(bytes[0..64]);
            const expected = std.math.add(u64, previous, 1) catch return error.CorruptRecord;
            if (header.generation != expected) return error.CorruptRecord;
            const entries = try codec.decode(self.allocator, bytes);
            var transferred = false;
            defer if (transferred) self.allocator.free(entries) else codec.freeEntries(self.allocator, entries);
            if (header.generation > self.counters.checkpoint_generation) {
                const nodes = try self.reserve(entries);
                defer self.allocator.free(nodes);
                for (entries, nodes) |entry, node| self.publish(entry, node);
                transferred = true;
                self.generation = header.generation;
            }
            self.counters.recovered_frames += 1;
            previous = header.generation;
            offset += bytes.len;
        }
        return .{ .generation = previous, .length = offset };
    }

    fn reserve(self: *Engine, entries: []const codec.Entry) ![]?*ordered.Node {
        var counts = @as([6]u32, @splat(0));
        var record_count = self.counters.records;
        var live_bytes = self.counters.live_bytes;
        for (entries) |entry| {
            const index = typeIndex(entry.record_type);
            if (self.maps[index].get(entry.record.key)) |old| {
                live_bytes -= old.key.len + old.payload.len;
            } else {
                record_count += 1;
                counts[index] += 1;
            }
            live_bytes = std.math.add(usize, live_bytes, entry.record.key.len + entry.record.payload.len) catch return error.ResourceLimit;
        }
        if (record_count > self.options.max_records or live_bytes > self.options.max_live_bytes) return error.ResourceLimit;
        for (&self.maps, counts) |*map, count| try map.ensureUnusedCapacity(self.allocator, count);
        const nodes = try self.allocator.alloc(?*ordered.Node, entries.len);
        errdefer self.allocator.free(nodes);
        var created: usize = 0;
        errdefer for (nodes[0..created]) |node| if (node) |value| self.allocator.destroy(value);
        for (entries, nodes) |entry, *node| {
            node.* = if (self.maps[typeIndex(entry.record_type)].contains(entry.record.key)) null else try self.allocator.create(ordered.Node);
            if (node.*) |value| value.* = .{ .key = entry.record.key };
            created += 1;
        }
        return nodes;
    }

    fn publish(self: *Engine, entry: codec.Entry, candidate: ?*ordered.Node) void {
        const index = typeIndex(entry.record_type);
        const map = &self.maps[index];
        if (map.get(entry.record.key)) |node| {
            self.counters.live_bytes -= node.key.len + node.payload.len;
            // Commit preparation borrows the stable key; recovery owns a decoded copy.
            if (entry.record.key.ptr != node.key.ptr) self.allocator.free(entry.record.key);
            // A pinned payload transfers to the checkpoint view. After this
            // exchange the view may free it, so never read it again here.
            if (!node.snapshot_pinned.swap(false, .acq_rel)) self.allocator.free(node.payload);
            node.payload = entry.record.payload;
            node.generation = entry.record.generation;
            node.tombstone = entry.record.tombstone;
        } else {
            const node = candidate.?;
            node.payload = entry.record.payload;
            node.generation = entry.record.generation;
            node.tombstone = entry.record.tombstone;
            self.indexes[index].upsert(self.allocator, node);
            map.putAssumeCapacityNoClobber(node.key, node);
            self.counters.records += 1;
        }
        self.counters.live_bytes += entry.record.key.len + entry.record.payload.len;
        self.counters.dirty_bytes +|= entry.record.key.len + entry.record.payload.len;
    }

    fn lockState(self: *Engine) void {
        const start = timing.begin(self.options.diagnostics, self.io);
        self.mutex.lockUncancelable(self.io);
        self.counters.phases.lock_wait.record(self.io, start);
        self.state_lock_start = timing.begin(self.options.diagnostics, self.io);
    }

    fn unlockState(self: *Engine) void {
        self.counters.phases.lock_hold.record(self.io, self.state_lock_start);
        self.mutex.unlock(self.io);
    }

    pub fn stats(self: *Engine) Stats {
        self.lockState();
        defer self.unlockState();
        var result = self.counters;
        result.generation = self.generation;
        result.active_wal_bytes = self.wal_length;
        result.recovery_required = self.recovery_required;
        return result;
    }

    /// Bounded keyset pagination: O(log N + limit) ordered-index traversal.
    /// Pages are individually consistent. expected_generation can reject changes
    /// between pages; without it, concurrent writes have ordinary keyset semantics.
    pub fn scanPage(
        self: *Engine,
        allocator: std.mem.Allocator,
        record_type: Type,
        options: query.ScanOptions,
    ) port.Error!query.Page {
        self.lockState();
        defer self.unlockState();
        if (self.recovery_required) return error.Unavailable;
        if (options.limit == 0 or options.limit > self.options.max_page_records or
            options.max_bytes == 0 or options.max_bytes > self.options.max_page_bytes or
            options.prefix.len > codec.Limits.max_key_bytes) return error.ResourceLimit;
        if (options.expected_generation) |expected| {
            if (self.generation != expected) return error.Conflict;
        }
        var records: std.ArrayList(port.Record) = .empty;
        errdefer {
            for (records.items) |record| record.deinit(allocator);
            records.deinit(allocator);
        }
        const index = typeIndex(record_type);
        var seek_key = options.prefix;
        var exclusive = false;
        if (options.start_after) |after| {
            if (std.mem.order(u8, after, options.prefix) != .lt) {
                seek_key = after;
                exclusive = true;
            }
        }
        var iterator = self.indexes[index].iterator(seek_key, exclusive);
        var key = iterator.next();
        var visited: usize = 0;
        var bytes: usize = 0;
        var last: ?[]const u8 = null;
        while (key) |current| {
            if (!std.mem.startsWith(u8, current, options.prefix)) {
                key = null;
                break;
            }
            if (visited == options.limit) break;
            const record = self.maps[index].get(current).?;
            if (options.include_tombstones or !record.tombstone) {
                const size = record.key.len + record.payload.len;
                if (size > options.max_bytes - bytes) {
                    if (visited == 0) return error.ResourceLimit;
                    break;
                }
                const copy = try clone(allocator, record.record());
                errdefer copy.deinit(allocator);
                try records.append(allocator, copy);
                bytes += size;
            }
            visited += 1;
            last = current;
            key = iterator.next();
        }
        if (key) |current| {
            if (!std.mem.startsWith(u8, current, options.prefix)) key = null;
        }
        const next = if (key != null and last != null) try allocator.dupe(u8, last.?) else null;
        errdefer if (next) |value| allocator.free(value);
        return .{ .records = try records.toOwnedSlice(allocator), .next_start_after = next, .generation = self.generation, .visited = visited };
    }

    fn freeMaps(self: *Engine) void {
        self.indexes = @splat(.{});
        for (&self.maps) |*map| {
            var iterator = map.valueIterator();
            while (iterator.next()) |node| {
                node.*.record().deinit(self.allocator);
                self.allocator.destroy(node.*);
            }
            map.deinit(self.allocator);
        }
    }

    fn getImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        record_type: Type,
        key: []const u8,
    ) port.Error!port.Record {
        const self: *Engine = @ptrCast(@alignCast(context));
        if (!codec.validKey(key)) return error.InvalidKey;
        self.lockState();
        defer self.unlockState();
        if (self.recovery_required) return error.Unavailable;
        const record = self.maps[typeIndex(record_type)].get(key) orelse return error.NotFound;
        return clone(allocator, record.record());
    }

    fn putImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        record_type: Type,
        key: []const u8,
        expected: port.ExpectedGeneration,
        payload: []const u8,
    ) port.Error!u64 {
        _ = allocator; // Persistent memory belongs to the engine allocator.
        const self: *Engine = @ptrCast(@alignCast(context));
        return self.commit(&.{.{ .record_type = record_type, .key = key, .expected = expected, .payload = payload }});
    }

    fn tombstoneImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        record_type: Type,
        key: []const u8,
        expected: port.ExpectedGeneration,
    ) port.Error!u64 {
        _ = allocator;
        const self: *Engine = @ptrCast(@alignCast(context));
        return self.commit(&.{.{ .record_type = record_type, .key = key, .expected = expected, .tombstone = true }});
    }

    fn scanImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        record_type: Type,
    ) port.Error!port.ScanResult {
        const self: *Engine = @ptrCast(@alignCast(context));
        self.lockState();
        defer self.unlockState();
        if (self.recovery_required) return error.Unavailable;
        var records: std.ArrayList(port.Record) = .empty;
        errdefer {
            for (records.items) |record| record.deinit(allocator);
            records.deinit(allocator);
        }
        const index = typeIndex(record_type);
        try records.ensureTotalCapacityPrecise(allocator, self.maps[index].count());
        var iterator = self.indexes[index].iterator("", false);
        while (iterator.next()) |key| {
            const copy = try clone(allocator, self.maps[index].get(key).?.record());
            records.appendAssumeCapacity(copy);
        }
        return .{ .records = try records.toOwnedSlice(allocator) };
    }
};

fn typeIndex(record_type: Type) usize {
    return @backingInt(record_type) - 1;
}

fn clone(allocator: std.mem.Allocator, record: port.Record) !port.Record {
    const key = try allocator.dupe(u8, record.key);
    errdefer allocator.free(key);
    return .{
        .key = key,
        .payload = try allocator.dupe(u8, record.payload),
        .generation = record.generation,
        .tombstone = record.tombstone,
    };
}

fn fileHeader(magic: *const [8]u8, database_id: [16]u8, generation: u64, count: u64) [80]u8 {
    var bytes = @as([80]u8, @splat(0));
    @memcpy(bytes[0..8], magic);
    std.mem.writeInt(u16, bytes[8..10], 2, .little);
    std.mem.writeInt(u64, bytes[16..24], generation, .little);
    std.mem.writeInt(u64, bytes[24..32], count, .little);
    @memcpy(bytes[32..48], &database_id);
    std.crypto.hash.sha2.Sha256.hash(bytes[0..48], bytes[48..80], .{});
    return bytes;
}

fn readFileHeader(file: std.Io.File, io: std.Io, magic: *const [8]u8) !struct { database_id: [16]u8, generation: u64, count: u64 } {
    var bytes: [80]u8 = undefined;
    if (try file.readPositionalAll(io, &bytes, 0) != bytes.len) return error.CorruptRecord;
    if (!std.mem.eql(u8, bytes[0..8], magic)) return error.CorruptRecord;
    const version = std.mem.readInt(u16, bytes[8..10], .little);
    if (version != 1 and version != 2) return error.UnsupportedFormat;
    if (!std.mem.allEqual(u8, bytes[10..16], 0)) return error.CorruptRecord;
    var checksum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..48], &checksum, .{});
    if (!std.mem.eql(u8, &checksum, bytes[48..80])) return error.CorruptRecord;
    return .{
        .database_id = bytes[32..48].*,
        .generation = std.mem.readInt(u64, bytes[16..24], .little),
        .count = std.mem.readInt(u64, bytes[24..32], .little),
    };
}

fn mapError(err: anyerror) port.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.PayloadTooLarge => error.PayloadTooLarge,
        error.InvalidKey => error.InvalidKey,
        error.ResourceLimit => error.ResourceLimit,
        else => error.CorruptRecord,
    };
}

/// Returned frames borrow the buffer until next(). Header validation precedes
/// large allocations; short reads mean an incomplete tail, not a valid frame.
const FrameReader = struct {
    file: std.Io.File,
    io: std.Io,
    allocator: std.mem.Allocator,
    buffer: [64 * 1024]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    offset: u64 = 80,
    large: std.ArrayList(u8) = .empty,

    fn deinit(self: *FrameReader) void {
        self.large.deinit(self.allocator);
    }

    fn fill(self: *FrameReader, needed: usize) !bool {
        if (self.end - self.start >= needed) return true;
        const remaining = self.end - self.start;
        std.mem.copyForwards(u8, self.buffer[0..remaining], self.buffer[self.start..self.end]);
        self.start = 0;
        self.end = remaining;
        const count = try self.file.readPositionalAll(self.io, self.buffer[remaining..], self.offset);
        self.offset += count;
        self.end += count;
        return self.end >= needed;
    }

    fn next(self: *FrameReader) !?[]const u8 {
        if (!try self.fill(codec.header_length)) return null;
        const header = try codec.decodeHeader(self.buffer[self.start..][0..64]);
        if (header.length <= self.buffer.len) {
            if (!try self.fill(header.length)) return null;
            const frame = self.buffer[self.start..][0..header.length];
            self.start += header.length;
            return frame;
        }
        try self.large.resize(self.allocator, header.length);
        const remaining = self.end - self.start;
        @memcpy(self.large.items[0..remaining], self.buffer[self.start..self.end]);
        self.start = self.end;
        const count = try self.file.readPositionalAll(self.io, self.large.items[remaining..], self.offset);
        self.offset += count;
        if (count != header.length - remaining) return null;
        return self.large.items;
    }
};
