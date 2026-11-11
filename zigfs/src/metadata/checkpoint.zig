const std = @import("std");
const format = @import("format.zig");
const generation = @import("generation.zig");
const durable = @import("durable.zig");
const fault = @import("../common/fault_injection.zig");

pub const path = ".zigfs/journal/checkpoint.meta";
pub const encoded_length = 72;
const magic = "ZFSCKP01";
pub const Error = error{ CorruptJournal, Unavailable };

pub fn load(root: std.Io.Dir, io: std.Io) Error!u64 {
    var format_buffer: [format.encoded_length + 1]u8 = undefined;
    const metadata: ?format.Metadata = if (root.readFile(io, format.path, &format_buffer)) |bytes|
        format.decode(bytes) catch return error.CorruptJournal
    else |err| switch (err) {
        error.FileNotFound => null,
        else => return error.Unavailable,
    };
    var buffer: [encoded_length + 1]u8 = undefined;
    const bytes = root.readFile(io, path, &buffer) catch |err| switch (err) {
        error.FileNotFound => {
            if (metadata != null and metadata.?.checkpoints) return error.CorruptJournal;
            return 0;
        },
        else => return error.Unavailable,
    };
    if (metadata == null or bytes.len != encoded_length) return error.CorruptJournal;
    if (!std.mem.eql(u8, bytes[0..8], magic) or
        std.mem.readInt(u64, bytes[8..16], .little) != 1 or
        !std.mem.eql(u8, bytes[24..40], &metadata.?.instance_id)) return error.CorruptJournal;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..40], &digest, .{});
    if (!std.mem.eql(u8, &digest, bytes[40..72])) return error.CorruptJournal;
    const boundary = std.mem.readInt(u64, bytes[16..24], .little);
    const last = generation.load(root, io) catch return error.CorruptJournal;
    if (last < boundary) return error.CorruptJournal;
    return boundary;
}

// The caller holds the repository commit barrier and has proved that all
// transactions through boundary are resolved and their publications durable.
pub fn publish(root: std.Io.Dir, io: std.Io, boundary: u64, injector: fault.Injector) Error!void {
    if (boundary < try load(root, io)) return error.CorruptJournal;
    var format_buffer: [format.encoded_length + 1]u8 = undefined;
    const metadata = format.decode(root.readFile(io, format.path, &format_buffer) catch return error.Unavailable) catch return error.CorruptJournal;
    var bytes: [encoded_length]u8 = @splat(0);
    @memcpy(bytes[0..8], magic);
    std.mem.writeInt(u64, bytes[8..16], 1, .little);
    std.mem.writeInt(u64, bytes[16..24], boundary, .little);
    @memcpy(bytes[24..40], &metadata.instance_id);
    std.crypto.hash.sha2.Sha256.hash(bytes[0..40], bytes[40..72], .{});
    var file = root.createFileAtomic(io, path, .{ .replace = true }) catch return error.Unavailable;
    defer file.deinit(io);
    file.file.writeStreamingAll(io, &bytes) catch return error.Unavailable;
    if (injector.trigger(.checkpoint_written)) return error.Unavailable;
    file.file.sync(io) catch return error.Unavailable;
    if (injector.trigger(.checkpoint_synced)) return error.Unavailable;
    file.replace(io) catch return error.Unavailable;
    if (injector.trigger(.checkpoint_published)) return error.Unavailable;
    durable.syncParent(root, io, path) catch return error.Unavailable;
    if (injector.trigger(.checkpoint_durable)) return error.Unavailable;
    format.enableCheckpoints(root, io) catch return error.Unavailable;
    if (injector.trigger(.checkpoint_format_enabled)) return error.Unavailable;
}
