const std = @import("std");

pub const max_objects: usize = 1000;
pub const max_payload_size: usize = 2 * 1024 * 1024;

pub const Object = struct { key: []u8, version_id: ?[]u8 = null };

pub const Request = struct {
    objects: []Object,
    quiet: bool,

    pub fn deinit(self: Request, allocator: std.mem.Allocator) void {
        for (self.objects) |object| {
            allocator.free(object.key);
            if (object.version_id) |version| allocator.free(version);
        }
        allocator.free(self.objects);
    }
};

pub const ParseError = error{
    OutOfMemory,
    MalformedXml,
    TooManyObjects,
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!Request {
    var parser: Parser = .{
        .allocator = allocator,
        .source = source,
    };
    return parser.parse();
}

const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    index: usize = 0,

    fn parse(self: *Parser) ParseError!Request {
        var keys: std.ArrayList(Object) = .empty;
        errdefer {
            for (keys.items) |object| {
                self.allocator.free(object.key);
                if (object.version_id) |version| self.allocator.free(version);
            }
            keys.deinit(self.allocator);
        }

        self.skipWhitespace();
        if (self.startsWith("<?xml")) {
            const end = std.mem.indexOfPos(u8, self.source, self.index + 5, "?>") orelse {
                return error.MalformedXml;
            };
            self.index = end + 2;
            self.skipWhitespace();
        }
        try self.parseDeleteOpen();
        self.skipWhitespace();

        var quiet = false;
        var quiet_seen = false;
        while (!self.startsWith("</Delete>")) {
            if (self.startsWith("<Object>")) {
                if (keys.items.len == max_objects) return error.TooManyObjects;
                self.index += "<Object>".len;
                self.skipWhitespace();
                try self.expect("<Key>");
                const key = try self.parseText("</Key>");
                errdefer self.allocator.free(key);
                self.skipWhitespace();
                var version: ?[]u8 = null;
                errdefer if (version) |value| self.allocator.free(value);
                if (self.startsWith("<VersionId>")) {
                    self.index += "<VersionId>".len;
                    version = try self.parseText("</VersionId>");
                    self.skipWhitespace();
                }
                try self.expect("</Object>");
                keys.append(self.allocator, .{ .key = key, .version_id = version }) catch return error.OutOfMemory;
            } else if (self.startsWith("<Quiet>") and !quiet_seen) {
                quiet_seen = true;
                self.index += "<Quiet>".len;
                const quiet_text = try self.rawText("</Quiet>");
                quiet = if (std.mem.eql(u8, quiet_text, "true"))
                    true
                else if (std.mem.eql(u8, quiet_text, "false"))
                    false
                else
                    return error.MalformedXml;
            } else {
                return error.MalformedXml;
            }
            self.skipWhitespace();
        }
        if (keys.items.len == 0) return error.MalformedXml;
        try self.expect("</Delete>");
        self.skipWhitespace();
        if (self.index != self.source.len) return error.MalformedXml;
        return .{
            .objects = keys.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            .quiet = quiet,
        };
    }

    fn parseDeleteOpen(self: *Parser) ParseError!void {
        try self.expect("<Delete");
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
        const end = std.mem.indexOfScalarPos(u8, self.source, self.index, quote) orelse {
            return error.MalformedXml;
        };
        if (!std.mem.eql(
            u8,
            self.source[self.index..end],
            "http://s3.amazonaws.com/doc/2006-03-01/",
        )) return error.MalformedXml;
        self.index = end + 1;
        self.skipWhitespace();
        try self.expect(">");
    }

    fn parseText(self: *Parser, closing: []const u8) ParseError![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        while (!self.startsWith(closing)) {
            if (self.index >= self.source.len or self.source[self.index] == '<') {
                return error.MalformedXml;
            }
            if (self.source[self.index] != '&') {
                const start = self.index;
                while (self.index < self.source.len and
                    self.source[self.index] != '&' and
                    self.source[self.index] != '<')
                {
                    self.index += 1;
                }
                output.appendSlice(self.allocator, self.source[start..self.index]) catch {
                    return error.OutOfMemory;
                };
                continue;
            }
            const semicolon = std.mem.indexOfScalarPos(u8, self.source, self.index + 1, ';') orelse {
                return error.MalformedXml;
            };
            try appendEntity(
                self.allocator,
                &output,
                self.source[self.index + 1 .. semicolon],
            );
            self.index = semicolon + 1;
        }
        self.index += closing.len;
        if (!std.unicode.utf8ValidateSlice(output.items)) return error.MalformedXml;
        return output.toOwnedSlice(self.allocator) catch error.OutOfMemory;
    }

    fn rawText(self: *Parser, closing: []const u8) ParseError![]const u8 {
        const end = std.mem.indexOfPos(u8, self.source, self.index, closing) orelse {
            return error.MalformedXml;
        };
        const value = self.source[self.index..end];
        if (std.mem.indexOfAny(u8, value, "<&") != null) return error.MalformedXml;
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
        while (self.index < self.source.len and isWhitespace(self.source[self.index])) {
            self.index += 1;
        }
    }
};

