const id = @import("../common/id.zig");
const byte_stream = @import("byte_stream.zig");
const secret_box = @import("../auth/secret_box.zig");
const object_domain = @import("../domain/object.zig");

/// Identifies a complete logical generation, independent of its physical layout.
/// A backend may map it to one file or to multiple durable blocks.
pub const Location = struct {
    bucket_id: id.Uuid,
    object_id: id.Uuid,
    data_generation: id.Uuid,
};

pub const ComposeEncryption = struct { key: secret_box.Key, associated_data: []const u8 };

pub const Staged = struct {
    data_layout: object_domain.DataLayout = .contiguous,
    token: id.Uuid,
    size: u64,
    etag_md5: [16]u8,
    checksum_crc32: u32,
    checksum_crc32c: u32,
    checksum_sha256: [32]u8,
    checksum_sha1: [20]u8,
    checksum_crc64nvme: u64,
    encryption_metadata: ?object_domain.EncryptionMetadata = null,
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
        stage_multipart: ?*const fn (*anyopaque, id.Uuid, object_domain.MultipartManifestView, ?ComposeEncryption) Error!?Staged = null,
        cleanup_staged: *const fn (context: *anyopaque) Error!usize,
        /// Consume the source through EOF and persist the complete logical data.
        /// Staged storage must be independent of temporary multipart uploads.
        stage: *const fn (
            context: *anyopaque,
            token: id.Uuid,
            source: byte_stream.Source,
        ) Error!Staged,
        stage_encrypted: *const fn (
            context: *anyopaque,
            token: id.Uuid,
            key: secret_box.Key,
            associated_data: []const u8,
            source: byte_stream.Source,
        ) Error!Staged,
        /// Durably associate all staged data (including block maps, if any)
        /// with this generation before the caller publishes object metadata.
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
        read_encrypted: *const fn (
            context: *anyopaque,
            location: Location,
            key: secret_box.Key,
            associated_data: []const u8,
            plaintext_size: u64,
            sink: byte_stream.Sink,
        ) Error!void,
        read_encrypted_range: *const fn (
            context: *anyopaque,
            location: Location,
            key: secret_box.Key,
            associated_data: []const u8,
            plaintext_size: u64,
            offset: u64,
            length: u64,
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
            partition: ?u8,
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

    /// Null indicates this backend/layout needs the streaming fallback.
    pub fn stageMultipart(self: ObjectDataStore, token: id.Uuid, manifest: object_domain.MultipartManifestView, encryption: ?ComposeEncryption) Error!?Staged {
        const compose = self.vtable.stage_multipart orelse return null;
        return compose(self.context, token, manifest, encryption);
    }

    pub fn stageEncrypted(
        self: ObjectDataStore,
        token: id.Uuid,
        key: secret_box.Key,
        associated_data: []const u8,
        source: byte_stream.Source,
    ) Error!Staged {
        return self.vtable.stage_encrypted(self.context, token, key, associated_data, source);
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

    pub fn readEncrypted(
        self: ObjectDataStore,
        location: Location,
        key: secret_box.Key,
        associated_data: []const u8,
        plaintext_size: u64,
        sink: byte_stream.Sink,
    ) Error!void {
        return self.vtable.read_encrypted(self.context, location, key, associated_data, plaintext_size, sink);
    }

    pub fn readEncryptedRange(self: ObjectDataStore, location: Location, key: secret_box.Key, associated_data: []const u8, plaintext_size: u64, offset: u64, length: u64, sink: byte_stream.Sink) Error!void {
        return self.vtable.read_encrypted_range(self.context, location, key, associated_data, plaintext_size, offset, length, sink);
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
        return self.vtable.scan_generations(self.context, allocator, null);
    }

    pub fn scanGenerationPartition(
        self: ObjectDataStore,
        allocator: @import("std").mem.Allocator,
        partition: u8,
    ) Error!ScanResult {
        if (partition >= 16) return error.InvalidValue;
        return self.vtable.scan_generations(self.context, allocator, partition);
    }

    pub fn deleteGeneration(
        self: ObjectDataStore,
        location: Location,
    ) Error!bool {
        return self.vtable.delete_generation(self.context, location);
    }
};
