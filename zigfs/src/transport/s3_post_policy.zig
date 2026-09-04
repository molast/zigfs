const std = @import("std");
const byte_stream = @import("../ports/byte_stream.zig");

pub const max_boundary_length: usize = 70;
pub const max_header_line_length: usize = 8 * 1024;
pub const max_field_value_length: usize = 64 * 1024;
pub const max_fields: usize = 128;

pub const Error = error{
    OutOfMemory,
    InvalidContentType,
    InvalidBoundary,
    InvalidBody,
    FieldTooLarge,
    TooManyFields,
    DuplicateField,
};

pub const Failure = enum {
    none,
    invalid_body,
    field_too_large,
};

pub const Field = struct {
    name: []u8,
    value: []u8,

    pub fn deinit(self: Field, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

pub const FileInfo = struct {
    name: []const u8,
    filename: []const u8,
    content_type: []const u8,
};

const PartHeaders = struct {
    name: []u8,
    filename: ?[]u8,
    content_type: []u8,

    fn deinit(self: PartHeaders, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.filename) |value| allocator.free(value);
        allocator.free(self.content_type);
    }
};

/// Incrementally parses a browser multipart form until the file part, then
/// exposes that part as a byte stream. Form fields are bounded and owned by
/// this parser; object bytes never accumulate in memory.
pub const Parser = struct {
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    stream_remaining: u64,
    input: [16 * 1024]u8 = undefined,
    input_start: usize = 0,
    input_end: usize = 0,
    boundary: []u8,
    marker: []u8,
    fields: std.ArrayList(Field) = .empty,
    file_name: ?[]u8 = null,
    file_filename: ?[]u8 = null,
    file_content_type: ?[]u8 = null,
    pending: [max_boundary_length + 8]u8 = undefined,
    pending_len: usize = 0,
    part_done: bool = false,
    final_boundary: bool = false,
    initial_consumed: bool = false,
    file_started: bool = false,
    failure: Failure = .none,

    pub fn init(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        content_length: ?u64,
        content_type: []const u8,
    ) Error!Parser {
        const length = content_length orelse return error.InvalidBody;
        const boundary_value = try parseBoundary(allocator, content_type);
        errdefer allocator.free(boundary_value);
        const marker = std.fmt.allocPrint(allocator, "\r\n--{s}", .{boundary_value}) catch {
            return error.OutOfMemory;
        };
        errdefer allocator.free(marker);
        if (marker.len > max_boundary_length + 4) return error.InvalidBoundary;
        return .{
            .allocator = allocator,
            .reader = reader,
            .stream_remaining = length,
            .boundary = boundary_value,
            .marker = marker,
        };
    }

    pub fn deinit(self: *Parser) void {
        for (self.fields.items) |field| field.deinit(self.allocator);
        self.fields.deinit(self.allocator);
        if (self.file_name) |value| self.allocator.free(value);
        if (self.file_filename) |value| self.allocator.free(value);
        if (self.file_content_type) |value| self.allocator.free(value);
        self.allocator.free(self.boundary);
        self.allocator.free(self.marker);
        self.* = undefined;
    }

    pub fn parseUntilFile(self: *Parser) Error!FileInfo {
        if (self.file_started or self.initial_consumed) return error.InvalidBody;
        try self.consumeInitialBoundary();
        while (!self.final_boundary) {
            var headers = try self.parsePartHeaders();
            defer headers.deinit(self.allocator);
            self.resetPart();
            if (std.ascii.eqlIgnoreCase(headers.name, "file")) {
                if (self.file_started) return error.DuplicateField;
                self.file_started = true;
                self.file_name = self.allocator.dupe(u8, headers.name) catch return error.OutOfMemory;
                self.file_filename = self.allocator.dupe(u8, headers.filename orelse "") catch return error.OutOfMemory;
                self.file_content_type = self.allocator.dupe(u8, headers.content_type) catch return error.OutOfMemory;
                return .{
                    .name = self.file_name.?,
                    .filename = self.file_filename.?,
                    .content_type = self.file_content_type.?,
                };
            }
            if (headers.filename != null) return error.InvalidBody;
            const value = try self.readFieldValue();
            if (self.fields.items.len >= max_fields) {
                self.allocator.free(value);
                return error.TooManyFields;
            }
            const name = self.allocator.dupe(u8, headers.name) catch {
                self.allocator.free(value);
                return error.OutOfMemory;
            };
            self.fields.append(self.allocator, .{ .name = name, .value = value }) catch {
                self.allocator.free(name);
                self.allocator.free(value);
                return error.OutOfMemory;
            };
            if (self.final_boundary) return error.InvalidBody;
        }
        return error.InvalidBody;
    }

    pub fn fieldsView(self: *const Parser) []const Field {
        return self.fields.items;
    }

    pub fn fileSource(self: *Parser) byte_stream.Source {
        return .{ .context = self, .vtable = &.{ .read = readFile } };
    }

    pub fn finish(self: *const Parser) Error!void {
        if (!self.file_started or !self.part_done or !self.final_boundary or self.streamRemaining() != 0) {
            return error.InvalidBody;
        }
    }

    pub fn lookup(self: *const Parser, name: []const u8) Error!?[]const u8 {
        var found: ?[]const u8 = null;
        for (self.fields.items) |field| {
            if (!std.ascii.eqlIgnoreCase(field.name, name)) continue;
            if (found != null) return error.DuplicateField;
            found = field.value;
        }
        return found;
    }

    fn resetPart(self: *Parser) void {
        self.pending_len = 0;
        self.part_done = false;
        self.failure = .none;
    }

    fn consumeInitialBoundary(self: *Parser) Error!void {
        self.initial_consumed = true;
        var prefix: [max_boundary_length + 2]u8 = undefined;
        const expected = std.fmt.bufPrint(&prefix, "--{s}", .{self.boundary}) catch return error.InvalidBoundary;
        for (expected) |character| if (try self.readByte()) |actual| {
            if (actual != character) return error.InvalidBody;
        } else return error.InvalidBody;
        const first = (try self.readByte()) orelse return error.InvalidBody;
        const second = (try self.readByte()) orelse return error.InvalidBody;
        if (first == '-' and second == '-') {
            self.final_boundary = true;
            try self.consumeFinalTrailer();
            return;
        }
        if (first != '\r' or second != '\n') return error.InvalidBody;
    }

    fn parsePartHeaders(self: *Parser) Error!PartHeaders {
        var disposition: ?[]u8 = null;
        var filename: ?[]u8 = null;
        var content_type: []u8 = self.allocator.dupe(u8, "application/octet-stream") catch return error.OutOfMemory;
        errdefer {
            if (disposition) |value| self.allocator.free(value);
            if (filename) |value| self.allocator.free(value);
            self.allocator.free(content_type);
        }
        while (true) {
            const line = try self.readLine();
            defer self.allocator.free(line);
            if (line.len == 0) break;
            const separator = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidBody;
            const name = std.mem.trim(u8, line[0..separator], " \t");
            const value = std.mem.trim(u8, line[separator + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "content-disposition")) {
                if (disposition != null) return error.InvalidBody;
                const parsed = try parseDisposition(self.allocator, value);
                disposition = parsed.name;
                filename = parsed.filename;
            } else if (std.ascii.eqlIgnoreCase(name, "content-type")) {
                self.allocator.free(content_type);
                content_type = self.allocator.dupe(u8, value) catch return error.OutOfMemory;
            } else if (std.ascii.eqlIgnoreCase(name, "content-transfer-encoding")) {
                return error.InvalidBody;
            }
        }
        return .{
            .name = disposition orelse return error.InvalidBody,
            .filename = filename,
            .content_type = content_type,
        };
    }

    fn readLine(self: *Parser) Error![]u8 {
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(self.allocator);
        while (true) {
            const character = (try self.readByte()) orelse return error.InvalidBody;
            if (character == '\r') {
                const newline = (try self.readByte()) orelse return error.InvalidBody;
                if (newline != '\n') return error.InvalidBody;
                return line.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
            }
            if (character == '\n' or line.items.len >= max_header_line_length) return error.InvalidBody;
            line.append(self.allocator, character) catch return error.OutOfMemory;
        }
    }

    fn readFieldValue(self: *Parser) Error![]u8 {
        var value: std.ArrayList(u8) = .empty;
        errdefer value.deinit(self.allocator);
        var buffer: [4096]u8 = undefined;
        while (true) {
            const count = self.readPart(&buffer) catch |err| {
                self.failure = if (err == error.FieldTooLarge) .field_too_large else .invalid_body;
                return err;
            };
            if (count == 0) break;
            if (value.items.len > max_field_value_length - count) return error.FieldTooLarge;
            value.appendSlice(self.allocator, buffer[0..count]) catch return error.OutOfMemory;
        }
        return value.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    fn readFile(context: *anyopaque, output: []u8) byte_stream.Source.Error!usize {
        const self: *Parser = @ptrCast(@alignCast(context));
        const count = self.readPart(output) catch {
            self.failure = .invalid_body;
            return error.ReadFailed;
        };
        if (count == 0 and !self.final_boundary) {
            self.failure = .invalid_body;
            return error.ReadFailed;
        }
        return count;
    }

    fn readPart(self: *Parser, output: []u8) Error!usize {
        if (self.part_done) return 0;
        if (output.len == 0) return 0;
        var written: usize = 0;
        while (written < output.len) {
            if (self.pending_len == self.marker.len) {
                const first = (try self.readByte()) orelse return error.InvalidBody;
                const second = (try self.readByte()) orelse return error.InvalidBody;
                if (first == '-' and second == '-') {
                    self.pending_len = 0;
                    self.part_done = true;
                    self.final_boundary = true;
                    try self.consumeFinalTrailer();
                    return written;
                }
                if (first == '\r' and second == '\n') {
                    self.pending_len = 0;
                    self.part_done = true;
                    self.final_boundary = false;
                    return written;
                }
                if (self.pending_len + 2 > self.pending.len) return error.InvalidBody;
                self.pending[self.pending_len] = first;
                self.pending[self.pending_len + 1] = second;
                self.pending_len += 2;
            }
            while (self.pending_len != 0 and
                !std.mem.startsWith(u8, self.marker, self.pending[0..self.pending_len]))
            {
                output[written] = self.pending[0];
                written += 1;
                std.mem.copyForwards(u8, self.pending[0 .. self.pending_len - 1], self.pending[1..self.pending_len]);
                self.pending_len -= 1;
                if (written == output.len) return written;
            }
            if (self.pending_len == self.marker.len) continue;
            const next = (try self.readByte()) orelse return error.InvalidBody;
            if (self.pending_len >= self.pending.len) return error.InvalidBody;
            self.pending[self.pending_len] = next;
            self.pending_len += 1;
        }
        return written;
    }

    fn consumeFinalTrailer(self: *Parser) Error!void {
        const first = try self.readByte();
        if (first) |value| {
            if (value != '\r') return error.InvalidBody;
            const second = (try self.readByte()) orelse return error.InvalidBody;
            if (second != '\n') return error.InvalidBody;
        }
        if (self.streamRemaining() != 0) return error.InvalidBody;
    }

    fn streamRemaining(self: *const Parser) u64 {
        return self.stream_remaining + (self.input_end - self.input_start);
    }

    fn readByte(self: *Parser) Error!?u8 {
        if (self.input_start == self.input_end) {
            if (self.stream_remaining == 0) return null;
            const requested: usize = @intCast(@min(self.stream_remaining, self.input.len));
            const count = self.reader.readSliceShort(self.input[0..requested]) catch return error.InvalidBody;
            if (count == 0) return error.InvalidBody;
            self.input_start = 0;
            self.input_end = count;
            self.stream_remaining -= count;
        }
        const value = self.input[self.input_start];
        self.input_start += 1;
        return value;
    }
};

const Disposition = struct { name: []u8, filename: ?[]u8 };

fn parseDisposition(allocator: std.mem.Allocator, value: []const u8) Error!Disposition {
    var iterator = std.mem.splitScalar(u8, value, ';');
    const kind = std.mem.trim(u8, iterator.next() orelse "", " \t");
    if (!std.ascii.eqlIgnoreCase(kind, "form-data")) return error.InvalidBody;
    var name: ?[]u8 = null;
    var filename: ?[]u8 = null;
    errdefer {
        if (name) |item| allocator.free(item);
        if (filename) |item| allocator.free(item);
    }
    while (iterator.next()) |raw_parameter| {
        const parameter = std.mem.trim(u8, raw_parameter, " \t");
        const equals = std.mem.indexOfScalar(u8, parameter, '=') orelse return error.InvalidBody;
        const parameter_name = std.mem.trim(u8, parameter[0..equals], " \t");
        const parameter_value = std.mem.trim(u8, parameter[equals + 1 ..], " \t");
        if (parameter_value.len < 2 or parameter_value[0] != '"' or parameter_value[parameter_value.len - 1] != '"') {
            return error.InvalidBody;
        }
        const parsed = try unquote(allocator, parameter_value[1 .. parameter_value.len - 1]);
        if (std.ascii.eqlIgnoreCase(parameter_name, "name")) {
            if (name != null) {
                allocator.free(parsed);
                return error.InvalidBody;
            }
            name = parsed;
        } else if (std.ascii.eqlIgnoreCase(parameter_name, "filename")) {
            if (filename != null) {
                allocator.free(parsed);
                return error.InvalidBody;
            }
            filename = parsed;
        } else {
            allocator.free(parsed);
        }
    }
    return .{ .name = name orelse return error.InvalidBody, .filename = filename };
}

fn unquote(allocator: std.mem.Allocator, value: []const u8) Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var escaped = false;
    for (value) |character| {
        if (escaped) {
            try output.append(allocator, character);
            escaped = false;
        } else if (character == '\\') {
            escaped = true;
        } else {
            try output.append(allocator, character);
        }
    }
    if (escaped) return error.InvalidBody;
    return output.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn parseBoundary(allocator: std.mem.Allocator, content_type: []const u8) Error![]u8 {
    var iterator = std.mem.splitScalar(u8, content_type, ';');
    const media_type = std.mem.trim(u8, iterator.next() orelse "", " \t");
    if (!std.ascii.eqlIgnoreCase(media_type, "multipart/form-data")) return error.InvalidContentType;
    var boundary: ?[]u8 = null;
    errdefer if (boundary) |value| allocator.free(value);
    while (iterator.next()) |raw_parameter| {
        const parameter = std.mem.trim(u8, raw_parameter, " \t");
        const equals = std.mem.indexOfScalar(u8, parameter, '=') orelse continue;
        const name = std.mem.trim(u8, parameter[0..equals], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "boundary")) continue;
        if (boundary != null) return error.InvalidBoundary;
        var value = std.mem.trim(u8, parameter[equals + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
        if (value.len == 0 or value.len > max_boundary_length or
            std.mem.indexOfAny(u8, value, "\r\n\";") != null) return error.InvalidBoundary;
        boundary = allocator.dupe(u8, value) catch return error.OutOfMemory;
    }
    return boundary orelse error.InvalidBoundary;
}

test "multipart parser streams file and preserves form fields" {
    const body =
        "--boundary\r\n" ++
        "Content-Disposition: form-data; name=\"key\"\r\n\r\n" ++
        "hello.txt\r\n" ++
        "--boundary\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"hello.txt\"\r\n" ++
        "Content-Type: text/plain\r\n\r\n" ++
        "hello world\r\n" ++
        "--boundary--\r\n";
    var reader = std.Io.Reader.fixed(body);
    var parser = try Parser.init(std.testing.allocator, &reader, body.len, "multipart/form-data; boundary=boundary");
    defer parser.deinit();
    const file = try parser.parseUntilFile();
    try std.testing.expectEqualStrings("hello.txt", (try parser.lookup("key")).?);
    try std.testing.expectEqualStrings("hello.txt", file.filename);
    var source = parser.fileSource();
    var output: [64]u8 = undefined;
    const count = try source.read(&output);
    try std.testing.expectEqualStrings("hello world", output[0..count]);
    try std.testing.expectEqual(@as(usize, 0), try source.read(&output));
    try parser.finish();
}