fn appendEntity(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    entity: []const u8,
) ParseError!void {
    const named: ?u8 = if (std.mem.eql(u8, entity, "amp"))
        '&'
    else if (std.mem.eql(u8, entity, "lt"))
        '<'
    else if (std.mem.eql(u8, entity, "gt"))
        '>'
    else if (std.mem.eql(u8, entity, "apos"))
        '\''
    else if (std.mem.eql(u8, entity, "quot"))
        '"'
    else
        null;
    if (named) |character| {
        output.append(allocator, character) catch return error.OutOfMemory;
        return;
    }
    if (entity.len < 2 or entity[0] != '#') return error.MalformedXml;
    const hexadecimal = entity.len >= 3 and entity[1] == 'x';
    const digits = entity[if (hexadecimal) 2 else 1..];
    if (digits.len == 0) return error.MalformedXml;
    const value = std.fmt.parseInt(u21, digits, if (hexadecimal) 16 else 10) catch {
        return error.MalformedXml;
    };
    if (!isXmlCodepoint(value)) return error.MalformedXml;
    var encoded: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(value, &encoded) catch return error.MalformedXml;
    output.appendSlice(allocator, encoded[0..length]) catch return error.OutOfMemory;
}

fn isWhitespace(character: u8) bool {
    return character == ' ' or character == '\t' or character == '\r' or character == '\n';
}

fn isXmlCodepoint(value: u21) bool {
    return value == 0x09 or value == 0x0a or value == 0x0d or
        (value >= 0x20 and value <= 0xd7ff) or
        (value >= 0xe000 and value <= 0xfffd) or
        (value >= 0x10000 and value <= 0x10ffff);
}

test "DeleteObjects XML parses mc quiet requests and escaped keys" {
    const request = try parse(
        std.testing.allocator,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<Delete xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">" ++
            "<Object><Key>a&amp;b.txt</Key></Object>" ++
            "<Object><Key>folder/&#x4e2d;.txt</Key></Object>" ++
            "<Quiet>true</Quiet></Delete>",
    );
    defer request.deinit(std.testing.allocator);
    try std.testing.expect(request.quiet);
    try std.testing.expectEqual(@as(usize, 2), request.objects.len);
    try std.testing.expectEqualStrings("a&b.txt", request.objects[0].key);
    try std.testing.expectEqualStrings("folder/\xe4\xb8\xad.txt", request.objects[1].key);
}

test "DeleteObjects XML accepts the mc Quiet-before-Object encoding" {
    const request = try parse(
        std.testing.allocator,
        "<Delete><Quiet>false</Quiet><Object><Key>payload.txt</Key></Object></Delete>",
    );
    defer request.deinit(std.testing.allocator);
    try std.testing.expect(!request.quiet);
    try std.testing.expectEqualStrings("payload.txt", request.objects[0].key);
}

test "DeleteObjects XML rejects unknown structure and empty requests" {
    try std.testing.expectError(error.MalformedXml, parse(
        std.testing.allocator,
        "<Delete></Delete>",
    ));
    try std.testing.expectError(error.MalformedXml, parse(
        std.testing.allocator,
        "<Delete><Object><Key>a</Key><VersionId>1</VersionId><VersionId>2</VersionId></Object></Delete>",
    ));
}

test "DeleteObjects accepts explicit versions without dropping them" {
    const request = try parse(std.testing.allocator, "<Delete><Object><Key>file</Key><VersionId>null</VersionId></Object><Object><Key>plain</Key></Object></Delete>");
    defer request.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("null", request.objects[0].version_id.?);
    try std.testing.expect(request.objects[1].version_id == null);
}
