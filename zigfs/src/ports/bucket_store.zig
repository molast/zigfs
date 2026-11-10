const std = @import("std");
const bucket_domain = @import("../domain/bucket.zig");
const id = @import("../common/id.zig");

pub const Error = error{
    OutOfMemory,
    NotFound,
    Conflict,
    InvalidValue,
    CorruptMetadata,
    Unavailable,
};

pub const ExpectedGeneration = union(enum) {
    missing,
    exact: u64,
};

pub const Value = struct {
    id: id.Uuid,
    name: []const u8,
    owner: []const u8,
    status: bucket_domain.Status,
    versioning: bucket_domain.Versioning = .unversioned,
    access_policy: bucket_domain.AccessPolicy = .private,
    object_ownership: bucket_domain.ObjectOwnership = .bucket_owner_enforced,
    block_public_access: bool = false,
    tags_json: ?[]const u8 = null,
    kms_key_id: bucket_domain.KmsKeyId = .{},
    encryption: bucket_domain.Encryption = .disabled,
    quota: bucket_domain.Quota = .{},
    retention: bucket_domain.Retention = .{},
    object_locking: bool = false,
    lifecycle_configuration: ?[]const u8 = null,
    created_at_unix_seconds: i64,
};

pub const Record = union(enum) {
    active: bucket_domain.Bucket,
    tombstone: u64,

    pub fn deinit(self: Record, allocator: std.mem.Allocator) void {
        switch (self) {
            .active => |bucket| bucket.deinit(allocator),
            .tombstone => {},
        }
    }
};

pub const BucketStore = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            name: []const u8,
        ) Error!Record,
        put: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            value: Value,
            expected_generation: ExpectedGeneration,
        ) Error!u64,
        tombstone: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            name: []const u8,
            expected_generation: u64,
        ) Error!u64,
    };

    pub fn get(
        self: BucketStore,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) Error!Record {
        return self.vtable.get(self.context, allocator, name);
    }

    pub fn put(
        self: BucketStore,
        allocator: std.mem.Allocator,
        value: Value,
        expected_generation: ExpectedGeneration,
    ) Error!u64 {
        return self.vtable.put(
            self.context,
            allocator,
            value,
            expected_generation,
        );
    }

    pub fn tombstone(
        self: BucketStore,
        allocator: std.mem.Allocator,
        name: []const u8,
        expected_generation: u64,
    ) Error!u64 {
        return self.vtable.tombstone(
            self.context,
            allocator,
            name,
            expected_generation,
        );
    }
};
