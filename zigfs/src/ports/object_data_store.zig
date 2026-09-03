const id = @import("../common/id.zig");
const byte_stream = @import("byte_stream.zig");

pub const Location = struct {
    bucket_id: id.Uuid,
    object_id: id.Uuid,
    data_generation: id.Uuid,
};

pub const Staged = struct {
    token: id.Uuid,
    size: u64,
    etag_md5: [16]u8,
    checksum_sha256: [32]u8,
    checksum_crc64nvme: u64,
};

pub const Integrity = struct {
    size: u64,
    checksum_sha256: [32]u8,
};

pub const Generation = struct {
    location: Location,
    data_present: bool,
};

pub const ScanResult = struct {
    generations: []Generation,

    pub fn deinit(self: ScanResult, allocator: @import("std").mem.Allocator) void {
        allocator.free(self.generations);
    }
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

pub const ObjectDataStore = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        cleanup_staged: *const fn (context: *anyopaque) Error!usize,
        stage: *const fn (
            context: *anyopaque,
            token: id.Uuid,
            source: byte_stream.Source,
        ) Error!Staged,
        publish: *const fn (
            context: *anyopaque,
            staged: Staged,
            location: Location,
        ) Error!void,
        discard: *const fn (context: *anyopaque, token: id.Uuid) void,
        stat: *const fn (context: *anyopaque, location: Location) Error!u64,
        read: *const fn (
            context: *anyopaque,
            location: Location,
            integrity: Integrity,
            sink: byte_stream.Sink,
        ) Error!void,
        read_range: *const fn (
            context: *anyopaque,
            location: Location,
            offset: u64,
            length: u64,
            sink: byte_stream.Sink,
        ) Error!void,
        scan_generations: *const fn (
            context: *anyopaque,
            allocator: @import("std").mem.Allocator,
        ) Error!ScanResult,
        delete_generation: *const fn (
            context: *anyopaque,
            location: Location,
        ) Error!bool,
    };

    pub fn cleanupStaged(self: ObjectDataStore) Error!usize {
        return self.vtable.cleanup_staged(self.context);
    }

    pub fn stage(
        self: ObjectDataStore,
        token: id.Uuid,
        source: byte_stream.Source,
    ) Error!Staged {
        return self.vtable.stage(self.context, token, source);
    }

    pub fn publish(
        self: ObjectDataStore,
        staged: Staged,
        location: Location,
    ) Error!void {
        return self.vtable.publish(self.context, staged, location);
    }

    pub fn discard(self: ObjectDataStore, token: id.Uuid) void {
        self.vtable.discard(self.context, token);
    }

    pub fn stat(self: ObjectDataStore, location: Location) Error!u64 {
        return self.vtable.stat(self.context, location);
    }

    pub fn read(
        self: ObjectDataStore,
        location: Location,
        integrity: Integrity,
        sink: byte_stream.Sink,
    ) Error!void {
        return self.vtable.read(self.context, location, integrity, sink);
    }

    pub fn readRange(
        self: ObjectDataStore,
        location: Location,
        offset: u64,
        length: u64,
        sink: byte_stream.Sink,
    ) Error!void {
        return self.vtable.read_range(self.context, location, offset, length, sink);
    }

    pub fn scanGenerations(
        self: ObjectDataStore,
        allocator: @import("std").mem.Allocator,
    ) Error!ScanResult {
        return self.vtable.scan_generations(self.context, allocator);
    }

    pub fn deleteGeneration(
        self: ObjectDataStore,
        location: Location,
    ) Error!bool {
        return self.vtable.delete_generation(self.context, location);
    }
};
