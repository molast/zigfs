const std = @import("std");
const bucket_domain = @import("../domain/bucket.zig");
const index_module = @import("../metadata/index.zig");
const bucket_store_port = @import("../ports/bucket_store.zig");

pub const Error = error{
    OutOfMemory,
    InvalidBucketName,
    InvalidOwner,
    BucketNotFound,
    BucketAlreadyExists,
    BucketNotEmpty,
    Conflict,
    RetentionChangeRejected,
    ObjectLockingRequiresVersioning,
    ObjectLockingCannotDisable,
    CorruptMetadata,
    Unavailable,
};

pub const CreateResult = struct {
    bucket: bucket_domain.Bucket,
    created: bool,

    pub fn deinit(self: CreateResult, allocator: std.mem.Allocator) void {
        self.bucket.deinit(allocator);
    }
};

pub const ListResult = struct {
    buckets: []bucket_domain.Bucket,

    pub fn deinit(self: ListResult, allocator: std.mem.Allocator) void {
        for (self.buckets) |bucket| bucket.deinit(allocator);
        allocator.free(self.buckets);
    }
};

pub const BucketService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: bucket_store_port.BucketStore,
    index: *index_module.MetadataIndex,
    mutex: *std.Io.Mutex,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        store: bucket_store_port.BucketStore,
        index: *index_module.MetadataIndex,
        mutex: *std.Io.Mutex,
    ) BucketService {
        return .{
            .allocator = allocator,
            .io = io,
            .store = store,
            .index = index,
            .mutex = mutex,
        };
    }

    pub fn create(
        self: BucketService,
        name: []const u8,
        owner: []const u8,
    ) Error!CreateResult {
        bucket_domain.validateName(name) catch return error.InvalidBucketName;
        bucket_domain.validateOwner(owner) catch return error.InvalidOwner;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const current: ?bucket_store_port.Record = self.store.get(
            self.allocator,
            name,
        ) catch |err| switch (err) {
            error.NotFound => null,
            else => return mapStoreError(err),
        };

        var expected_generation: bucket_store_port.ExpectedGeneration = .missing;
        if (current) |record| {
            switch (record) {
                .active => |existing| {
                    if (self.index.bucketGeneration(name) != existing.generation) {
                        existing.deinit(self.allocator);
                        return error.CorruptMetadata;
                    }
                    if (std.mem.eql(u8, existing.owner, owner)) {
                        return .{ .bucket = existing, .created = false };
                    }
                    existing.deinit(self.allocator);
                    return error.BucketAlreadyExists;
                },
                .tombstone => |generation| {
                    if (self.index.containsBucket(name)) return error.CorruptMetadata;
                    expected_generation = .{ .exact = generation };
                },
            }
        } else if (self.index.containsBucket(name)) {
            return error.CorruptMetadata;
        }

        const bucket_id = @import("../common/id.zig").randomV4(self.io) catch {
            return error.Unavailable;
        };
        const created_at = std.Io.Clock.real.now(self.io).toSeconds();

        var prepared = self.index.prepareBucket(name) catch |err| return mapIndexError(err);
        defer prepared.deinit(self.index.allocator);
        var created_bucket = try ownedBucket(
            self.allocator,
            bucket_id,
            name,
            owner,
            .active,
            created_at,
            0,
        );
        errdefer created_bucket.deinit(self.allocator);

        const generation = self.store.put(
            self.allocator,
            .{
                .id = bucket_id,
                .name = name,
                .owner = owner,
                .status = .active,
                .created_at_unix_seconds = created_at,
            },
            expected_generation,
        ) catch |err| return mapStoreError(err);
        self.index.publishBucket(&prepared, generation);
        created_bucket.generation = generation;
        return .{ .bucket = created_bucket, .created = true };
    }

    pub fn head(self: BucketService, name: []const u8) Error!bucket_domain.Bucket {
        bucket_domain.validateName(name) catch return error.InvalidBucketName;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const indexed_generation = self.index.bucketGeneration(name) orelse {
            return error.BucketNotFound;
        };
        const record = self.store.get(self.allocator, name) catch |err| {
            return switch (err) {
                error.NotFound => error.CorruptMetadata,
                else => mapStoreError(err),
            };
        };
        return switch (record) {
            .active => |bucket| {
                if (bucket.generation != indexed_generation) {
                    bucket.deinit(self.allocator);
                    return error.CorruptMetadata;
                }
                return bucket;
            },
            .tombstone => error.CorruptMetadata,
        };
    }

    pub fn list(self: BucketService) Error!ListResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entries = self.index.bucketEntries();
        var buckets: std.ArrayList(bucket_domain.Bucket) = .empty;
        errdefer {
            for (buckets.items) |bucket| bucket.deinit(self.allocator);
            buckets.deinit(self.allocator);
        }
        buckets.ensureTotalCapacity(self.allocator, entries.len) catch {
            return error.OutOfMemory;
        };
        for (entries) |entry| {
            const record = self.store.get(self.allocator, entry.name) catch |err| {
                return switch (err) {
                    error.NotFound => error.CorruptMetadata,
                    else => mapStoreError(err),
                };
            };
            switch (record) {
                .active => |bucket| {
                    if (bucket.generation != entry.generation) {
                        bucket.deinit(self.allocator);
                        return error.CorruptMetadata;
                    }
                    buckets.appendAssumeCapacity(bucket);
                },
                .tombstone => return error.CorruptMetadata,
            }
        }
        return .{
            .buckets = buckets.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
        };
    }

    pub fn delete(self: BucketService, name: []const u8) Error!void {
        bucket_domain.validateName(name) catch return error.InvalidBucketName;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const indexed_generation = self.index.bucketGeneration(name) orelse {
            return error.BucketNotFound;
        };
        const record = self.store.get(self.allocator, name) catch |err| {
            return switch (err) {
                error.NotFound => error.CorruptMetadata,
                else => mapStoreError(err),
            };
        };
        const bucket = switch (record) {
            .active => |active| active,
            .tombstone => return error.CorruptMetadata,
        };
        defer bucket.deinit(self.allocator);
        if (bucket.generation != indexed_generation) return error.CorruptMetadata;
        if (self.index.hasObjectsInBucket(name)) return error.BucketNotEmpty;

        _ = self.store.tombstone(
            self.allocator,
            name,
            bucket.generation,
        ) catch |err| return mapStoreError(err);
        if (!self.index.removeBucket(name)) return error.CorruptMetadata;
    }

    pub fn setVersioning(
        self: BucketService,
        name: []const u8,
        versioning: bucket_domain.Versioning,
    ) Error!bucket_domain.Bucket {
        return self.updateConfiguration(name, versioning, null, .keep, null, false, null, null, null, null);
    }

    pub fn setAccessPolicy(
        self: BucketService,
        name: []const u8,
        access_policy: bucket_domain.AccessPolicy,
    ) Error!bucket_domain.Bucket {
        return self.updateConfiguration(name, null, access_policy, .keep, null, false, null, null, null, null);
    }

    pub fn setPublicAccess(self: BucketService, name: []const u8, block_public_access: bool) Error!bucket_domain.Bucket {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const generation = self.index.bucketGeneration(name) orelse return error.BucketNotFound;
        const record = self.store.get(self.allocator, name) catch |err| return mapStoreError(err);
        var bucket = switch (record) { .active => |active| active, .tombstone => return error.CorruptMetadata };
        errdefer bucket.deinit(self.allocator);
        if (bucket.generation != generation) return error.CorruptMetadata;
        var prepared = self.index.prepareBucket(name) catch |err| return mapIndexError(err);
        defer prepared.deinit(self.index.allocator);
        const next = self.store.put(self.allocator, .{ .id = bucket.id, .name = bucket.name, .owner = bucket.owner, .status = bucket.status, .versioning = bucket.versioning, .access_policy = bucket.access_policy, .object_ownership = bucket.object_ownership, .block_public_access = block_public_access, .lifecycle_configuration = bucket.lifecycle_configuration, .tags_json = bucket.tags_json, .encryption = bucket.encryption, .quota = bucket.quota, .retention = bucket.retention, .object_locking = bucket.object_locking, .created_at_unix_seconds = bucket.created_at_unix_seconds }, .{ .exact = bucket.generation }) catch |err| return mapStoreError(err);
        self.index.publishBucket(&prepared, next);
        bucket.block_public_access = block_public_access;
        bucket.generation = next;
        return bucket;
    }

    pub fn setTags(self: BucketService, name: []const u8, tags_json: ?[]const u8) Error!bucket_domain.Bucket {
        return self.updateConfiguration(name, null, null, .keep, tags_json, true, null, null, null, null);
    }

    pub fn setEncryption(self: BucketService, name: []const u8, encryption: bucket_domain.Encryption) Error!bucket_domain.Bucket {
        return self.updateConfiguration(name, null, null, .keep, null, false, encryption, null, null, null);
    }

    pub fn setQuota(self: BucketService, name: []const u8, quota: bucket_domain.Quota) Error!bucket_domain.Bucket {
        return self.updateConfiguration(name, null, null, .keep, null, false, null, quota, null, null);
    }

    pub fn setRetention(self: BucketService, name: []const u8, retention: bucket_domain.Retention) Error!bucket_domain.Bucket {
        return self.updateConfiguration(name, null, null, .keep, null, false, null, null, retention, null);
    }

    pub fn setObjectLocking(self: BucketService, name: []const u8, enabled: bool) Error!bucket_domain.Bucket {
        return self.updateConfiguration(name, null, null, .keep, null, false, null, null, null, enabled);
    }

    pub fn putLifecycle(
        self: BucketService,
        name: []const u8,
        configuration: []const u8,
    ) Error!bucket_domain.Bucket {
        return self.updateConfiguration(name, null, null, .{ .replace = configuration }, null, false, null, null, null, null);
    }

    pub fn deleteLifecycle(self: BucketService, name: []const u8) Error!bucket_domain.Bucket {
        return self.updateConfiguration(name, null, null, .remove, null, false, null, null, null, null);
    }

    const LifecycleUpdate = union(enum) {
        keep,
        remove,
        replace: []const u8,
    };

    fn updateConfiguration(
        self: BucketService,
        name: []const u8,
        versioning: ?bucket_domain.Versioning,
        access_policy: ?bucket_domain.AccessPolicy,
        lifecycle: LifecycleUpdate,
        tags_json: ?[]const u8,
        replace_tags: bool,
        encryption: ?bucket_domain.Encryption,
        quota: ?bucket_domain.Quota,
        retention: ?bucket_domain.Retention,
        object_locking: ?bool,
    ) Error!bucket_domain.Bucket {
        bucket_domain.validateName(name) catch return error.InvalidBucketName;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const indexed_generation = self.index.bucketGeneration(name) orelse return error.BucketNotFound;
        const record = self.store.get(self.allocator, name) catch |err| return mapStoreError(err);
        var bucket = switch (record) {
            .active => |active| active,
            .tombstone => return error.CorruptMetadata,
        };
        errdefer bucket.deinit(self.allocator);
        if (bucket.generation != indexed_generation) return error.CorruptMetadata;

        const lifecycle_value: ?[]const u8 = switch (lifecycle) {
            .keep => bucket.lifecycle_configuration,
            .remove => null,
            .replace => |value| value,
        };
        const owned_lifecycle = if (lifecycle == .keep)
            null
        else if (lifecycle_value) |value|
            self.allocator.dupe(u8, value) catch return error.OutOfMemory
        else
            null;
        errdefer if (owned_lifecycle) |value| self.allocator.free(value);
        const tags_value = if (replace_tags) tags_json else bucket.tags_json;
        const owned_tags = if (replace_tags) if (tags_value) |value| self.allocator.dupe(u8, value) catch return error.OutOfMemory else null else null;
        errdefer if (owned_tags) |value| self.allocator.free(value);
        const next_retention = retention orelse bucket.retention;
        const next_object_locking = object_locking orelse bucket.object_locking;
        if (next_object_locking and (versioning orelse bucket.versioning) != .enabled) return error.ObjectLockingRequiresVersioning;
        if (bucket.object_locking and !next_object_locking) return error.ObjectLockingCannotDisable;
        if (bucket.retention.enabled and bucket.retention.mode == .compliance) {
            const current_duration = bucket.retention.default_duration_seconds orelse 0;
            const next_duration = next_retention.default_duration_seconds orelse 0;
            if (!next_retention.enabled or next_retention.mode != .compliance or next_duration < current_duration) {
                return error.RetentionChangeRejected;
            }
        }
        var prepared = self.index.prepareBucket(name) catch |err| return mapIndexError(err);
        defer prepared.deinit(self.index.allocator);
        const generation = self.store.put(self.allocator, .{
            .id = bucket.id,
            .name = bucket.name,
            .owner = bucket.owner,
            .status = bucket.status,
            .versioning = versioning orelse bucket.versioning,
            .access_policy = access_policy orelse bucket.access_policy,
            .object_ownership = bucket.object_ownership,
            .block_public_access = bucket.block_public_access,
            .lifecycle_configuration = lifecycle_value,
            .tags_json = tags_value,
            .encryption = encryption orelse bucket.encryption,
            .quota = quota orelse bucket.quota,
            .retention = next_retention,
            .object_locking = next_object_locking,
            .created_at_unix_seconds = bucket.created_at_unix_seconds,
        }, .{ .exact = bucket.generation }) catch |err| return mapStoreError(err);
        self.index.publishBucket(&prepared, generation);

        bucket.versioning = versioning orelse bucket.versioning;
        bucket.access_policy = access_policy orelse bucket.access_policy;
        if (replace_tags) {
            if (bucket.tags_json) |existing| self.allocator.free(existing);
            bucket.tags_json = owned_tags;
        }
        bucket.encryption = encryption orelse bucket.encryption;
        bucket.quota = quota orelse bucket.quota;
        bucket.retention = next_retention;
        bucket.object_locking = next_object_locking;
        if (lifecycle != .keep) {
            if (bucket.lifecycle_configuration) |existing| self.allocator.free(existing);
            bucket.lifecycle_configuration = owned_lifecycle;
        }
        bucket.generation = generation;
        return bucket;
    }
};

