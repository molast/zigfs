const std = @import("std");
const delivery = @import("../ports/event_delivery.zig");
const destinations = @import("../application/event_destinations.zig");
const Channel = @import("event_channel.zig").Channel;
const certificatePath = @import("event_webhook.zig").certificatePath;

/// One bounded MQTT 3.1.1 session per delivery; no background traffic or retries.
pub const Mqtt = struct {
    config: destinations.Destination,
    root: std.Io.Dir,
    timeout_seconds: c_long = 10,
    pub fn sender(self: *Mqtt) delivery.Sender {
        return .{ .context = self, .vtable = &.{ .send = send } };
    }
    fn send(ctx: *anyopaque, allocator: std.mem.Allocator, io: std.Io, event: delivery.Event) delivery.Error!void {
        const self: *Mqtt = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, self.config.type, "mqtt")) return error.InvalidConfiguration;
        destinations.validate(self.config) catch return error.InvalidConfiguration;
        if (self.timeout_seconds < 1 or self.timeout_seconds > 60 or event.payload.len > 1024 * 1024) return error.InvalidConfiguration;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const c = self.config;
        const uri = std.Uri.parse(c.broker) catch return error.InvalidConfiguration;
        const ws = std.mem.eql(u8, uri.scheme, "ws") or std.mem.eql(u8, uri.scheme, "wss");
        const tls = std.mem.eql(u8, uri.scheme, "tls") or std.mem.eql(u8, uri.scheme, "ssl") or std.mem.eql(u8, uri.scheme, "mqtts") or std.mem.eql(u8, uri.scheme, "wss");
        const host = try uri.host.?.toRawMaybeAlloc(a);
        const broker_path = if (uri.path.isEmpty()) "/" else switch (uri.path) {
            .raw => |path| path,
            .percent_encoded => |path| path,
        };
        if (uri.query != null or (!ws and !std.mem.eql(u8, broker_path, "/"))) return error.InvalidConfiguration;
        if (ws and c.websocket_path_allowlist.len > 0) {
            var allowed = false;
            var list = std.mem.splitScalar(u8, c.websocket_path_allowlist, ',');
            while (list.next()) |path| if (std.mem.eql(u8, std.mem.trim(u8, path, " "), broker_path)) {
                allowed = true;
            };
            if (!allowed) return error.InvalidConfiguration;
        }
        const port = uri.port orelse @as(u16, if (ws) (if (tls) 443 else 80) else if (tls) 8883 else 1883);
        const authority = try std.fmt.allocPrint(a, "{s}:{d}", .{ host, port });
        const url = try std.fmt.allocPrintSentinel(a, "{s}://{s}/", .{ if (tls) "https" else "http", authority }, 0);
        const policy: c_int = if (c.tls_policy.len == 0 or std.mem.eql(u8, c.tls_policy, "strict")) 0 else if (std.mem.eql(u8, c.tls_policy, "compat")) 1 else if (std.mem.eql(u8, c.tls_policy, "insecure")) 2 else return error.InvalidConfiguration;
        const ca = try certificatePath(a, self.root, io, c.tls_ca);
        const cert = try certificatePath(a, self.root, io, c.tls_client_certificate);
        const key = try certificatePath(a, self.root, io, c.tls_client_key);
        if (c.trust_leaf_as_ca and ca.len == 0) return error.InvalidConfiguration;
        if (!c.trust_leaf_as_ca) try @import("event_ca.zig").requireCaCertificates(a, self.root, io, c.tls_ca);
        const keep_alive_ms = try durationMs(c.keep_alive_interval);
        const keep_alive_seconds = (keep_alive_ms + 999) / 1000;
        if (keep_alive_seconds > 65535) return error.InvalidConfiguration;
        const channel = try Channel.open(url, ca, cert, key, policy, c.trust_leaf_as_ca, self.timeout_seconds);
        defer channel.close();
        var wire: Wire = .{ .channel = channel, .a = a, .io = io, .websocket = ws };
        if (ws) try wire.upgrade(authority, broker_path);
        var random: [8]u8 = undefined;
        io.randomSecure(&random) catch return error.Unavailable;
        const client_id = try std.fmt.allocPrint(a, "zigfs{s}", .{std.fmt.bytesToHex(random, .lower)});
        var connect: std.ArrayList(u8) = .empty;
        try appendString(&connect, a, "MQTT");
        // Clean session. A password always carries a username flag (possibly empty).
        const has_username = c.username.len > 0 or c.password.len > 0;
        const flags: u8 = 2 | @as(u8, if (has_username) 0x80 else 0) | @as(u8, if (c.password.len > 0) 0x40 else 0);
        try connect.appendSlice(a, &.{ 4, flags, @intCast(keep_alive_seconds >> 8), @intCast(keep_alive_seconds & 255) });
        try appendString(&connect, a, client_id);
        if (has_username) try appendString(&connect, a, c.username);
        if (c.password.len > 0) try appendString(&connect, a, c.password);
        try wire.packet(0x10, connect.items);
        const connack = try wire.readPacket();
        if (connack.header != 0x20 or connack.body.len != 2 or connack.body[0] != 0) return error.Rejected;
        switch (connack.body[1]) {
            0 => {},
            3 => return error.Unavailable,
            4, 5 => return error.AuthenticationFailed,
            else => return error.Rejected,
        }
        var publish: std.ArrayList(u8) = .empty;
        try appendString(&publish, a, c.topic);
        if (c.qos > 0) try publish.appendSlice(a, &.{ 0, 1 });
        try publish.appendSlice(a, event.payload);
        try wire.packet(0x30 | (c.qos << 1), publish.items);
        if (c.qos == 1) try expectAck(try wire.readPacket(), 0x40);
        if (c.qos == 2) {
            try expectAck(try wire.readPacket(), 0x50);
            try wire.packet(0x62, &.{ 0, 1 });
            var duplicate: usize = 0;
            while (true) {
                const ack = try wire.readPacket();
                if (ack.header == 0x50 and duplicate < 16) {
                    try expectAck(ack, 0x50);
                    try wire.packet(0x62, &.{ 0, 1 });
                    duplicate += 1;
                    continue;
                }
                try expectAck(ack, 0x70);
                break;
            }
        }
        // A disconnect failure cannot undo a confirmed publish.
        wire.packet(0xe0, &.{}) catch {};
    }
};
pub fn durationMs(value: []const u8) delivery.Error!u64 {
    var i: usize = 0;
    while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) {}
    if (i == 0) return error.InvalidConfiguration;
    const amount = std.fmt.parseInt(u32, value[0..i], 10) catch return error.InvalidConfiguration;
    const unit = value[i..];
    const factor: u64 = if (std.mem.eql(u8, unit, "ms")) 1 else if (std.mem.eql(u8, unit, "s")) 1000 else if (std.mem.eql(u8, unit, "m")) 60000 else if (std.mem.eql(u8, unit, "h")) 3600000 else return error.InvalidConfiguration;
    return @as(u64, amount) * factor;
}
fn appendString(out: *std.ArrayList(u8), a: std.mem.Allocator, value: []const u8) delivery.Error!void {
    if (value.len > 65535) return error.InvalidConfiguration;
    try out.appendSlice(a, &.{ @intCast(value.len >> 8), @intCast(value.len & 255) });
    try out.appendSlice(a, value);
}
const Packet = struct { header: u8, body: []const u8 };
fn expectAck(packet: Packet, header: u8) delivery.Error!void {
    if (packet.header != header or !std.mem.eql(u8, packet.body, &.{ 0, 1 })) return error.Rejected;
}
const Wire = struct {
    channel: Channel,
    a: std.mem.Allocator,
    io: std.Io,
    websocket: bool,
    frame: []const u8 = &.{},
    offset: usize = 0,
    fragmented: bool = false,
    incoming_bytes: usize = 0,
    incoming_frames: usize = 0,

    fn upgrade(self: *Wire, authority: []const u8, path: []const u8) delivery.Error!void {
        var nonce: [16]u8 = undefined;
        self.io.randomSecure(&nonce) catch return error.Unavailable;
        var encoded: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&encoded, &nonce);
        const request = try std.fmt.allocPrint(self.a, "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Protocol: mqtt\r\n\r\n", .{ path, authority, encoded });
        try self.channel.writeAll(request);
        var response: std.ArrayList(u8) = .empty;
        while (response.items.len < 16384) {
            var byte: [1]u8 = undefined;
            try self.channel.readAll(&byte);
            try response.append(self.a, byte[0]);
            if (std.mem.endsWith(u8, response.items, "\r\n\r\n")) break;
        }
        var lines = std.mem.splitSequence(u8, response.items, "\r\n");
        const status = lines.next() orelse return error.Rejected;
        if (!std.mem.startsWith(u8, status, "HTTP/1.1 101 ")) {
            if (std.mem.startsWith(u8, status, "HTTP/1.1 401 ") or std.mem.startsWith(u8, status, "HTTP/1.1 403 ")) return error.AuthenticationFailed;
            return error.Rejected;
        }
        const hash_input = try std.fmt.allocPrint(self.a, "{s}258EAFA5-E914-47DA-95CA-C5AB0DC85B11", .{encoded});
        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(hash_input, &digest, .{});
        var expected: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&expected, &digest);
        var accepted = false;
        var upgraded = false;
        var connected = false;
        var protocol = false;
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) accepted = std.mem.eql(u8, value, &expected);
            if (std.ascii.eqlIgnoreCase(name, "upgrade")) upgraded = std.ascii.eqlIgnoreCase(value, "websocket");
            if (std.ascii.eqlIgnoreCase(name, "connection")) {
                var tokens = std.mem.splitScalar(u8, value, ',');
                while (tokens.next()) |token| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, token, " \t"), "upgrade")) {
                    connected = true;
                };
            }
            if (std.ascii.eqlIgnoreCase(name, "sec-websocket-protocol")) protocol = std.mem.eql(u8, value, "mqtt");
        }
        if (!accepted or !upgraded or !connected or !protocol) return error.Rejected;
    }
    fn writeFrame(self: *Wire, opcode: u8, bytes: []const u8) delivery.Error!void {
        var out: std.ArrayList(u8) = .empty;
        try out.append(self.a, 0x80 | opcode);
        if (bytes.len < 126) {
            try out.append(self.a, 0x80 | @as(u8, @intCast(bytes.len)));
        } else if (bytes.len <= 65535) {
            try out.appendSlice(self.a, &.{ 0xfe, @intCast(bytes.len >> 8), @intCast(bytes.len & 255) });
        } else {
            try out.append(self.a, 0xff);
            var length: [8]u8 = undefined;
            std.mem.writeInt(u64, &length, bytes.len, .big);
            try out.appendSlice(self.a, &length);
        }
        var mask: [4]u8 = undefined;
        self.io.randomSecure(&mask) catch return error.Unavailable;
        try out.appendSlice(self.a, &mask);
        for (bytes, 0..) |byte, i| try out.append(self.a, byte ^ mask[i % 4]);
        try self.channel.writeAll(out.items);
    }
    fn packet(self: *Wire, header: u8, body: []const u8) delivery.Error!void {
        if (body.len > 268435455) return error.InvalidEvent;
        var out: std.ArrayList(u8) = .empty;
        try out.append(self.a, header);
        var remaining = body.len;
        while (true) {
            var byte: u8 = @intCast(remaining % 128);
            remaining /= 128;
            if (remaining > 0) byte |= 128;
            try out.append(self.a, byte);
            if (remaining == 0) break;
        }
        try out.appendSlice(self.a, body);
        if (self.websocket) try self.writeFrame(2, out.items) else try self.channel.writeAll(out.items);
    }
    fn read(self: *Wire, bytes: []u8) delivery.Error!void {
        if (!self.websocket) return self.channel.readAll(bytes);
        for (bytes) |*byte| {
            while (self.offset == self.frame.len) {
                var header: [2]u8 = undefined;
                try self.channel.readAll(&header);
                if ((header[0] & 0x70) != 0 or (header[1] & 0x80) != 0) return error.Rejected;
                const fin = (header[0] & 0x80) != 0;
                const opcode = header[0] & 15;
                var length: u64 = header[1] & 127;
                if (length == 126) {
                    var n: [2]u8 = undefined;
                    try self.channel.readAll(&n);
                    length = std.mem.readInt(u16, &n, .big);
                } else if (length == 127) {
                    var n: [8]u8 = undefined;
                    try self.channel.readAll(&n);
                    length = std.mem.readInt(u64, &n, .big);
                }
                self.incoming_frames += 1;
                if (self.incoming_frames > 1024 or length > 65536 or self.incoming_bytes + length > 65536) return error.Rejected;
                self.incoming_bytes += @intCast(length);
                const payload = try self.a.alloc(u8, @intCast(length));
                try self.channel.readAll(payload);
                if (opcode >= 8) {
                    if (!fin or length > 125) return error.Rejected;
                    switch (opcode) {
                        8 => return error.Unavailable,
                        9 => try self.writeFrame(10, payload),
                        10 => {},
                        else => return error.Rejected,
                    }
                    continue;
                }
                if (opcode == 2 and !self.fragmented) self.fragmented = !fin else if (opcode == 0 and self.fragmented) self.fragmented = !fin else return error.Rejected;
                self.frame = payload;
                self.offset = 0;
            }
            byte.* = self.frame[self.offset];
            self.offset += 1;
        }
    }
    fn readPacket(self: *Wire) delivery.Error!Packet {
        var header: [1]u8 = undefined;
        try self.read(&header);
        var length: usize = 0;
        var multiplier: usize = 1;
        var count: usize = 0;
        while (true) {
            var byte: [1]u8 = undefined;
            try self.read(&byte);
            length += @as(usize, byte[0] & 127) * multiplier;
            count += 1;
            if (length > 4096) return error.Rejected;
            if (byte[0] & 128 == 0) break;
            if (count == 4) return error.Rejected;
            multiplier *= 128;
        }
        const body = try self.a.alloc(u8, length);
        try self.read(body);
        return .{ .header = header[0], .body = body };
    }
};
