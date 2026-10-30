const std = @import("std");
const durable = @import("durable.zig");
const journal_record = @import("journal_record.zig");
const journal_port = @import("../ports/transaction_journal.zig");

pub const LocalTransactionJournal = struct {
    root: std.Io.Dir,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    pub fn init(root: std.Io.Dir, io: std.Io) LocalTransactionJournal {
        return .{ .root = root, .io = io };
    }

    pub fn interface(self: *LocalTransactionJournal) journal_port.TransactionJournal {
        return .{ .context = self, .vtable = &.{
            .append = appendImpl,
            .scan = scanImpl,
        } };
    }

    fn appendImpl(context: *anyopaque, entry: journal_port.Entry) journal_port.Error!void {
        const self: *LocalTransactionJournal = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const bytes = journal_record.encode(entry);
        var path_buffer: [160]u8 = undefined;
        const path = journalPath(entry, &path_buffer) catch return error.Unavailable;

        var atomic_file = self.root.createFileAtomic(self.io, path, .{ .replace = false }) catch {
            return error.Unavailable;
        };
        defer atomic_file.deinit(self.io);
        atomic_file.file.writeStreamingAll(self.io, &bytes) catch return error.Unavailable;
        atomic_file.file.sync(self.io) catch return error.Unavailable;
        atomic_file.link(self.io) catch |err| switch (err) {
            error.PathAlreadyExists => {
                var existing_buffer: [journal_record.encoded_length + 1]u8 = undefined;
                const existing = self.root.readFile(self.io, path, &existing_buffer) catch {
                    return error.Unavailable;
                };
                if (!std.mem.eql(u8, existing, &bytes)) return error.CorruptJournal;
            },
            else => return error.Unavailable,
        };
        durable.syncParent(self.root, self.io, path) catch return error.Unavailable;
    }

    fn scanImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
    ) journal_port.Error!journal_port.ScanResult {
        const self: *LocalTransactionJournal = @ptrCast(@alignCast(context));
        var journal_dir = self.root.openDir(self.io, ".zigfs/journal", .{ .iterate = true }) catch {
            return error.Unavailable;
        };
        defer journal_dir.close(self.io);

        var entries: std.ArrayList(journal_port.Entry) = .empty;
        errdefer entries.deinit(allocator);
        var iterator = journal_dir.iterate();
        while (iterator.next(self.io) catch return error.Unavailable) |directory_entry| {
            if (directory_entry.kind != .file or
                !std.mem.endsWith(u8, directory_entry.name, ".journal"))
            {
                continue;
            }
            var buffer: [journal_record.encoded_length + 1]u8 = undefined;
            const bytes = journal_dir.readFile(self.io, directory_entry.name, &buffer) catch {
                return error.Unavailable;
            };
            const decoded = journal_record.decode(bytes) catch return error.CorruptJournal;
            var expected_path_buffer: [160]u8 = undefined;
            const expected_path = journalPath(decoded, &expected_path_buffer) catch {
                return error.CorruptJournal;
            };
            if (!std.mem.eql(u8, directory_entry.name, std.fs.path.basename(expected_path))) {
                return error.CorruptJournal;
            }
            entries.append(allocator, decoded) catch return error.OutOfMemory;
        }
        std.mem.sort(journal_port.Entry, entries.items, {}, lessThan);
        return .{ .entries = entries.toOwnedSlice(allocator) catch return error.OutOfMemory };
    }

    fn lessThan(_: void, left: journal_port.Entry, right: journal_port.Entry) bool {
        if (left.generation != right.generation) return left.generation < right.generation;
        const transaction_order = std.mem.order(u8, &left.transaction_id, &right.transaction_id);
        if (transaction_order != .eq) return transaction_order == .lt;
        return @intFromEnum(left.state) < @intFromEnum(right.state);
    }
};

fn journalPath(entry: journal_port.Entry, buffer: *[160]u8) error{NoSpaceLeft}![]const u8 {
    const transaction_hex = std.fmt.bytesToHex(entry.transaction_id, .lower);
    return std.fmt.bufPrint(
        buffer,
        ".zigfs/journal/{d:0>20}-{s}-{d}.journal",
        .{ entry.generation, &transaction_hex, @intFromEnum(entry.state) },
    );
}

test "local journal passes shared contract" {
    const contract = @import("../ports/transaction_journal_contract.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".zigfs/journal");

    var local = LocalTransactionJournal.init(tmp.dir, std.testing.io);
    try contract.run(local.interface());
}

test "local journal detects corrupt entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".zigfs/journal");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".zigfs/journal/corrupt.journal",
        .data = "not a journal record",
    });

    var local = LocalTransactionJournal.init(tmp.dir, std.testing.io);
    try std.testing.expectError(
        error.CorruptJournal,
        local.interface().scan(std.testing.allocator),
    );
}

test "local journal rejects a valid entry under the wrong name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".zigfs/journal");
    const bytes = journal_record.encode(.{
        .transaction_id = .{ 0, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
        .state = .intent,
        .record_type = .bucket,
        .generation = 1,
        .previous_generation = null,
        .key_hash = @as([32]u8, @splat(0x22)),
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".zigfs/journal/wrong-name.journal",
        .data = &bytes,
    });

    var local = LocalTransactionJournal.init(tmp.dir, std.testing.io);
    try std.testing.expectError(
        error.CorruptJournal,
        local.interface().scan(std.testing.allocator),
    );
}
