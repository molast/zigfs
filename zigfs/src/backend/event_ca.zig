const std = @import("std");
const delivery = @import("../ports/event_delivery.zig");

/// Enforce CA:TRUE on configured trust anchors unless leaf trust was explicit.
/// This keeps the setting consistent across libcurl TLS backends.
pub fn requireCaCertificates(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, path: []const u8) delivery.Error!void {
    if (path.len == 0) return;
    const bytes = root.readFileAlloc(io, path, a, .limited(1024 * 1024)) catch return error.InvalidConfiguration;
    const begin = "-----BEGIN CERTIFICATE-----";
    const end = "-----END CERTIFICATE-----";
    var offset: usize = 0;
    var count: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, offset, begin)) |start| {
        const body_start = start + begin.len;
        const body_end = std.mem.indexOfPos(u8, bytes, body_start, end) orelse return error.InvalidConfiguration;
        var encoded: std.ArrayList(u8) = .empty;
        for (bytes[body_start..body_end]) |byte| if (!std.ascii.isWhitespace(byte)) {
            try encoded.append(a, byte);
        };
        const size = std.base64.standard.Decoder.calcSizeForSlice(encoded.items) catch return error.InvalidConfiguration;
        const der = try a.alloc(u8, size);
        std.base64.standard.Decoder.decode(der, encoded.items) catch return error.InvalidConfiguration;
        if (!isCa(der)) return error.InvalidConfiguration;
        count += 1;
        offset = body_end + end.len;
    }
    if (count == 0 and !isCa(bytes)) return error.InvalidConfiguration;
}
const Element = struct { tag: u8, bytes: []const u8 };
fn take(bytes: []const u8, offset: *usize) ?Element {
    if (offset.* > bytes.len or bytes.len - offset.* < 2) return null;
    const tag = bytes[offset.*];
    const first = bytes[offset.* + 1];
    offset.* += 2;
    var length: usize = first;
    if (first & 128 != 0) {
        const count = first & 127;
        if (count == 0 or count > 4 or bytes.len - offset.* < count) return null;
        length = 0;
        for (bytes[offset.* .. offset.* + count]) |byte| length = (length << 8) | byte;
        offset.* += count;
    }
    if (length > bytes.len - offset.*) return null;
    const result: Element = .{ .tag = tag, .bytes = bytes[offset.* .. offset.* + length] };
    offset.* += length;
    return result;
}
fn isCa(der: []const u8) bool {
    var i: usize = 0;
    const cert = take(der, &i) orelse return false;
    if (cert.tag != 0x30 or i != der.len) return false;
    i = 0;
    const tbs = take(cert.bytes, &i) orelse return false;
    if (tbs.tag != 0x30) return false;
    i = 0;
    while (i < tbs.bytes.len) {
        const field = take(tbs.bytes, &i) orelse return false;
        if (field.tag != 0xa3) continue;
        var j: usize = 0;
        const extensions = take(field.bytes, &j) orelse return false;
        if (extensions.tag != 0x30) return false;
        j = 0;
        while (j < extensions.bytes.len) {
            const extension = take(extensions.bytes, &j) orelse return false;
            if (extension.tag != 0x30) return false;
            var k: usize = 0;
            const oid = take(extension.bytes, &k) orelse return false;
            if (oid.tag != 6 or !std.mem.eql(u8, oid.bytes, &.{ 0x55, 0x1d, 0x13 })) continue;
            var value = take(extension.bytes, &k) orelse return false;
            if (value.tag == 1) value = take(extension.bytes, &k) orelse return false;
            if (value.tag != 4) return false;
            k = 0;
            const constraints = take(value.bytes, &k) orelse return false;
            if (constraints.tag != 0x30) return false;
            k = 0;
            const ca = take(constraints.bytes, &k) orelse return false;
            return ca.tag == 1 and std.mem.eql(u8, ca.bytes, &.{0xff});
        }
    }
    return false;
}
test "CA constraint parser rejects missing, false and malformed constraints" {
    const ca = [_]u8{ 0x30, 20, 0x30, 18, 0xa3, 16, 0x30, 14, 0x30, 12, 6, 3, 0x55, 0x1d, 0x13, 4, 5, 0x30, 3, 1, 1, 0xff };
    try std.testing.expect(isCa(&ca));
    var leaf = ca;
    leaf[21] = 0;
    try std.testing.expect(!isCa(&leaf));
    try std.testing.expect(!isCa(&.{ 0x30, 0x84, 0xff }));
    try std.testing.expect(!isCa(&.{}));
}
