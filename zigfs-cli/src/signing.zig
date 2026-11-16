const std = @import("std");
const A = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
pub const Header = struct { name: []const u8, value: []const u8 };
pub const Pair = struct { name: []const u8, value: []const u8 };

pub fn hash(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
pub fn encode(a: A, bytes: []const u8, slash: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const hex = "0123456789ABCDEF";
    for (bytes) |b| {
        if (std.ascii.isAlphanumeric(b) or std.mem.indexOfScalar(u8, "-._~", b) != null or slash and b == '/')
            try out.append(a, b)
        else
            try out.appendSlice(a, &.{ '%', hex[b >> 4], hex[b & 15] });
    }
    return out.items;
}
pub fn query(a: A, pairs: []const Pair) ![]const u8 {
    const encoded = try a.alloc(Pair, pairs.len);
    for (pairs, encoded) |p, *out| out.* = .{ .name = try encode(a, p.name, false), .value = try encode(a, p.value, false) };
    std.mem.sort(Pair, encoded, {}, struct {
        fn less(_: void, x: Pair, y: Pair) bool {
            const order = std.mem.order(u8, x.name, y.name);
            return if (order == .eq) std.mem.lessThan(u8, x.value, y.value) else order == .lt;
        }
    }.less);
    var writer: std.Io.Writer.Allocating = .init(a);
    for (encoded, 0..) |p, i| {
        if (i != 0) try writer.writer.writeByte('&');
        try writer.writer.print("{s}={s}", .{ p.name, p.value });
    }
    return writer.toOwnedSlice();
}
fn normalize(a: A, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var whitespace = false;
    for (std.mem.trim(u8, value, " \t")) |c| {
        if (c == '\r' or c == '\n' or c == 0) return error.InvalidHeader;
        if (c == ' ' or c == '\t') {
            whitespace = true;
        } else {
            if (whitespace and out.items.len != 0) try out.append(a, ' ');
            whitespace = false;
            try out.append(a, c);
        }
    }
    return out.items;
}
pub const Signed = struct { authorization: []const u8, headers: []Header, canonical: []const u8 };
pub fn sign(a: A, method: []const u8, path: []const u8, canonical_query: []const u8, headers: []const Header, payload_hash: []const u8, date: []const u8, region: []const u8, ak: []const u8, sk: []const u8) !Signed {
    if (date.len != 16 or payload_hash.len != 64) return error.InvalidSigningInput;
    const normalized = try a.alloc(Header, headers.len);
    for (headers, normalized) |h, *out| out.* = .{ .name = try std.ascii.allocLowerString(a, h.name), .value = try normalize(a, h.value) };
    std.mem.sort(Header, normalized, {}, struct {
        fn less(_: void, l: Header, r: Header) bool {
            return std.mem.lessThan(u8, l.name, r.name);
        }
    }.less);
    var canonical_headers: std.Io.Writer.Allocating = .init(a);
    var names: std.Io.Writer.Allocating = .init(a);
    for (normalized, 0..) |h, i| {
        if (h.name.len == 0) return error.InvalidHeader;
        for (h.name) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return error.InvalidHeader;
        if (i != 0) {
            if (std.mem.eql(u8, normalized[i - 1].name, h.name)) return error.DuplicateHeader;
            try names.writer.writeByte(';');
        }
        try names.writer.writeAll(h.name);
        try canonical_headers.writer.print("{s}:{s}\n", .{ h.name, h.value });
    }
    const canonical = try std.fmt.allocPrint(a, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{ method, path, canonical_query, canonical_headers.written(), names.written(), payload_hash });
    const scope = try std.fmt.allocPrint(a, "{s}/{s}/s3/aws4_request", .{ date[0..8], region });
    const message = try std.fmt.allocPrint(a, "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{ date, scope, hash(canonical) });
    var signing_key: [32]u8 = undefined;
    const seed = try std.fmt.allocPrint(a, "AWS4{s}", .{sk});
    defer std.crypto.secureZero(u8, seed);
    Hmac.create(&signing_key, date[0..8], seed);
    for ([_][]const u8{ region, "s3", "aws4_request" }) |part| {
        var next: [32]u8 = undefined;
        Hmac.create(&next, part, &signing_key);
        signing_key = next;
    }
    defer std.crypto.secureZero(u8, &signing_key);
    var signature: [32]u8 = undefined;
    Hmac.create(&signature, message, &signing_key);
    return .{ .headers = normalized, .canonical = canonical, .authorization = try std.fmt.allocPrint(a, "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}", .{ ak, scope, names.written(), std.fmt.bytesToHex(signature, .lower) }) };
}
pub fn timestamp(a: A, seconds: u64) ![]const u8 {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const day = epoch.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    return std.fmt.allocPrint(a, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{ day.year, @backingInt(month.month), month.day_index + 1, time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute() });
}

test "AWS S3 published GET signing vector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const signed = try sign(a, "GET", "/test.txt", "", &.{ .{ .name = "Host", .value = "examplebucket.s3.amazonaws.com" }, .{ .name = "Range", .value = "bytes=0-9" }, .{ .name = "x-amz-content-sha256", .value = &hash("") }, .{ .name = "x-amz-date", .value = "20130524T000000Z" } }, &hash(""), "20130524T000000Z", "us-east-1", "AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY");
    try std.testing.expect(std.mem.endsWith(u8, signed.authorization, "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"));
}
test "S3 key encoding preserves literal slashes percent unicode and dot segments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("a//../%E4%B8%AD%20%2B%25%3F", try encode(a, "a//../中 +%?", true));
    try std.testing.expectEqualStrings("a=%20&a=%2B&z=", try query(a, &.{ .{ .name = "z", .value = "" }, .{ .name = "a", .value = "+" }, .{ .name = "a", .value = " " } }));
    try std.testing.expectEqualStrings("19700101T000000Z", try timestamp(a, 0));
}
