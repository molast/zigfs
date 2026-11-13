const std = @import("std");
const delivery = @import("../ports/event_delivery.zig");
const webhook = @import("event_webhook.zig");

pub const Channel = struct {
    context: *anyopaque,
    pub fn open(url: [:0]const u8, ca: [:0]const u8, cert: [:0]const u8, key: [:0]const u8, policy: c_int, trust_leaf: bool, timeout: c_long) delivery.Error!Channel {
        var ctx: ?*anyopaque = null;
        const code = zigfs_event_channel_open(url, ca, cert, key, policy, @intFromBool(trust_leaf), timeout, &ctx);
        if (code != 0) return webhook.curlError(code);
        return .{ .context = ctx orelse return error.Unavailable };
    }
    pub fn close(self: Channel) void {
        zigfs_event_channel_close(self.context);
    }
    pub fn writeAll(self: Channel, bytes: []const u8) delivery.Error!void {
        const code = zigfs_event_channel_write(self.context, bytes.ptr, bytes.len);
        if (code != 0) return webhook.curlError(code);
    }
    pub fn readAll(self: Channel, bytes: []u8) delivery.Error!void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            var used: usize = 0;
            const code = zigfs_event_channel_read(self.context, bytes[offset..].ptr, bytes.len - offset, &used);
            if (code != 0) return webhook.curlError(code);
            offset += used;
        }
    }
};
extern fn zigfs_event_channel_open([*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, c_int, c_int, c_long, *?*anyopaque) c_int;
extern fn zigfs_event_channel_read(*anyopaque, [*]u8, usize, *usize) c_int;
extern fn zigfs_event_channel_write(*anyopaque, [*]const u8, usize) c_int;
extern fn zigfs_event_channel_close(*anyopaque) void;