fn ownedBucket(
    allocator: std.mem.Allocator,
    bucket_id: @import("../common/id.zig").Uuid,
    name: []const u8,
    owner: []const u8,
    status: bucket_domain.Status,
    created_at_unix_seconds: i64,
    generation: u64,
) Error!bucket_domain.Bucket {
    const owned_name = allocator.dupe(u8, name) catch return error.OutOfMemory;
    errdefer allocator.free(owned_name);
    const owned_owner = allocator.dupe(u8, owner) catch return error.OutOfMemory;
    return .{
        .id = bucket_id,
        .name = owned_name,
        .owner = owned_owner,
        .status = status,
        .created_at_unix_seconds = created_at_unix_seconds,
        .generation = generation,
    };
}

fn mapStoreError(err: bucket_store_port.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Conflict => error.Conflict,
        error.InvalidValue, error.CorruptMetadata => error.CorruptMetadata,
        error.NotFound => error.BucketNotFound,
        error.Unavailable,
        => error.Unavailable,
    };
}

fn mapIndexError(err: index_module.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CorruptRecord => error.CorruptMetadata,
        error.Unavailable => error.Unavailable,
    };
}

test "bucket service supports idempotent create head list delete and recreate" {
    const MemoryMetadataRepository = @import("../testing/memory_metadata_repository.zig").MemoryMetadataRepository;
    const MetadataBucketStore = @import("../metadata/bucket_store.zig").MetadataBucketStore;
    var memory = MemoryMetadataRepository.init(std.testing.allocator);
    defer memory.deinit();
    var bucket_store = MetadataBucketStore.init(memory.interface());
    var index = index_module.MetadataIndex.init(std.testing.allocator);
    defer index.deinit();
    try index.rebuild(memory.interface());
    var mutex: std.Io.Mutex = .init;
    const service = BucketService.init(
        std.testing.allocator,
        std.testing.io,
        bucket_store.interface(),
        &index,
        &mutex,
    );

    const created = try service.create("project-assets", "owner-a");
    defer created.deinit(std.testing.allocator);
    try std.testing.expect(created.created);
    try std.testing.expect(created.bucket.generation > 0);

    const repeated = try service.create("project-assets", "owner-a");
    defer repeated.deinit(std.testing.allocator);
    try std.testing.expect(!repeated.created);
    try std.testing.expectEqual(created.bucket.generation, repeated.bucket.generation);
    try std.testing.expectEqualSlices(u8, &created.bucket.id, &repeated.bucket.id);
    try std.testing.expectError(
        error.BucketAlreadyExists,
        service.create("project-assets", "owner-b"),
    );
    const archive = try service.create("archive-assets", "owner-b");
    defer archive.deinit(std.testing.allocator);

    const headed = try service.head("project-assets");
    defer headed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("owner-a", headed.owner);
    const listed = try service.list();
    defer listed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), listed.buckets.len);
    try std.testing.expectEqualStrings("archive-assets", listed.buckets[0].name);
    try std.testing.expectEqualStrings("project-assets", listed.buckets[1].name);

    try service.delete("project-assets");
    try std.testing.expectError(error.BucketNotFound, service.head("project-assets"));
    try std.testing.expectError(error.BucketNotFound, service.delete("project-assets"));
    const recreated = try service.create("project-assets", "owner-b");
    defer recreated.deinit(std.testing.allocator);
    try std.testing.expect(recreated.created);
    try std.testing.expect(recreated.bucket.generation > created.bucket.generation);
    try std.testing.expect(!std.mem.eql(u8, &created.bucket.id, &recreated.bucket.id));
}

