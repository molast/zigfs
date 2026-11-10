const std = @import("std");

pub const configuration_xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ServerSideEncryptionConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>AES256</SSEAlgorithm></ApplyServerSideEncryptionByDefault></Rule></ServerSideEncryptionConfiguration>";
pub const Error = error{ MalformedXml, InvalidArgument };

pub fn parseAlgorithm(body: []const u8) Error!@import("../domain/bucket.zig").Encryption {
    return (try parseConfiguration(body)).algorithm;
}

pub fn parseConfiguration(body: []const u8) Error!@import("../domain/bucket.zig").EncryptionConfiguration {
    var key: @import("../domain/bucket.zig").KmsKeyId = .{};
    var result: @import("../domain/bucket.zig").Encryption = .enabled;
    var parser = Parser{ .source = body };
    parser.whitespace();
    if (std.mem.startsWith(u8, body[parser.pos..], "<?xml")) {
        parser.pos = (std.mem.indexOfPos(u8, body, parser.pos, "?>") orelse return error.MalformedXml) + 2;
    }
    try parser.open("ServerSideEncryptionConfiguration", true);
    try parser.open("Rule", false);
    var applied = false;
    var bucket_key = false;
    while (!parser.closing()) {
        if (parser.nextIs("ApplyServerSideEncryptionByDefault")) {
            if (applied) return error.MalformedXml;
            applied = true;
            try parser.open("ApplyServerSideEncryptionByDefault", false);
            try parser.open("SSEAlgorithm", false);
            const algorithm = try parser.text();
            if (std.mem.eql(u8, algorithm, "aws:kms")) result = .kms else if (!std.mem.eql(u8, algorithm, "AES256")) return error.InvalidArgument;
            try parser.close("SSEAlgorithm");
            if (parser.nextIs("KMSMasterKeyID")) {
                if (result != .kms) return error.InvalidArgument;
                try parser.open("KMSMasterKeyID", false);
                key = @import("../domain/bucket.zig").KmsKeyId.fromString(try parser.text()) catch return error.InvalidArgument;
                try parser.close("KMSMasterKeyID");
            }
            try parser.close("ApplyServerSideEncryptionByDefault");
        } else if (parser.nextIs("BucketKeyEnabled")) {
            if (bucket_key) return error.MalformedXml;
            bucket_key = true;
            try parser.open("BucketKeyEnabled", false);
            if (!std.mem.eql(u8, try parser.text(), "false")) return error.InvalidArgument;
            try parser.close("BucketKeyEnabled");
        } else return error.MalformedXml;
    }
    if (!applied) return error.MalformedXml;
    try parser.close("Rule");
    try parser.close("ServerSideEncryptionConfiguration");
    parser.whitespace();
    if (parser.pos != body.len) return error.MalformedXml;
    return .{ .algorithm = result, .key = key };
}

