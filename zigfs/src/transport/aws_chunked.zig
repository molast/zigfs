const std = @import("std");
const sigv4 = @import("../auth/sigv4.zig");
const Crc64Nvme = @import("../common/checksum.zig").Crc64Nvme;
const byte_stream = @import("../ports/byte_stream.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Trailer = enum {
    none,
    crc64nvme,
};

pub const Failure = enum {
    none,
    malformed_chunk_header,
    unexpected_end,
    invalid_chunk_ending,
    invalid_final_ending,
    signature_mismatch,
    malformed_trailer,
    trailer_signature_mismatch,
    checksum_mismatch,
    decoded_length_mismatch,
};

pub const Source = struct {
    reader: *std.Io.Reader,
    verifier: sigv4.StreamingVerifier,
    expected_decoded_length: u64,
    trailer: Trailer,
    decoded_length: u64 = 0,
    chunk_remaining: u64 = 0,
    chunk_hash: Sha256 = Sha256.init(.{}),
    chunk_signature: [64]u8 = undefined,
    chunk_active: bool = false,
    finished: bool = false,
    failure: Failure = .none,
    crc64nvme: Crc64Nvme = Crc64Nvme.init(),
    verified_crc64nvme: ?u64 = null,

    pub fn init(
        reader: *std.Io.Reader,
        verifier: sigv4.StreamingVerifier,
        expected_decoded_length: u64,
        trailer: Trailer,
    ) Source {
        return .{
            .reader = reader,
            .verifier = verifier,
            .expected_decoded_length = expected_decoded_length,
            .trailer = trailer,
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
        self.crc64nvme.update(buffer[0..count]);
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
        switch (self.trailer) {
            .none => {
                const trailer_end = readCrlfLine(self.reader) catch {
                    self.failure = .invalid_final_ending;
                    return error.ReadFailed;
                };
                if (trailer_end.len != 0) {
                    self.failure = .invalid_final_ending;
                    return error.ReadFailed;
                }
            },
            .crc64nvme => try self.finishCrc64NvmeTrailer(),
        }
        self.finished = true;
    }

    fn finishCrc64NvmeTrailer(self: *Source) error{ReadFailed}!void {
        const checksum_line = readLfLine(self.reader) catch {
            self.failure = .malformed_trailer;
            return error.ReadFailed;
        };
        const checksum_prefix = "x-amz-checksum-crc64nvme:";
        if (!std.mem.startsWith(u8, checksum_line, checksum_prefix)) {
            self.failure = .malformed_trailer;
            return error.ReadFailed;
        }
        const encoded = checksum_line[checksum_prefix.len..];
        const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch {
            self.failure = .malformed_trailer;
            return error.ReadFailed;
        };
        if (decoded_size != 8) {
            self.failure = .malformed_trailer;
            return error.ReadFailed;
        }
        var checksum_bytes: [8]u8 = undefined;
        std.base64.standard.Decoder.decode(&checksum_bytes, encoded) catch {
            self.failure = .malformed_trailer;
            return error.ReadFailed;
        };
        const expected_checksum = std.mem.readInt(u64, &checksum_bytes, .big);
        var canonical_buffer: [128]u8 = undefined;
        const canonical_trailer = std.fmt.bufPrint(&canonical_buffer, "{s}\n", .{checksum_line}) catch {
            self.failure = .malformed_trailer;
            return error.ReadFailed;
        };
        var trailer_hash: [32]u8 = undefined;
        Sha256.hash(canonical_trailer, &trailer_hash, .{});

        const separator = readCrlfLine(self.reader) catch {
            self.failure = .malformed_trailer;
            return error.ReadFailed;
        };
        if (separator.len != 0) {
            self.failure = .malformed_trailer;
            return error.ReadFailed;
        }
        const signature_line = readCrlfLine(self.reader) catch {
            self.failure = .malformed_trailer;
            return error.ReadFailed;
        };
        const signature_separator = std.mem.indexOfScalar(u8, signature_line, ':') orelse {
            self.failure = .malformed_trailer;
            return error.ReadFailed;
        };
        if (!std.ascii.eqlIgnoreCase(signature_line[0..signature_separator], "x-amz-trailer-signature")) {
            self.failure = .malformed_trailer;
            return error.ReadFailed;
        }
        self.verifier.verifyTrailerHash(
            trailer_hash,
            signature_line[signature_separator + 1 ..],
        ) catch {
            self.failure = .trailer_signature_mismatch;
            return error.ReadFailed;
        };
        const final_end = readCrlfLine(self.reader) catch {
            self.failure = .invalid_final_ending;
            return error.ReadFailed;
        };
        if (final_end.len != 0) {
            self.failure = .invalid_final_ending;
            return error.ReadFailed;
        }
        if (self.crc64nvme.final() != expected_checksum) {
            self.failure = .checksum_mismatch;
            return error.ReadFailed;
        }
        self.verified_crc64nvme = expected_checksum;
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

fn readLfLine(reader: *std.Io.Reader) error{ReadFailed}![]const u8 {
    const raw = (reader.takeDelimiter('\n') catch return error.ReadFailed) orelse {
        return error.ReadFailed;
    };
    const line = if (raw.len != 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
    if (std.mem.indexOfScalar(u8, line, '\r') != null) return error.ReadFailed;
    return line;
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
    var source = Source.init(&reader, verifier, 1, .none);
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
    var source = Source.init(&reader, verifier, payload.len, .none);
    defer source.deinit();
    var output: [64]u8 = undefined;
    const length = try source.interface().read(&output);
    try std.testing.expectEqualStrings(payload, output[0..length]);
    try std.testing.expectEqual(@as(usize, 0), try source.interface().read(&output));
    try std.testing.expectEqual(Failure.none, source.failure);
}

test "aws chunked source verifies a signed CRC64NVME trailer before EOF" {
    const secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY";
    const amz_date = "20130524T000000Z";
    const scope_date = "20130524";
    const region = "us-east-1";
    const payload = "signed trailer payload\n";
    const seed_signature = [_]u8{0x6b} ** 32;
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
    const checksum = Crc64Nvme.hash(payload);
    var checksum_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &checksum_bytes, checksum, .big);
    var checksum_base64_buffer: [12]u8 = undefined;
    const checksum_base64 = std.base64.standard.Encoder.encode(&checksum_base64_buffer, &checksum_bytes);
    var canonical_buffer: [128]u8 = undefined;
    const canonical_trailer = try std.fmt.bufPrint(
        &canonical_buffer,
        "x-amz-checksum-crc64nvme:{s}\n",
        .{checksum_base64},
    );
    const trailer_signature = testTrailerSignature(
        secret_key,
        amz_date,
        scope_date,
        region,
        final_signature,
        canonical_trailer,
    );
    const data_signature_hex = std.fmt.bytesToHex(data_signature, .lower);
    const final_signature_hex = std.fmt.bytesToHex(final_signature, .lower);
    const trailer_signature_hex = std.fmt.bytesToHex(trailer_signature, .lower);
    const framed = try std.fmt.allocPrint(
        std.testing.allocator,
        "{x};chunk-signature={s}\r\n{s}\r\n0;chunk-signature={s}\r\n" ++
            "{s}\r\nx-amz-trailer-signature:{s}\r\n\r\n",
        .{
            payload.len,
            &data_signature_hex,
            payload,
            &final_signature_hex,
            canonical_trailer,
            &trailer_signature_hex,
        },
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
            .signed_headers = "host;x-amz-content-sha256;x-amz-date;x-amz-trailer",
            .signature = seed_signature,
        },
        secret_key,
    );
    var source = Source.init(&reader, verifier, payload.len, .crc64nvme);
    defer source.deinit();
    var output: [64]u8 = undefined;
    const length = try source.interface().read(&output);
    try std.testing.expectEqualStrings(payload, output[0..length]);
    try std.testing.expectEqual(@as(usize, 0), try source.interface().read(&output));
    try std.testing.expectEqual(checksum, source.verified_crc64nvme.?);
    try std.testing.expectEqual(Failure.none, source.failure);
}

test "aws chunked source rejects a validly signed wrong trailer checksum" {
    const secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY";
    const amz_date = "20130524T000000Z";
    const scope_date = "20130524";
    const region = "us-east-1";
    const payload = "payload";
    const seed_signature = [_]u8{0x7c} ** 32;
    const data_signature = testChunkSignature(secret_key, amz_date, scope_date, region, seed_signature, payload);
    const final_signature = testChunkSignature(secret_key, amz_date, scope_date, region, data_signature, "");
    var checksum_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &checksum_bytes, Crc64Nvme.hash(payload) +% 1, .big);
    var checksum_base64_buffer: [12]u8 = undefined;
    const checksum_base64 = std.base64.standard.Encoder.encode(&checksum_base64_buffer, &checksum_bytes);
    var canonical_buffer: [128]u8 = undefined;
    const canonical_trailer = try std.fmt.bufPrint(
        &canonical_buffer,
        "x-amz-checksum-crc64nvme:{s}\n",
        .{checksum_base64},
    );
    const trailer_signature = testTrailerSignature(
        secret_key,
        amz_date,
        scope_date,
        region,
        final_signature,
        canonical_trailer,
    );
    const framed = try std.fmt.allocPrint(
        std.testing.allocator,
        "{x};chunk-signature={s}\r\n{s}\r\n0;chunk-signature={s}\r\n" ++
            "{s}\r\nx-amz-trailer-signature:{s}\r\n\r\n",
        .{
            payload.len,
            &std.fmt.bytesToHex(data_signature, .lower),
            payload,
            &std.fmt.bytesToHex(final_signature, .lower),
            canonical_trailer,
            &std.fmt.bytesToHex(trailer_signature, .lower),
        },
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
            .signed_headers = "host;x-amz-content-sha256;x-amz-date;x-amz-trailer",
            .signature = seed_signature,
        },
        secret_key,
    );
    var source = Source.init(&reader, verifier, payload.len, .crc64nvme);
    defer source.deinit();
    var output: [64]u8 = undefined;
    _ = try source.interface().read(&output);
    try std.testing.expectError(error.ReadFailed, source.interface().read(&output));
    try std.testing.expectEqual(Failure.checksum_mismatch, source.failure);
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

fn testTrailerSignature(
    secret_key: []const u8,
    amz_date: []const u8,
    scope_date: []const u8,
    region: []const u8,
    previous_signature: [32]u8,
    trailer: []const u8,
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
    var trailer_hash: [32]u8 = undefined;
    Sha256.hash(trailer, &trailer_hash, .{});
    const previous_hex = std.fmt.bytesToHex(previous_signature, .lower);
    const trailer_hex = std.fmt.bytesToHex(trailer_hash, .lower);
    var string_buffer: [512]u8 = undefined;
    const string_to_sign = std.fmt.bufPrint(
        &string_buffer,
        "AWS4-HMAC-SHA256-TRAILER\n{s}\n{s}/{s}/s3/aws4_request\n{s}\n{s}",
        .{ amz_date, scope_date, region, &previous_hex, &trailer_hex },
    ) catch unreachable;
    var signature: [32]u8 = undefined;
    HmacSha256.create(&signature, string_to_sign, &signing_key);
    return signature;
}
