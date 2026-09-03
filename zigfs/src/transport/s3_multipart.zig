const std = @import("std");
const multipart_service = @import("../application/multipart_service.zig");
const multipart_domain = @import("../domain/multipart.zig");

pub const max_payload_size: usize = 2 * 1024 * 1024;

pub const Request = struct {
    parts: []multipart_service.CompletePart,

    pub fn deinit(self: Request, allocator: std.mem.Allocator) void {
        allocator.free(self.parts);
    }
};

pub const ParseError = error{ OutOfMemory, MalformedXml, TooManyParts };

pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!Request {
    var parser: Parser = .{ .allocator = allocator, .source = source };
    return parser.parse();
}

const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    index: usize = 0,

    fn parse(self: *Parser) ParseError!Request {
        var parts: std.ArrayList(multipart_service.CompletePart) = .empty;
        errdefer parts.deinit(self.allocator);
        self.skipWhitespace();
        if (self.startsWith("<?xml")) {
            const end = std.mem.indexOfPos(u8, self.source, self.index + 5, "?>") orelse return error.MalformedXml;
            self.index = end + 2;
            self.skipWhitespace();
        }
        try self.parseRootOpen();
        self.skipWhitespace();
        while (!self.startsWith("</CompleteMultipartUpload>")) {
            if (parts.items.len == multipart_domain.max_parts) return error.TooManyParts;
            try self.expect("<Part>");
            self.skipWhitespace();
            var number: ?u16 = null;
            var etag: ?[16]u8 = null;
            while (!self.startsWith("</Part>")) {
                if (self.startsWith("<PartNumber>") and number == null) {
                    self.index += "<PartNumber>".len;
                    const number_text = try self.rawText("</PartNumber>");
                    number = std.fmt.parseInt(u16, number_text, 10) catch return error.MalformedXml;
                } else if (self.startsWith("<ETag>") and etag == null) {
                    self.index += "<ETag>".len;
                    const etag_text = try self.elementText("</ETag>");
                    etag = parseEtag(etag_text) orelse return error.MalformedXml;
                } else {
                    return error.MalformedXml;
                }
                self.skipWhitespace();
            }
            try self.expect("</Part>");
            parts.append(self.allocator, .{
                .number = number orelse return error.MalformedXml,
                .etag_md5 = etag orelse return error.MalformedXml,
            }) catch return error.OutOfMemory;
            self.skipWhitespace();
        }
        if (parts.items.len == 0) return error.MalformedXml;
        try self.expect("</CompleteMultipartUpload>");
        self.skipWhitespace();
        if (self.index != self.source.len) return error.MalformedXml;
        return .{ .parts = parts.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
    }

    fn parseRootOpen(self: *Parser) ParseError!void {
        try self.expect("<CompleteMultipartUpload");
        if (self.index >= self.source.len) return error.MalformedXml;
        if (self.source[self.index] == '>') {
            self.index += 1;
            return;
        }
        if (!isWhitespace(self.source[self.index])) return error.MalformedXml;
        self.skipWhitespace();
        try self.expect("xmlns");
        self.skipWhitespace();
        try self.expect("=");
        self.skipWhitespace();
        if (self.index >= self.source.len) return error.MalformedXml;
        const quote = self.source[self.index];
        if (quote != '\'' and quote != '"') return error.MalformedXml;
        self.index += 1;
        const end = std.mem.indexOfScalarPos(u8, self.source, self.index, quote) orelse return error.MalformedXml;
        if (!std.mem.eql(u8, self.source[self.index..end], "http://s3.amazonaws.com/doc/2006-03-01/")) {
            return error.MalformedXml;
        }
        self.index = end + 1;
        self.skipWhitespace();
        try self.expect(">");
    }

    fn rawText(self: *Parser, closing: []const u8) ParseError![]const u8 {
        const end = std.mem.indexOfPos(u8, self.source, self.index, closing) orelse return error.MalformedXml;
        const value = self.source[self.index..end];
        if (std.mem.indexOfAny(u8, value, "<&") != null) return error.MalformedXml;
        self.index = end + closing.len;
        return value;
    }

    fn elementText(self: *Parser, closing: []const u8) ParseError![]const u8 {
        const end = std.mem.indexOfPos(u8, self.source, self.index, closing) orelse return error.MalformedXml;
        const value = self.source[self.index..end];
        if (std.mem.indexOfScalar(u8, value, '<') != null) return error.MalformedXml;
        self.index = end + closing.len;
        return value;
    }

    fn expect(self: *Parser, value: []const u8) ParseError!void {
        if (!self.startsWith(value)) return error.MalformedXml;
        self.index += value.len;
    }

    fn startsWith(self: Parser, value: []const u8) bool {
        return std.mem.startsWith(u8, self.source[self.index..], value);
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.index < self.source.len and isWhitespace(self.source[self.index])) self.index += 1;
    }
};

pub fn parseEtag(value: []const u8) ?[16]u8 {
    const hex = if (value.len == 34 and value[0] == '"' and value[value.len - 1] == '"')
        value[1 .. value.len - 1]
    else if (unwrapXmlQuoted(value, "&quot;")) |inner|
        inner
    else if (unwrapXmlQuoted(value, "&#34;")) |inner|
        inner
    else if (unwrapXmlQuoted(value, "&#x22;")) |inner|
        inner
    else if (value.len == 32)
        value
    else
        return null;
    for (hex) |character| {
        if (!std.ascii.isDigit(character) and
            !(character >= 'a' and character <= 'f') and
            !(character >= 'A' and character <= 'F')) return null;
    }
    var result: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, hex) catch return null;
    return result;
}

fn unwrapXmlQuoted(value: []const u8, quote: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, quote) or !std.mem.endsWith(u8, value, quote)) return null;
    if (value.len != quote.len * 2 + 32) return null;
    return value[quote.len .. value.len - quote.len];
}

fn isWhitespace(character: u8) bool {
    return character == ' ' or character == '\t' or character == '\r' or character == '\n';
}

test "CompleteMultipartUpload XML parses ordered quoted ETags" {
    const request = try parse(
        std.testing.allocator,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" ++
            "<CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">" ++
            "<Part><ETag>\"900150983cd24fb0d6963f7d28e17f72\"</ETag><PartNumber>1</PartNumber></Part>" ++
            "<Part><PartNumber>2</PartNumber><ETag>\"d41d8cd98f00b204e9800998ecf8427e\"</ETag></Part>" ++
            "</CompleteMultipartUpload>",
    );
    defer request.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), request.parts.len);
    try std.testing.expectEqual(@as(u16, 2), request.parts[1].number);
}

test "CompleteMultipartUpload XML rejects unknown fields and invalid ETags" {
    try std.testing.expectError(error.MalformedXml, parse(
        std.testing.allocator,
        "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>bad</ETag></Part></CompleteMultipartUpload>",
    ));
    try std.testing.expectError(error.MalformedXml, parse(
        std.testing.allocator,
        "<CompleteMultipartUpload><Unknown/></CompleteMultipartUpload>",
    ));
}

test "CompleteMultipartUpload accepts rclone XML-escaped ETag quotes" {
    const request = try parse(
        std.testing.allocator,
        "<CompleteMultipartUpload><Part><ETag>&#34;900150983cd24fb0d6963f7d28e17f72&#34;</ETag><PartNumber>1</PartNumber></Part></CompleteMultipartUpload>",
    );
    defer request.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 1), request.parts[0].number);
}
