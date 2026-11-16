//! Bounded S3 XML decoder. No DTD/external entities, namespaces do not alter local names.
const std = @import("std");
const A = std.mem.Allocator;
pub const Node = struct { name: []const u8, text: []const u8, children: []const Node };
const Parser = struct {
    a: A,
    bytes: []const u8,
    at: usize = 0,
    nodes: usize = 0,
    fn skip(self: *Parser) void {
        while (self.at < self.bytes.len and std.ascii.isWhitespace(self.bytes[self.at])) self.at += 1;
    }
    fn starts(self: *Parser, text: []const u8) bool {
        return std.mem.startsWith(u8, self.bytes[self.at..], text);
    }
    fn name(self: *Parser) ![]const u8 {
        const start = self.at;
        while (self.at < self.bytes.len) : (self.at += 1) {
            const c = self.bytes[self.at];
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != ':' and c != '.') break;
        }
        if (self.at == start) return error.InvalidXml;
        return self.bytes[start..self.at];
    }
    fn node(self: *Parser, depth: usize) anyerror!Node {
        if (depth > 32 or self.nodes >= 100000 or !self.starts("<")) return error.InvalidXml;
        self.nodes += 1;
        self.at += 1;
        const full_name = try self.name();
        const local = if (std.mem.lastIndexOfScalar(u8, full_name, ':')) |i| full_name[i + 1 ..] else full_name;
        while (true) {
            self.skip();
            if (self.starts("/>")) {
                self.at += 2;
                return .{ .name = local, .text = "", .children = &.{} };
            }
            if (self.starts(">")) {
                self.at += 1;
                break;
            }
            _ = try self.name();
            self.skip();
            if (!self.starts("=")) return error.InvalidXml;
            self.at += 1;
            self.skip();
            if (self.at == self.bytes.len or (self.bytes[self.at] != '"' and self.bytes[self.at] != '\'')) return error.InvalidXml;
            const quote = self.bytes[self.at];
            self.at += 1;
            while (self.at < self.bytes.len and self.bytes[self.at] != quote) : (self.at += 1) {
                if (self.bytes[self.at] == '<') return error.InvalidXml;
            }
            if (self.at == self.bytes.len) return error.InvalidXml;
            self.at += 1;
        }
        var children: std.ArrayList(Node) = .empty;
        var text: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.at == self.bytes.len) return error.InvalidXml;
            if (self.starts("</")) {
                self.at += 2;
                if (!std.mem.eql(u8, try self.name(), full_name)) return error.InvalidXml;
                self.skip();
                if (!self.starts(">")) return error.InvalidXml;
                self.at += 1;
                break;
            }
            if (self.starts("<!--")) {
                const end = std.mem.indexOf(u8, self.bytes[self.at + 4 ..], "-->") orelse return error.InvalidXml;
                self.at += end + 7;
                continue;
            }
            if (self.starts("<")) {
                if (self.starts("<!") or self.starts("<?")) return error.InvalidXml;
                try children.append(self.a, try self.node(depth + 1));
            } else {
                const start = self.at;
                while (self.at < self.bytes.len and self.bytes[self.at] != '<') self.at += 1;
                try text.appendSlice(self.a, try decode(self.a, self.bytes[start..self.at]));
            }
        }
        if (children.items.len > 0 and std.mem.trim(u8, text.items, " \t\r\n").len != 0) return error.InvalidXml;
        return .{ .name = local, .text = text.items, .children = children.items };
    }
};
pub fn decode(a: A, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '&') {
            try out.append(a, text[i]);
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, text, i, ';') orelse return error.InvalidXml;
        const entity = text[i + 1 .. end];
        if (std.mem.eql(u8, entity, "amp")) try out.append(a, '&') else if (std.mem.eql(u8, entity, "lt")) try out.append(a, '<') else if (std.mem.eql(u8, entity, "gt")) try out.append(a, '>') else if (std.mem.eql(u8, entity, "quot")) try out.append(a, '"') else if (std.mem.eql(u8, entity, "apos")) try out.append(a, '\'') else if (std.mem.startsWith(u8, entity, "#")) {
            const hex = std.mem.startsWith(u8, entity, "#x");
            const cp = std.fmt.parseInt(u21, entity[if (hex) @as(usize, 2) else 1..], if (hex) 16 else 10) catch return error.InvalidXml;
            if (cp == 0 or cp < 32 and cp != 9 and cp != 10 and cp != 13) return error.InvalidXml;
            var buffer: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buffer) catch return error.InvalidXml;
            try out.appendSlice(a, buffer[0..n]);
        } else return error.InvalidXml;
        i = end;
    }
    return out.items;
}
pub fn parse(a: A, bytes: []const u8) !Node {
    if (bytes.len > 4 * 1024 * 1024 or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidXml;
    var p: Parser = .{ .a = a, .bytes = bytes };
    p.skip();
    if (p.starts("<?xml")) {
        const end = std.mem.indexOf(u8, bytes[p.at..], "?>") orelse return error.InvalidXml;
        p.at += end + 2;
        p.skip();
    }
    const root = try p.node(0);
    p.skip();
    if (p.at != bytes.len) return error.InvalidXml;
    return root;
}
pub fn child(node: Node, name: []const u8) ?[]const u8 {
    for (node.children) |n| if (std.mem.eql(u8, n.name, name)) return n.text;
    return null;
}
pub fn toJson(a: A, node: Node) anyerror!std.json.Value {
    if (node.children.len == 0) return .{ .string = node.text };
    var object: std.json.ObjectMap = .{};
    for (node.children) |n| {
        const value = try toJson(a, n);
        const entry = try object.getOrPut(a, n.name);
        if (entry.found_existing) {
            if (entry.value_ptr.* != .array) {
                var arr: std.array_list.Managed(std.json.Value) = .init(a);
                try arr.append(entry.value_ptr.*);
                entry.value_ptr.* = .{ .array = arr };
            }
            try entry.value_ptr.array.append(value);
        } else if (std.mem.eql(u8, n.name, "Bucket") or std.mem.eql(u8, n.name, "Contents") or std.mem.eql(u8, n.name, "CommonPrefixes") or std.mem.eql(u8, n.name, "Part") or std.mem.eql(u8, n.name, "Upload") or std.mem.eql(u8, n.name, "Deleted") or std.mem.eql(u8, n.name, "Error")) {
            var arr: std.array_list.Managed(std.json.Value) = .init(a);
            try arr.append(value);
            entry.value_ptr.* = .{ .array = arr };
        } else entry.value_ptr.* = value;
    }
    return .{ .object = object };
}
test "XML namespaces entities repeated children and invalid documents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try parse(a, "<?xml version=\"1.0\"?><s:Result xmlns:s='urn:s3'><Contents><Key>a&amp;&#x4E2D;</Key></Contents><Contents><Key>b</Key></Contents></s:Result>");
    const result = try toJson(a, root);
    try std.testing.expectEqual(@as(usize, 2), result.object.get("Contents").?.array.items.len);
    try std.testing.expectEqualStrings("a&中", result.object.get("Contents").?.array.items[0].object.get("Key").?.string);
    try std.testing.expectError(error.InvalidXml, parse(a, "<!DOCTYPE x SYSTEM 'file:///etc/passwd'><x/>"));
    try std.testing.expectError(error.InvalidXml, parse(a, "<x>&bad;</x>"));
    try std.testing.expectError(error.InvalidXml, parse(a, "<x></y>"));
    try std.testing.expectError(error.InvalidXml, parse(a, "<x/>trailing"));
}

