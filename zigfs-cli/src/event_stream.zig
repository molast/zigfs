//! AWS event-stream framing for SelectObjectContent. Publish only after End and CRC validation.
const std = @import("std");
const Io = std.Io;
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    pending: std.ArrayList(u8) = .empty,
    ended: bool = false,
    written: u64 = 0,
    pub fn feed(self: *Decoder, io: Io, file: Io.File, bytes: []const u8) !void {
        if (self.ended and bytes.len != 0) return error.InvalidResponse;
        if (self.pending.items.len + bytes.len > 17 * 1024 * 1024) return error.InvalidResponse;
        try self.pending.appendSlice(self.allocator, bytes);
        var offset: usize = 0;
        while (self.pending.items.len - offset >= 12) {
            const data = self.pending.items[offset..];
            const size = std.mem.readInt(u32, data[0..4], .big);
            const headers = std.mem.readInt(u32, data[4..8], .big);
            if (size < 16 or size > 16 * 1024 * 1024 or headers > size - 16 or headers > 128 * 1024) return error.InvalidResponse;
            if (std.hash.crc.@"CRC-32/ISO-HDLC".hash(data[0..8]) != std.mem.readInt(u32, data[8..12], .big)) return error.InvalidResponse;
            if (data.len < size) break;
            const frame = data[0..size];
            if (self.ended or std.hash.crc.@"CRC-32/ISO-HDLC".hash(frame[0 .. size - 4]) != std.mem.readInt(u32, frame[size - 4 ..][0..4], .big)) return error.InvalidResponse;
            var at: usize = 12;
            var kind: ?[]const u8 = null;
            var event: ?[]const u8 = null;
            while (at < 12 + headers) {
                const n = frame[at];
                at += 1;
                if (at + n + 3 > 12 + headers) return error.InvalidResponse;
                const name = frame[at..][0..n];
                at += n;
                if (frame[at] != 7) return error.InvalidResponse;
                at += 1;
                const length = std.mem.readInt(u16, frame[at..][0..2], .big);
                at += 2;
                if (at + length > 12 + headers) return error.InvalidResponse;
                const value = frame[at..][0..length];
                at += length;
                if (std.mem.eql(u8, name, ":message-type")) {
                    if (kind != null) return error.InvalidResponse;
                    kind = value;
                }
                if (std.mem.eql(u8, name, ":event-type")) {
                    if (event != null) return error.InvalidResponse;
                    event = value;
                }
            }
            if (!std.mem.eql(u8, kind orelse return error.InvalidResponse, "event")) return error.RemoteSelectError;
            const name = event orelse return error.InvalidResponse;
            const payload = frame[12 + headers .. size - 4];
            if (std.mem.eql(u8, name, "Records")) {
                try file.writeStreamingAll(io, payload);
                self.written += payload.len;
            } else if (std.mem.eql(u8, name, "End")) {
                if (payload.len != 0) return error.InvalidResponse;
                self.ended = true;
            } else if (std.mem.eql(u8, name, "Stats") or std.mem.eql(u8, name, "Progress")) {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                _ = try @import("xml.zig").parse(arena.allocator(), payload);
            } else if (!std.mem.eql(u8, name, "Cont")) return error.InvalidResponse;
            offset += size;
        }
        const rest = self.pending.items.len - offset;
        std.mem.copyForwards(u8, self.pending.items[0..rest], self.pending.items[offset..]);
        self.pending.items.len = rest;
    }
    pub fn complete(self: Decoder) bool {
        return self.ended and self.pending.items.len == 0;
    }
};