test "bucket service rejects invalid names and non-empty delete" {
    const MemoryMetadataRepository = @import("../testing/memory_metadata_repository.zig").MemoryMetadataRepository;
    const MetadataBucketStore = @import("../metadata/bucket_store.zig").MetadataBucketStore;
    var memory = MemoryMetadataRepository.init(std.testing.allocator);
    defer memory.deinit();
    var bucket_store = MetadataBucketStore.init(memory.interface());
    var index = index_module.MetadataIndex.init(std.testing.allocator);
    defer index.deinit();
    try index.rebuild(memory.interface());
    var mutex: std.Io.Mutex = .init;
    const service = BucketService.init(
        std.testing.allocator,
        std.testing.io,
        bucket_store.interface(),
        &index,
        &mutex,
    );
    try std.testing.expectError(
        error.InvalidBucketName,
        service.create("Invalid_Name", "owner"),
    );
    try std.testing.expectError(
        error.InvalidOwner,
        service.create("valid-bucket", ""),
    );
    const created = try service.create("project-assets", "owner");
    defer created.deinit(std.testing.allocator);
    var prepared = try index.prepareObject("project-assets", "file.txt");
    defer prepared.deinit(index.allocator);
    index.publishObject(&prepared, created.bucket.generation + 1);
    try std.testing.expectError(error.BucketNotEmpty, service.delete("project-assets"));
}

