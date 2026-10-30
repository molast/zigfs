const std = @import("std");
const byte_stream = @import("../ports/byte_stream.zig");
const secret_box = @import("../auth/secret_box.zig");
const frames = @import("object_encryption_frames.zig");
const checksum = @import("../common/checksum.zig");

pub const Error = std.mem.Allocator.Error || std.Io.RandomSecureError || error{
    SourceReadFailed,
    SinkWriteFailed,
    SizeOverflow,
};

pub const Result = struct {
    plaintext_size: u64,
    frame_count: u64,
    etag_md5: [16]u8,
    checksum_crc32: u32,
    checksum_crc32c: u32,
    checksum_sha256: [32]u8,
    checksum_sha1: [20]u8,
    checksum_crc64nvme: u64,
};

/// Encrypts a source as authenticated frames without buffering the full object.
/// The caller owns the DEK and supplies object-bound associated data.
pub fn sealSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    key: secret_box.Key,
    associated_data: []const u8,
    source: byte_stream.Source,
    sink: byte_stream.Sink,
) Error!Result {
    const buffer = allocator.alloc(u8, frames.plaintext_frame_size) catch return error.OutOfMemory;
    defer allocator.free(buffer);
    var frame_index: u64 = 0;
    var plaintext_size: u64 = 0;
    var buffered: usize = 0;
    var md5 = std.crypto.hash.Md5.init(.{});
    var crc32 = checksum.Crc32.init();
    var crc32c = checksum.Crc32C.init();
    var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
    var sha1 = checksum.Sha1.init(.{});
    var crc64nvme = checksum.Crc64Nvme.init();
    while (true) {
        const count = source.read(buffer[buffered..]) catch return error.SourceReadFailed;
        if (count > buffer.len - buffered) return error.SourceReadFailed;
        if (count == 0) {
            if (buffered == 0 and frame_index == 0) {
                try writeFrame(allocator, io, key, associated_data, frame_index, buffer[0..0], sink);
                frame_index += 1;
            } else if (buffered > 0) {
                try writeFrame(allocator, io, key, associated_data, frame_index, buffer[0..buffered], sink);
                frame_index += 1;
                plaintext_size = std.math.add(u64, plaintext_size, buffered) catch return error.SizeOverflow;
            }
            break;
        }
        buffered += count;
        const read_bytes = buffer[buffered - count .. buffered];
        md5.update(read_bytes);
        crc32.update(read_bytes);
        crc32c.update(read_bytes);
        sha256.update(read_bytes);
        sha1.update(read_bytes);
        crc64nvme.update(read_bytes);
        if (buffered == buffer.len) {
            try writeFrame(allocator, io, key, associated_data, frame_index, buffer, sink);
            frame_index += 1;
            plaintext_size = std.math.add(u64, plaintext_size, buffered) catch return error.SizeOverflow;
            buffered = 0;
        }
    }
    var etag_md5: [16]u8 = undefined;
    md5.final(&etag_md5);
    var checksum_sha256: [32]u8 = undefined;
    sha256.final(&checksum_sha256);
    var checksum_sha1: [20]u8 = undefined;
    sha1.final(&checksum_sha1);
    return .{
        .plaintext_size = plaintext_size,
        .frame_count = frame_index,
        .etag_md5 = etag_md5,
        .checksum_crc32 = crc32.final(),
        .checksum_crc32c = crc32c.final(),
        .checksum_sha256 = checksum_sha256,
        .checksum_sha1 = checksum_sha1,
        .checksum_crc64nvme = crc64nvme.final(),
    };
}

fn writeFrame(
    allocator: std.mem.Allocator,
    io: std.Io,
    key: secret_box.Key,
    associated_data: []const u8,
    index: u64,
    plaintext: []const u8,
    sink: byte_stream.Sink,
) Error!void {
    const frame = frames.seal(allocator, io, key, associated_data, index, plaintext) catch return error.SinkWriteFailed;
    defer frame.deinit(allocator);
    const header = frames.encodeHeader(frame) catch return error.SinkWriteFailed;
    sink.writeAll(&header) catch return error.SinkWriteFailed;
    sink.writeAll(frame.ciphertext) catch return error.SinkWriteFailed;
}

test "encrypted stream emits an authenticated empty frame" {
    const test_streams = @import("../testing/streams.zig");
    const key = @as([@sizeOf(secret_box.Key)]u8, @splat(0x37));
    var source = test_streams.SliceSource.init("");
    var sink = test_streams.CollectingSink.init(std.testing.allocator);
    defer sink.deinit();
    const result = try sealSource(std.testing.allocator, std.testing.io, key, "object-ad", source.interface(), sink.interface());
    try std.testing.expectEqual(@as(u64, 0), result.plaintext_size);
    try std.testing.expectEqual(@as(u64, 1), result.frame_count);
    try std.testing.expectEqual(frames.header_length, sink.bytes.items.len);
}
