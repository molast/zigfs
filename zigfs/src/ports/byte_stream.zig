const std = @import("std");

pub const Source = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{ReadFailed};

    pub const VTable = struct {
        read: *const fn (context: *anyopaque, buffer: []u8) Error!usize,
    };

    pub fn read(self: Source, buffer: []u8) Error!usize {
        return self.vtable.read(self.context, buffer);
    }
};

pub const Sink = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{ WriteFailed, OutOfMemory };

    pub const VTable = struct {
        write_all: *const fn (context: *anyopaque, bytes: []const u8) Error!void,
    };

    pub fn writeAll(self: Sink, bytes: []const u8) Error!void {
        return self.vtable.write_all(self.context, bytes);
    }
};

test "byte stream interfaces preserve incremental reads and writes" {
    const TestStream = struct {
        source_bytes: []const u8,
        source_offset: usize = 0,
        written: [8]u8 = undefined,
        written_length: usize = 0,

        fn source(self: *@This()) Source {
            return .{ .context = self, .vtable = &.{ .read = read } };
        }

        fn sink(self: *@This()) Sink {
            return .{ .context = self, .vtable = &.{ .write_all = writeAll } };
        }

        fn read(context: *anyopaque, buffer: []u8) Source.Error!usize {
            const self: *@This() = @ptrCast(@alignCast(context));
            const length = @min(buffer.len, self.source_bytes.len - self.source_offset);
            @memcpy(buffer[0..length], self.source_bytes[self.source_offset..][0..length]);
            self.source_offset += length;
            return length;
        }

        fn writeAll(context: *anyopaque, bytes: []const u8) Sink.Error!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.written_length + bytes.len > self.written.len) return error.WriteFailed;
            @memcpy(self.written[self.written_length..][0..bytes.len], bytes);
            self.written_length += bytes.len;
        }
    };

    var stream: TestStream = .{ .source_bytes = "zigfs" };
    var buffer: [3]u8 = undefined;
    while (true) {
        const length = try stream.source().read(&buffer);
        if (length == 0) break;
        try stream.sink().writeAll(buffer[0..length]);
    }
    try std.testing.expectEqualStrings("zigfs", stream.written[0..stream.written_length]);
}
