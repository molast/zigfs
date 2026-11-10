const std = @import("std");
const id = @import("../common/id.zig");
const byte_stream = @import("byte_stream.zig");

pub const Location = struct {
    encrypted: bool = false,
    upload_id: id.Uuid,
    part_number: u16,
    data_generation: id.Uuid,
};

pub const Integrity = struct {
    size: u64,
    checksum_sha256: [32]u8,
};

pub const Generation = struct {
    location: Location,
    data_present: bool,
    data_size: u64,
};

pub const ScanResult = struct {
    generations: []Generation,

    pub fn deinit(self: ScanResult, allocator: std.mem.Allocator) void {
        allocator.free(self.generations);
    }
};

pub const Staged = struct {
    token: id.Uuid,
    size: u64,
    etag_md5: [16]u8,
    checksum_crc32: u32,
    checksum_crc32c: u32,
    checksum_sha256: [32]u8,
    checksum_sha1: [20]u8,
    checksum_crc64nvme: u64,
};

pub const Error = error{
    OutOfMemory,
    InvalidValue,
    SourceReadFailed,
    SinkWriteFailed,
    NotFound,
    Conflict,
    CorruptData,
    Unavailable,
};

pub const MultipartDataStore = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        cleanup_staged: *const fn (*anyopaque) Error!usize,
        stage_encrypted: ?*const fn (*anyopaque, id.Uuid, byte_stream.Source) Error!Staged = null,
        stage: *const fn (*anyopaque, id.Uuid, byte_stream.Source) Error!Staged,
        publish: *const fn (*anyopaque, Staged, Location) Error!void,
        discard: *const fn (*anyopaque, id.Uuid) void,
        stat: *const fn (*anyopaque, Location) Error!u64,
        read_range: *const fn (*anyopaque, Location, u64, u64, byte_stream.Sink) Error!void,
        delete_upload: *const fn (*anyopaque, id.Uuid) Error!void,
        scan_generations: *const fn (*anyopaque, std.mem.Allocator, ?u8) Error!ScanResult,
        delete_generation: *const fn (*anyopaque, Location) Error!bool,
    };

    pub fn cleanupStaged(self: MultipartDataStore) Error!usize {
        return self.vtable.cleanup_staged(self.context);
    }

    pub fn stage(self: MultipartDataStore, token: id.Uuid, source: byte_stream.Source) Error!Staged {
        return self.vtable.stage(self.context, token, source);
    }

    pub fn stageEncrypted(self: MultipartDataStore, token: id.Uuid, source: byte_stream.Source) Error!Staged {
        return (self.vtable.stage_encrypted orelse return error.Unavailable)(self.context, token, source);
    }

    pub fn publish(self: MultipartDataStore, staged: Staged, location: Location) Error!void {
        return self.vtable.publish(self.context, staged, location);
    }

    pub fn discard(self: MultipartDataStore, token: id.Uuid) void {
        self.vtable.discard(self.context, token);
    }

    pub fn stat(self: MultipartDataStore, location: Location) Error!u64 {
        return self.vtable.stat(self.context, location);
    }

    pub fn readRange(self: MultipartDataStore, location: Location, offset: u64, length: u64, sink: byte_stream.Sink) Error!void {
        return self.vtable.read_range(self.context, location, offset, length, sink);
    }

    pub fn deleteUpload(self: MultipartDataStore, upload_id: id.Uuid) Error!void {
        return self.vtable.delete_upload(self.context, upload_id);
    }

    pub fn scanGenerations(self: MultipartDataStore, allocator: std.mem.Allocator) Error!ScanResult {
        return self.vtable.scan_generations(self.context, allocator, null);
    }

    pub fn scanGenerationPartition(self: MultipartDataStore, allocator: std.mem.Allocator, partition: u8) Error!ScanResult {
        if (partition >= 16) return error.InvalidValue;
        return self.vtable.scan_generations(self.context, allocator, partition);
    }

    pub fn deleteGeneration(self: MultipartDataStore, location: Location) Error!bool {
        return self.vtable.delete_generation(self.context, location);
    }
};