test "bucket service requires versioning and prevents disabling object locking" {
    const MemoryMetadataRepository = @import("../testing/memory_metadata_repository.zig").MemoryMetadataRepository;
    const MetadataBucketStore = @import("../metadata/bucket_store.zig").MetadataBucketStore;
    var memory = MemoryMetadataRepository.init(std.testing.allocator);
    defer memory.deinit();
    var bucket_store = MetadataBucketStore.init(memory.interface());
    var index = index_module.MetadataIndex.init(std.testing.allocator);
    defer index.deinit();
    try index.rebuild(memory.interface());
    var mutex: std.Io.Mutex = .init;
    const service = BucketService.init(std.testing.allocator, std.testing.io, bucket_store.interface(), &index, &mutex);
    const created = try service.create("lock-assets", "owner");
    defer created.deinit(std.testing.allocator);

    try std.testing.expectError(error.ObjectLockingRequiresVersioning, service.setObjectLocking("lock-assets", true));
    const versioned = try service.setVersioning("lock-assets", .enabled);
    versioned.deinit(std.testing.allocator);
    const locked = try service.setObjectLocking("lock-assets", true);
    defer locked.deinit(std.testing.allocator);
    try std.testing.expect(locked.object_locking);
    try std.testing.expectError(error.ObjectLockingCannotDisable, service.setObjectLocking("lock-assets", false));
}
