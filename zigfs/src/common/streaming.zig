const std = @import("std");
const byte_stream = @import("../ports/byte_stream.zig");
const checksum = @import("checksum.zig");
const Crc32 = checksum.Crc32;
const Crc32C = checksum.Crc32C;
const Crc64Nvme = checksum.Crc64Nvme;
const Sha1 = checksum.Sha1;

pub const min_buffer_size: usize = 4 * 1024;
pub const default_buffer_size: usize = 64 * 1024;
pub const max_buffer_size: usize = 1024 * 1024;

pub const Result = struct {
    size: u64,
    etag_md5: [16]u8,
    checksum_crc32: u32,
    checksum_crc32c: u32,
    checksum_sha256: [32]u8,
    checksum_sha1: [20]u8,
    checksum_crc64nvme: u64,
};

pub const Error = error{
    OutOfMemory,
    InvalidBufferSize,
    SourceReadFailed,
    SinkWriteFailed,
    SizeOverflow,
};

pub fn copyAndHash(
    allocator: std.mem.Allocator,
    buffer_size: usize,
    source: byte_stream.Source,
    sink: byte_stream.Sink,
) Error!Result {
    if (buffer_size < min_buffer_size or buffer_size > max_buffer_size) {
        return error.InvalidBufferSize;
    }
    const buffer = allocator.alloc(u8, buffer_size) catch return error.OutOfMemory;
    defer allocator.free(buffer);

    var md5 = std.crypto.hash.Md5.init(.{});
    var crc32 = Crc32.init();
    var crc32c = Crc32C.init();
    var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
    var sha1 = Sha1.init(.{});
    var crc64nvme = Crc64Nvme.init();
    var size: u64 = 0;
    while (true) {
        const length = source.read(buffer) catch return error.SourceReadFailed;
        if (length > buffer.len) return error.SourceReadFailed;
        if (length == 0) break;
        const bytes = buffer[0..length];
        sink.writeAll(bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.WriteFailed => return error.SinkWriteFailed,
        };
        md5.update(bytes);
        crc32.update(bytes);
        crc32c.update(bytes);
        sha256.update(bytes);
        sha1.update(bytes);
        crc64nvme.update(bytes);
        size = std.math.add(u64, size, length) catch return error.SizeOverflow;
    }

    var etag_md5: [16]u8 = undefined;
    md5.final(&etag_md5);
    var checksum_sha256: [32]u8 = undefined;
    sha256.final(&checksum_sha256);
    var checksum_sha1: [20]u8 = undefined;
    sha1.final(&checksum_sha1);
    return .{
        .size = size,
        .etag_md5 = etag_md5,
        .checksum_crc32 = crc32.final(),
        .checksum_crc32c = crc32c.final(),
        .checksum_sha256 = checksum_sha256,
        .checksum_sha1 = checksum_sha1,
        .checksum_crc64nvme = crc64nvme.final(),
    };
}

const SliceSource = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn interface(self: *SliceSource) byte_stream.Source {
        return .{ .context = self, .vtable = &.{ .read = read } };
    }

    fn read(context: *anyopaque, buffer: []u8) byte_stream.Source.Error!usize {
        const self: *SliceSource = @ptrCast(@alignCast(context));
        const length = @min(buffer.len, self.bytes.len - self.offset);
        @memcpy(buffer[0..length], self.bytes[self.offset..][0..length]);
        self.offset += length;
        return length;
    }
};

const CountingSink = struct {
    size: u64 = 0,

    fn interface(self: *CountingSink) byte_stream.Sink {
        return .{ .context = self, .vtable = &.{ .write_all = writeAll } };
    }

    fn writeAll(context: *anyopaque, bytes: []const u8) byte_stream.Sink.Error!void {
        const self: *CountingSink = @ptrCast(@alignCast(context));
        self.size = std.math.add(u64, self.size, bytes.len) catch return error.WriteFailed;
    }
};

const RepeatingSource = struct {
    remaining: u64,
    byte: u8,
    largest_buffer: usize = 0,

    fn interface(self: *RepeatingSource) byte_stream.Source {
        return .{ .context = self, .vtable = &.{ .read = read } };
    }

    fn read(context: *anyopaque, buffer: []u8) byte_stream.Source.Error!usize {
        const self: *RepeatingSource = @ptrCast(@alignCast(context));
        self.largest_buffer = @max(self.largest_buffer, buffer.len);
        const length: usize = @intCast(@min(self.remaining, buffer.len));
        @memset(buffer[0..length], self.byte);
        self.remaining -= length;
        return length;
    }
};

test "bounded streaming calculates S3 MD5 and SHA-256" {
    var source: SliceSource = .{ .bytes = "abc" };
    var sink: CountingSink = .{};
    const result = try copyAndHash(
        std.testing.allocator,
        min_buffer_size,
        source.interface(),
        sink.interface(),
    );
    try std.testing.expectEqual(@as(u64, 3), result.size);
    try std.testing.expectEqual(@as(u64, 3), sink.size);
    const expected_md5 = std.fmt.bytesToHex(result.etag_md5, .lower);
    const expected_sha256 = std.fmt.bytesToHex(result.checksum_sha256, .lower);
    try std.testing.expectEqualStrings("900150983cd24fb0d6963f7d28e17f72", &expected_md5);
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &expected_sha256,
    );
    try std.testing.expectEqual(@as(u32, 0x352441c2), result.checksum_crc32);
    try std.testing.expectEqual(@as(u32, 0x364b3fb7), result.checksum_crc32c);
    try std.testing.expectEqual(@as(u8, 0xa9), result.checksum_sha1[0]);
    try std.testing.expectEqual(@as(u64, 0x05e5cabb3fc1faeb), result.checksum_crc64nvme);
}

test "bounded streaming handles 100 MiB and 1 GiB with fixed memory" {
    for ([_]u64{ 100 * 1024 * 1024, 1024 * 1024 * 1024 }) |size| {
        var source: RepeatingSource = .{ .remaining = size, .byte = 0x5a };
        var sink: CountingSink = .{};
        const result = try copyAndHash(
            std.testing.allocator,
            default_buffer_size,
            source.interface(),
            sink.interface(),
        );
        try std.testing.expectEqual(size, result.size);
        try std.testing.expectEqual(size, sink.size);
        try std.testing.expectEqual(default_buffer_size, source.largest_buffer);
    }
}
