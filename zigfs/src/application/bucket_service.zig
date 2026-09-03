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
