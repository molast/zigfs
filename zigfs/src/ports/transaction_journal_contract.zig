const std = @import("std");
const id = @import("../common/id.zig");
const journal_port = @import("transaction_journal.zig");

pub fn run(journal: journal_port.TransactionJournal) !void {
    const transaction_id: id.Uuid = .{ 0, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 };
    const base: journal_port.Entry = .{
        .transaction_id = transaction_id,
        .state = .intent,
        .record_type = .bucket,
        .generation = 7,
        .previous_generation = null,
        .key_hash = [_]u8{0x44} ** 32,
    };
    try journal.append(base);
    var committed = base;
    committed.state = .commit;
    try journal.append(committed);
    try journal.append(committed);
    var aborted = base;
    aborted.state = .abort;
    aborted.generation = 8;
    try journal.append(aborted);

    const result = try journal.scan(std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), result.entries.len);
    try std.testing.expectEqual(journal_port.State.intent, result.entries[0].state);
    try std.testing.expectEqual(journal_port.State.commit, result.entries[1].state);
    try std.testing.expectEqual(journal_port.State.abort, result.entries[2].state);
    try std.testing.expectEqual(@as(u64, 7), result.entries[0].generation);
}