const Parser = struct {
    source: []const u8,
    pos: usize = 0,
    prefix: []const u8 = "",

    fn whitespace(self: *Parser) void {
        while (self.pos < self.source.len and std.ascii.isWhitespace(self.source[self.pos])) self.pos += 1;
    }
    fn closing(self: *Parser) bool {
        self.whitespace();
        return std.mem.startsWith(u8, self.source[self.pos..], "</");
    }
    fn name(self: *Parser) []const u8 {
        const start = self.pos;
        while (self.pos < self.source.len and (std.ascii.isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == ':' or self.source[self.pos] == '_')) self.pos += 1;
        return self.source[start..self.pos];
    }
    fn matches(self: *Parser, actual: []const u8, expected: []const u8) bool {
        if (self.prefix.len == 0) return std.mem.eql(u8, actual, expected);
        return actual.len == self.prefix.len + 1 + expected.len and std.mem.startsWith(u8, actual, self.prefix) and actual[self.prefix.len] == ':' and std.mem.eql(u8, actual[self.prefix.len + 1 ..], expected);
    }
    fn nextIs(self: *Parser, expected: []const u8) bool {
        self.whitespace();
        const saved = self.pos;
        defer self.pos = saved;
        if (self.pos >= self.source.len or self.source[self.pos] != '<') return false;
        self.pos += 1;
        return self.matches(self.name(), expected);
    }
    fn open(self: *Parser, expected: []const u8, root: bool) Error!void {
        self.whitespace();
        try self.expect('<');
        const actual = self.name();
        if (root) if (std.mem.indexOfScalar(u8, actual, ':')) |colon| {
            self.prefix = actual[0..colon];
        };
        if (!self.matches(actual, expected)) return error.MalformedXml;
        self.whitespace();
        if (root and self.pos < self.source.len and self.source[self.pos] != '>') {
            const attribute = self.name();
            if (self.prefix.len == 0) {
                if (!std.mem.eql(u8, attribute, "xmlns")) return error.MalformedXml;
            } else if (!std.mem.startsWith(u8, attribute, "xmlns:") or !std.mem.eql(u8, attribute[6..], self.prefix)) return error.MalformedXml;
            self.whitespace();
            try self.expect('=');
            self.whitespace();
            if (self.pos >= self.source.len) return error.MalformedXml;
            const quote = self.source[self.pos];
            if (quote != '\'' and quote != '"') return error.MalformedXml;
            self.pos += 1;
            const end = std.mem.indexOfScalarPos(u8, self.source, self.pos, quote) orelse return error.MalformedXml;
            if (!std.mem.eql(u8, self.source[self.pos..end], "http://s3.amazonaws.com/doc/2006-03-01/")) return error.MalformedXml;
            self.pos = end + 1;
            self.whitespace();
        } else if (root and self.prefix.len != 0) return error.MalformedXml;
        try self.expect('>');
    }
    fn close(self: *Parser, expected: []const u8) Error!void {
        self.whitespace();
        try self.expect('<');
        try self.expect('/');
        if (!self.matches(self.name(), expected)) return error.MalformedXml;
        self.whitespace();
        try self.expect('>');
    }
    fn text(self: *Parser) Error![]const u8 {
        const end = std.mem.indexOfScalarPos(u8, self.source, self.pos, '<') orelse return error.MalformedXml;
        const value = std.mem.trim(u8, self.source[self.pos..end], " \t\r\n");
        self.pos = end;
        return value;
    }
    fn expect(self: *Parser, character: u8) Error!void {
        if (self.pos >= self.source.len or self.source[self.pos] != character) return error.MalformedXml;
        self.pos += 1;
    }
};

test "SSE-S3 configuration parses namespaces and rejects invalid rules" {
    try parse(configuration_xml);
    try parse("<s:ServerSideEncryptionConfiguration xmlns:s='http://s3.amazonaws.com/doc/2006-03-01/'><s:Rule><s:ApplyServerSideEncryptionByDefault><s:SSEAlgorithm>AES256</s:SSEAlgorithm></s:ApplyServerSideEncryptionByDefault></s:Rule></s:ServerSideEncryptionConfiguration>");
    try std.testing.expectEqual(.kms, try parseAlgorithm("<ServerSideEncryptionConfiguration><Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>aws:kms</SSEAlgorithm></ApplyServerSideEncryptionByDefault></Rule></ServerSideEncryptionConfiguration>"));
    try std.testing.expectError(error.MalformedXml, parse("<ServerSideEncryptionConfiguration><Rule></Rule></ServerSideEncryptionConfiguration>"));
    try std.testing.expectError(error.MalformedXml, parse(configuration_xml ++ "trailing"));
}

pub fn parse(body: []const u8) Error!void {
    _ = try parseAlgorithm(body);
}

pub const kms_configuration_xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ServerSideEncryptionConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>aws:kms</SSEAlgorithm></ApplyServerSideEncryptionByDefault></Rule></ServerSideEncryptionConfiguration>";

test "KMS bucket configuration parses key and rejects unsafe or incompatible names" {
    const prefix = "<ServerSideEncryptionConfiguration><Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>";
    const suffix = "</KMSMasterKeyID></ApplyServerSideEncryptionByDefault></Rule></ServerSideEncryptionConfiguration>";
    const result = try parseConfiguration(prefix ++ "aws:kms</SSEAlgorithm><KMSMasterKeyID>bucket-key" ++ suffix);
    try std.testing.expectEqual(.kms, result.algorithm);
    try std.testing.expectEqualStrings("bucket-key", result.key.slice());
    try std.testing.expectError(error.InvalidArgument, parseConfiguration(prefix ++ "AES256</SSEAlgorithm><KMSMasterKeyID>bucket-key" ++ suffix));
    try std.testing.expectError(error.InvalidArgument, parseConfiguration(prefix ++ "aws:kms</SSEAlgorithm><KMSMasterKeyID>../escape" ++ suffix));
    const probe = try parseConfiguration(prefix ++ "aws:kms</SSEAlgorithm><KMSMasterKeyID>zigfs-internal-kms-probe" ++ suffix);
    try std.testing.expectEqualStrings("zigfs-internal-kms-probe", probe.key.slice());
}
