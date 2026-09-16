const std = @import("std");
const metadata_record = @import("record.zig");
const id = @import("../common/id.zig");

pub const max_path_length: usize = 160;

pub fn typeDirectory(record_type: metadata_record.Type) []const u8 {
    return switch (record_type) {
        .system => ".zigfs/system/configuration/records",
        .bucket => "metadata/buckets",
        .object => "metadata/objects",
        .multipart => "metadata/multipart",
        .credential => ".zigfs/system/credentials",
        .directory => "metadata/directories",
    };
}

pub fn hashKey(key: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});
    return digest;
}

pub fn recordPath(
    record_type: metadata_record.Type,
    key_hash: [32]u8,
    buffer: *[max_path_length]u8,
) error{NoSpaceLeft}![]const u8 {
    const key_hex = std.fmt.bytesToHex(key_hash, .lower);
    return std.fmt.bufPrint(
        buffer,
        "{s}/{s}.record",
        .{ typeDirectory(record_type), &key_hex },
    );
}

pub fn temporaryPath(
    generation: u64,
    transaction_id: id.Uuid,
    buffer: *[max_path_length]u8,
) error{NoSpaceLeft}![]const u8 {
    const transaction_hex = std.fmt.bytesToHex(transaction_id, .lower);
    return std.fmt.bufPrint(
        buffer,
        ".zigfs/tmp/{d:0>20}-{s}.record",
        .{ generation, &transaction_hex },
    );
}
