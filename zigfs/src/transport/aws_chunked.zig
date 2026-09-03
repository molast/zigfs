const std = @import("std");
const sigv4 = @import("../auth/sigv4.zig");
const byte_stream = @import("../ports/byte_stream.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Failure = enum {
    none,
    malformed_chunk_header,
    unexpected_end,
    invalid_chunk_ending,
    invalid_final_ending,
    signature_mismatch,
    decoded_length_mismatch,
};

pub const Source = struct {
    reader: *std.Io.Reader,
    verifier: sigv4.StreamingVerifier,
    expected_decoded_length: u64,
    decoded_length: u64 = 0,
    chunk_remaining: u64 = 0,
    chunk_hash: Sha256 = Sha256.init(.{}),
    chunk_signature: [64]u8 = undefined,
    chunk_active: bool = false,
    finished: bool = false,
    failure: Failure = .none,

    pub fn init(
        reader: *std.Io.Reader,
        verifier: sigv4.StreamingVerifier,
        expected_decoded_length: u64,
    ) Source {
        return .{
            .reader = reader,
            .verifier = verifier,
            .expected_decoded_length = expected_decoded_length,
        };
    }

    pub fn deinit(self: *Source) void {
        self.verifier.deinit();
        self.* = undefined;
    }

    pub fn interface(self: *Source) byte_stream.Source {
        return .{ .context = self, .vtable = &.{ .read = read } };
    }

    fn read(context: *anyopaque, buffer: []u8) byte_stream.Source.Error!usize {
        const self: *Source = @ptrCast(@alignCast(context));
        if (buffer.len == 0 or self.finished) return 0;

        if (self.chunk_active and self.chunk_remaining == 0) {
            self.finishChunk() catch return error.ReadFailed;
        }
        while (!self.chunk_active) {
            self.beginChunk() catch return error.ReadFailed;
            if (self.finished) return 0;
        }

        const requested: usize = @intCast(@min(
            self.chunk_remaining,
            @as(u64, @intCast(buffer.len)),
        ));
        const count = self.reader.readSliceShort(buffer[0..requested]) catch {
            self.failure = .unexpected_end;
            return error.ReadFailed;
        };
        if (count == 0) {
            self.failure = .unexpected_end;
            return error.ReadFailed;
        }
        self.chunk_hash.update(buffer[0..count]);
        self.chunk_remaining -= count;
        self.decoded_length = std.math.add(u64, self.decoded_length, count) catch {
            self.failure = .decoded_length_mismatch;
            return error.ReadFailed;
        };
        if (self.decoded_length > self.expected_decoded_length) {
            self.failure = .decoded_length_mismatch;
            return error.ReadFailed;
        }
        return count;
    }

    fn beginChunk(self: *Source) error{ReadFailed}!void {
        const line = readCrlfLine(self.reader) catch {
            self.failure = .malformed_chunk_header;
            return error.ReadFailed;
        };
        const marker = ";chunk-signature=";
        const marker_index = std.mem.indexOf(u8, line, marker) orelse {
            self.failure = .malformed_chunk_header;
            return error.ReadFailed;
        };
        if (std.mem.indexOfPos(u8, line, marker_index + marker.len, ";") != null) {
            self.failure = .malformed_chunk_header;
            return error.ReadFailed;
        }
        const size_text = line[0..marker_index];
        const signature = line[marker_index + marker.len ..];
        if (size_text.len == 0 or signature.len != self.chunk_signature.len) {
            self.failure = .malformed_chunk_header;
            return error.ReadFailed;
        }
        const size = std.fmt.parseInt(u64, size_text, 16) catch {
            self.failure = .malformed_chunk_header;
            return error.ReadFailed;
        };
        @memcpy(&self.chunk_signature, signature);
        self.chunk_hash = Sha256.init(.{});
        self.chunk_remaining = size;

        if (size != 0) {
            self.chunk_active = true;
            return;
        }

        var empty_hash: [32]u8 = undefined;
        self.chunk_hash.final(&empty_hash);
        self.verifier.verifyChunkHash(empty_hash, &self.chunk_signature) catch {
            self.failure = .signature_mismatch;
            return error.ReadFailed;
        };
        if (self.decoded_length != self.expected_decoded_length) {
            self.failure = .decoded_length_mismatch;
            return error.ReadFailed;
        }
        const trailer_end = readCrlfLine(self.reader) catch {
            self.failure = .invalid_final_ending;
            return error.ReadFailed;
        };
        if (trailer_end.len != 0) {
            self.failure = .invalid_final_ending;
            return error.ReadFailed;
        }
        self.finished = true;
    }

    fn finishChunk(self: *Source) error{ReadFailed}!void {
        var ending: [2]u8 = undefined;
        self.reader.readSliceAll(&ending) catch {
            self.failure = .unexpected_end;
            return error.ReadFailed;
        };
        if (!std.mem.eql(u8, &ending, "\r\n")) {
            self.failure = .invalid_chunk_ending;
            return error.ReadFailed;
        }
        var digest: [32]u8 = undefined;
        self.chunk_hash.final(&digest);
        self.verifier.verifyChunkHash(digest, &self.chunk_signature) catch {
            self.failure = .signature_mismatch;
            return error.ReadFailed;
        };
        self.chunk_active = false;
    }
};

