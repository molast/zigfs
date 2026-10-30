const std = @import("std");
const id = @import("../common/id.zig");
const metadata_record = @import("record.zig");
const journal_port = @import("../ports/transaction_journal.zig");

pub const magic = [4]u8{ 'Z', 'F', 'J', 'N' };
pub const major_version: u16 = 1;
pub const minor_version: u16 = 0;
pub const encoded_length: usize = 112;

const state_offset: usize = 8;
const record_type_offset: usize = 9;
const flags_offset: usize = 10;
const generation_offset: usize = 12;
const previous_generation_offset: usize = 20;
const transaction_id_offset: usize = 28;
const key_hash_offset: usize = 44;
const reserved_offset: usize = 76;
const checksum_offset: usize = 80;

pub const DecodeError = error{
    InvalidLength,
    InvalidMagic,
    UnsupportedMajorVersion,
    UnsupportedFlags,
    InvalidState,
    InvalidRecordType,
    InvalidGeneration,
    InvalidTransactionId,
    ChecksumMismatch,
};

pub fn encode(entry: journal_port.Entry) [encoded_length]u8 {
    var bytes = @as([encoded_length]u8, @splat(0));
    @memcpy(bytes[0..magic.len], &magic);
    std.mem.writeInt(u16, bytes[4..6], major_version, .little);
    std.mem.writeInt(u16, bytes[6..8], minor_version, .little);
    bytes[state_offset] = @intFromEnum(entry.state);
    bytes[record_type_offset] = @intFromEnum(entry.record_type);
    std.mem.writeInt(u16, bytes[flags_offset..12], 0, .little);
    std.mem.writeInt(u64, bytes[generation_offset..20], entry.generation, .little);
    std.mem.writeInt(
        u64,
        bytes[previous_generation_offset..28],
        entry.previous_generation orelse 0,
        .little,
    );
    @memcpy(bytes[transaction_id_offset..key_hash_offset], &entry.transaction_id);
    @memcpy(bytes[key_hash_offset..reserved_offset], &entry.key_hash);
    std.mem.writeInt(u32, bytes[reserved_offset..checksum_offset], 0, .little);
    writeChecksum(&bytes);
    return bytes;
}

pub fn decode(bytes: []const u8) DecodeError!journal_port.Entry {
    if (bytes.len != encoded_length) return error.InvalidLength;
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return error.InvalidMagic;
    if (std.mem.readInt(u16, bytes[4..6], .little) != major_version) {
        return error.UnsupportedMajorVersion;
    }
    if (std.mem.readInt(u16, bytes[flags_offset..12], .little) != 0 or
        std.mem.readInt(u32, bytes[reserved_offset..checksum_offset], .little) != 0)
    {
        return error.UnsupportedFlags;
    }

    const state: journal_port.State = switch (bytes[state_offset]) {
        1 => .intent,
        2 => .commit,
        3 => .abort,
        else => return error.InvalidState,
    };
    const record_type: metadata_record.Type = switch (bytes[record_type_offset]) {
        1 => .system,
        2 => .bucket,
        3 => .object,
        4 => .multipart,
        5 => .credential,
        6 => .directory,
        else => return error.InvalidRecordType,
    };
    const generation = std.mem.readInt(u64, bytes[generation_offset..20], .little);
    if (generation == 0) return error.InvalidGeneration;

    var transaction_id: id.Uuid = undefined;
    @memcpy(&transaction_id, bytes[transaction_id_offset..key_hash_offset]);
    if (!id.isValidV4(transaction_id)) return error.InvalidTransactionId;

    var expected_checksum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..checksum_offset], &expected_checksum, .{});
    if (!std.mem.eql(u8, &expected_checksum, bytes[checksum_offset..])) {
        return error.ChecksumMismatch;
    }

    var key_hash: [32]u8 = undefined;
    @memcpy(&key_hash, bytes[key_hash_offset..reserved_offset]);
    const previous_generation = std.mem.readInt(
        u64,
        bytes[previous_generation_offset..28],
        .little,
    );
    return .{
        .transaction_id = transaction_id,
        .state = state,
        .record_type = record_type,
        .generation = generation,
        .previous_generation = if (previous_generation == 0) null else previous_generation,
        .key_hash = key_hash,
    };
}

fn writeChecksum(bytes: *[encoded_length]u8) void {
    std.crypto.hash.sha2.Sha256.hash(bytes[0..checksum_offset], bytes[checksum_offset..], .{});
}

test "journal record round trips all states" {
    const transaction_id: id.Uuid = .{ 0, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 };
    var key_hash: [32]u8 = undefined;
    @memset(&key_hash, 0xab);

    for ([_]journal_port.State{ .intent, .commit, .abort }) |state| {
        const entry: journal_port.Entry = .{
            .transaction_id = transaction_id,
            .state = state,
            .record_type = .object,
            .generation = 42,
            .previous_generation = 41,
            .key_hash = key_hash,
        };
        const decoded = try decode(&encode(entry));
        try std.testing.expectEqual(state, decoded.state);
        try std.testing.expectEqual(metadata_record.Type.object, decoded.record_type);
        try std.testing.expectEqual(@as(u64, 42), decoded.generation);
        try std.testing.expectEqual(@as(?u64, 41), decoded.previous_generation);
        try std.testing.expectEqualSlices(u8, &transaction_id, &decoded.transaction_id);
        try std.testing.expectEqualSlices(u8, &key_hash, &decoded.key_hash);
    }
}

test "journal record rejects corruption and unknown values" {
    const entry: journal_port.Entry = .{
        .transaction_id = .{ 0, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
        .state = .intent,
        .record_type = .bucket,
        .generation = 1,
        .previous_generation = null,
        .key_hash = @as([32]u8, @splat(0x11)),
    };
    const valid = encode(entry);
    try std.testing.expectError(error.InvalidLength, decode(valid[0 .. valid.len - 1]));

    var changed = valid;
    changed[0] = 'X';
    try std.testing.expectError(error.InvalidMagic, decode(&changed));

    changed = valid;
    changed[checksum_offset] ^= 0xff;
    try std.testing.expectError(error.ChecksumMismatch, decode(&changed));

    changed = valid;
    changed[state_offset] = 255;
    writeChecksum(&changed);
    try std.testing.expectError(error.InvalidState, decode(&changed));
}