fn escape(writer: *std.Io.Writer, text: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidXml;
    for (text) |c| {
        if (c < 32 and c != 9 and c != 10 and c != 13) return error.InvalidXml;
        try writer.writeAll(switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&apos;",
            else => &.{c},
        });
    }
}
fn writeNode(writer: *std.Io.Writer, node: Node, namespace: ?[]const u8, depth: usize) anyerror!void {
    if (depth > 32 or node.name.len == 0 or !std.ascii.isAlphabetic(node.name[0])) return error.InvalidXml;
    for (node.name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return error.InvalidXml;
    if (node.text.len > 0 and node.children.len > 0) return error.InvalidXml;
    try writer.print("<{s}", .{node.name});
    if (namespace) |ns| {
        try writer.writeAll(" xmlns=\"");
        try escape(writer, ns);
        try writer.writeByte('"');
    }
    try writer.writeByte('>');
    try escape(writer, node.text);
    for (node.children) |n| try writeNode(writer, n, null, depth + 1);
    try writer.print("</{s}>", .{node.name});
}
pub fn encode(a: A, node: Node, namespace: ?[]const u8) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(a);
    try writer.writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
    try writeNode(&writer.writer, node, namespace, 0);
    return writer.toOwnedSlice();
}
test "XML serialization escapes content and validates element names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = try encode(a, .{ .name = "Root", .text = "a<&中\"", .children = &.{} }, "urn:test");
    try std.testing.expectEqualStrings("a<&中\"", (try parse(a, data)).text);
    try std.testing.expectError(error.InvalidXml, encode(a, .{ .name = "x><secret", .text = "", .children = &.{} }, null));
}