fn readCrlfLine(reader: *std.Io.Reader) error{ReadFailed}![]const u8 {
    const raw = (reader.takeDelimiter('\n') catch return error.ReadFailed) orelse {
        return error.ReadFailed;
    };
    if (raw.len == 0 or raw[raw.len - 1] != '\r') return error.ReadFailed;
    return raw[0 .. raw.len - 1];
}

test "aws chunked source rejects malformed framing before publishing EOF" {
    var reader = std.Io.Reader.fixed("1;chunk-signature=bad\r\na\r\n");
    const verifier = try sigv4.StreamingVerifier.init(
        std.testing.allocator,
        &.{.{ .name = "x-amz-date", .value = "20130524T000000Z" }},
        .{
            .access_key = "AKIDEXAMPLE",
            .scope_date = "20130524",
            .region = "us-east-1",
            .signed_headers = "host;x-amz-content-sha256;x-amz-date",
            .signature = .{0} ** 32,
        },
        "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    );
    var source = Source.init(&reader, verifier, 1);
    defer source.deinit();
    var buffer: [1]u8 = undefined;
    try std.testing.expectError(error.ReadFailed, source.interface().read(&buffer));
    try std.testing.expectEqual(Failure.malformed_chunk_header, source.failure);
}

test "aws chunked source verifies and decodes a complete signed payload" {
    const secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY";
    const amz_date = "20130524T000000Z";
    const scope_date = "20130524";
    const region = "us-east-1";
    const payload = "mc streaming payload\n";
    const seed_signature = [_]u8{0x5a} ** 32;
    const data_signature = testChunkSignature(
        secret_key,
        amz_date,
        scope_date,
        region,
        seed_signature,
        payload,
    );
    const final_signature = testChunkSignature(
        secret_key,
        amz_date,
        scope_date,
        region,
        data_signature,
        "",
    );
    const data_signature_hex = std.fmt.bytesToHex(data_signature, .lower);
    const final_signature_hex = std.fmt.bytesToHex(final_signature, .lower);
    const framed = try std.fmt.allocPrint(
        std.testing.allocator,
        "{x};chunk-signature={s}\r\n{s}\r\n0;chunk-signature={s}\r\n\r\n",
        .{ payload.len, &data_signature_hex, payload, &final_signature_hex },
    );
    defer std.testing.allocator.free(framed);

    var reader = std.Io.Reader.fixed(framed);
    const verifier = try sigv4.StreamingVerifier.init(
        std.testing.allocator,
        &.{.{ .name = "x-amz-date", .value = amz_date }},
        .{
            .access_key = "AKIDEXAMPLE",
            .scope_date = scope_date,
            .region = region,
            .signed_headers = "host;x-amz-content-sha256;x-amz-date",
            .signature = seed_signature,
        },
        secret_key,
    );
    var source = Source.init(&reader, verifier, payload.len);
    defer source.deinit();
    var output: [64]u8 = undefined;
    const length = try source.interface().read(&output);
    try std.testing.expectEqualStrings(payload, output[0..length]);
    try std.testing.expectEqual(@as(usize, 0), try source.interface().read(&output));
    try std.testing.expectEqual(Failure.none, source.failure);
}

fn testChunkSignature(
    secret_key: []const u8,
    amz_date: []const u8,
    scope_date: []const u8,
    region: []const u8,
    previous_signature: [32]u8,
    payload: []const u8,
) [32]u8 {
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var prefixed_secret: [128]u8 = undefined;
    @memcpy(prefixed_secret[0..4], "AWS4");
    @memcpy(prefixed_secret[4..][0..secret_key.len], secret_key);
    var date_key: [32]u8 = undefined;
    HmacSha256.create(&date_key, scope_date, prefixed_secret[0 .. 4 + secret_key.len]);
    var region_key: [32]u8 = undefined;
    HmacSha256.create(&region_key, region, &date_key);
    var service_key: [32]u8 = undefined;
    HmacSha256.create(&service_key, "s3", &region_key);
    var signing_key: [32]u8 = undefined;
    HmacSha256.create(&signing_key, "aws4_request", &service_key);
    var empty_hash: [32]u8 = undefined;
    Sha256.hash("", &empty_hash, .{});
    var payload_hash: [32]u8 = undefined;
    Sha256.hash(payload, &payload_hash, .{});
    const previous_hex = std.fmt.bytesToHex(previous_signature, .lower);
    const empty_hex = std.fmt.bytesToHex(empty_hash, .lower);
    const payload_hex = std.fmt.bytesToHex(payload_hash, .lower);
    var string_buffer: [512]u8 = undefined;
    const string_to_sign = std.fmt.bufPrint(
        &string_buffer,
        "AWS4-HMAC-SHA256-PAYLOAD\n{s}\n{s}/{s}/s3/aws4_request\n{s}\n{s}\n{s}",
        .{ amz_date, scope_date, region, &previous_hex, &empty_hex, &payload_hex },
    ) catch unreachable;
    var signature: [32]u8 = undefined;
    HmacSha256.create(&signature, string_to_sign, &signing_key);
    return signature;
}
