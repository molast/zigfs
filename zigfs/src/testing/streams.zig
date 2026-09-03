const std = @import("std");
const byte_stream = @import("../ports/byte_stream.zig");

pub const SliceSource = struct {
    bytes: []const u8,
    offset: usize = 0,

    pub fn init(bytes: []const u8) SliceSource {
        return .{ .bytes = bytes };
    }

    pub fn interface(self: *SliceSource) byte_stream.Source {
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

pub const RepeatingSource = struct {
    remaining: u64,
    byte: u8,

    pub fn init(size: u64, byte: u8) RepeatingSource {
        return .{ .remaining = size, .byte = byte };
    }

    pub fn interface(self: *RepeatingSource) byte_stream.Source {
        return .{ .context = self, .vtable = &.{ .read = read } };
    }

    fn read(context: *anyopaque, buffer: []u8) byte_stream.Source.Error!usize {
        const self: *RepeatingSource = @ptrCast(@alignCast(context));
        const length: usize = @intCast(@min(self.remaining, buffer.len));
        @memset(buffer[0..length], self.byte);
        self.remaining -= length;
        return length;
    }
};

pub const CollectingSink = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) CollectingSink {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CollectingSink) void {
        self.bytes.deinit(self.allocator);
    }

    pub fn interface(self: *CollectingSink) byte_stream.Sink {
        return .{ .context = self, .vtable = &.{ .write_all = writeAll } };
    }

    fn writeAll(context: *anyopaque, bytes: []const u8) byte_stream.Sink.Error!void {
        const self: *CollectingSink = @ptrCast(@alignCast(context));
        self.bytes.appendSlice(self.allocator, bytes) catch return error.OutOfMemory;
    }
};

pub const CountingSink = struct {
    size: u64 = 0,

    pub fn interface(self: *CountingSink) byte_stream.Sink {
        return .{ .context = self, .vtable = &.{ .write_all = writeAll } };
    }

    fn writeAll(context: *anyopaque, bytes: []const u8) byte_stream.Sink.Error!void {
        const self: *CountingSink = @ptrCast(@alignCast(context));
        self.size = std.math.add(u64, self.size, bytes.len) catch return error.WriteFailed;
    }
};

pub const FailingSource = struct {
    pub fn interface(self: *FailingSource) byte_stream.Source {
        return .{ .context = self, .vtable = &.{ .read = read } };
    }

    fn read(_: *anyopaque, _: []u8) byte_stream.Source.Error!usize {
        return error.ReadFailed;
    }
};
