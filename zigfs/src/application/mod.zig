const std = @import("std");
const builtin = @import("builtin");
const Config = @import("../config.zig").Config;
const LocalStorageBackend = @import("../backend/local.zig").LocalStorageBackend;
const CredentialMasterKey = @import("../backend/credential_master_key.zig").MasterKey;
const credential_master_key = @import("../backend/credential_master_key.zig");
const LocalObjectDataStore = @import("../backend/local_object_data.zig").LocalObjectDataStore;
const LocalTransactionJournal = @import("../metadata/local_journal.zig").LocalTransactionJournal;
const LocalRecoveryStore = @import("../metadata/local_recovery_store.zig").LocalRecoveryStore;
const LocalMetadataRepository = @import("../metadata/local_repository.zig").LocalMetadataRepository;
const MetadataBucketStore = @import("../metadata/bucket_store.zig").MetadataBucketStore;
const MetadataCredentialStore = @import("../metadata/credential_store.zig").MetadataCredentialStore;
const MetadataObjectStore = @import("../metadata/object_store.zig").MetadataObjectStore;
const index_module = @import("../metadata/index.zig");
const recovery = @import("../metadata/recovery.zig");
const local_layout = @import("../metadata/local_layout.zig");
const MetadataRepository = @import("../ports/metadata_repository.zig").MetadataRepository;

pub const bucket_service = @import("bucket_service.zig");
pub const continuation_token = @import("continuation_token.zig");
pub const credential_service = @import("credential_service.zig");
pub const object_gc = @import("object_gc.zig");
pub const object_lock_pool = @import("object_lock_pool.zig");
pub const object_listing = @import("object_listing.zig");
pub const object_service = @import("object_service.zig");

pub const Application = struct {
    allocator: std.mem.Allocator,
    config: Config,
    local_storage: LocalStorageBackend,
    data_root: ?std.Io.Dir = null,
    local_journal: ?LocalTransactionJournal = null,
    local_recovery_store: ?LocalRecoveryStore = null,
    local_repository: ?LocalMetadataRepository = null,
    bucket_store: ?MetadataBucketStore = null,
    credential_store: ?MetadataCredentialStore = null,
    object_store: ?MetadataObjectStore = null,
    master_key: ?CredentialMasterKey = null,
    local_object_data: ?LocalObjectDataStore = null,
    metadata_index: ?index_module.MetadataIndex = null,
    io: ?std.Io = null,
    state_mutex: std.Io.Mutex = .init,
    object_locks: object_lock_pool.ObjectLockPool = .{},
    recovery_state: recovery.State = .{},
    recovery_report: ?recovery.Report = null,

    pub fn init(config: Config) Application {
        return initWithAllocator(config, std.heap.smp_allocator);
    }

    pub fn initWithAllocator(
        config: Config,
        allocator: std.mem.Allocator,
    ) Application {
        return .{
            .allocator = allocator,
            .config = config,
            .local_storage = LocalStorageBackend.init(config.data_root),
        };
    }

    pub fn initialize(self: *Application, io: std.Io) !void {
        self.io = io;
        const storage = self.local_storage.interface();
        try storage.ensureReady(io);

        self.data_root = try std.Io.Dir.cwd().openDir(io, self.config.data_root, .{});
        self.local_journal = LocalTransactionJournal.init(self.data_root.?, io);
        self.local_recovery_store = LocalRecoveryStore.init(self.data_root.?, io);
        self.local_repository = LocalMetadataRepository.init(
            self.data_root.?,
            io,
            self.local_journal.?.interface(),
        );
        self.bucket_store = MetadataBucketStore.init(self.local_repository.?.interface());
        self.credential_store = MetadataCredentialStore.init(self.local_repository.?.interface());
        self.object_store = MetadataObjectStore.init(self.local_repository.?.interface());
        self.local_object_data = LocalObjectDataStore.init(
            self.allocator,
            self.data_root.?,
            io,
            self.config.stream_buffer_size,
        );

        self.recovery_state.begin();
        self.recovery_report = recovery.run(
            self.allocator,
            self.local_journal.?.interface(),
            self.local_recovery_store.?.interface(),
        ) catch |err| {
            self.recovery_state.markRequired(err);
            if (!builtin.is_test) {
                std.log.err("ZigFS metadata recovery requires operator action: {t}", .{err});
            }
            return;
        };
        _ = self.local_object_data.?.interface().cleanupStaged() catch |err| {
            self.recovery_state.markRequired(error.Unavailable);
            if (!builtin.is_test) {
                std.log.err("ZigFS staged object cleanup failed: {t}", .{err});
            }
            return;
        };
        self.master_key = credential_master_key.loadOrCreate(self.data_root.?, io) catch |err| {
            self.recovery_state.markRequired(switch (err) {
                error.InvalidLength,
                error.InvalidMagic,
                error.UnsupportedVersion,
                error.ChecksumMismatch,
                => error.CorruptRecord,
                else => error.Unavailable,
            });
            if (!builtin.is_test) {
                std.log.err("ZigFS credential master key is unavailable: {t}", .{err});
            }
            return;
        };

        var rebuilt_index = index_module.MetadataIndex.init(self.allocator);
        rebuilt_index.rebuild(self.local_repository.?.interface()) catch |err| {
            rebuilt_index.deinit();
            const recovery_error: recovery.Error = switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.CorruptRecord => error.CorruptRecord,
                error.Unavailable => error.Unavailable,
            };
            self.recovery_state.markRequired(recovery_error);
            if (!builtin.is_test) {
                std.log.err("ZigFS metadata index rebuild failed: {t}", .{err});
            }
            return;
        };
        self.metadata_index = rebuilt_index;
        self.recovery_state.markReady();
    }

    pub fn deinit(self: *Application, io: std.Io) void {
        if (self.metadata_index) |*metadata_index| {
            metadata_index.deinit();
            self.metadata_index = null;
        }
        self.bucket_store = null;
        self.credential_store = null;
        self.object_store = null;
        self.local_object_data = null;
        self.local_repository = null;
        self.local_recovery_store = null;
        self.local_journal = null;
        if (self.master_key) |*master_key| {
            master_key.deinit();
            self.master_key = null;
        }
        self.io = null;
        if (self.data_root) |root| {
            root.close(io);
            self.data_root = null;
        }
        self.local_storage.deinit(io);
    }

    pub fn metadataRepository(self: *Application) ?MetadataRepository {
        if (self.local_repository) |*repository| return repository.interface();
        return null;
    }

    pub fn metadataIndex(self: *Application) ?*index_module.MetadataIndex {
        if (self.metadata_index) |*metadata_index| return metadata_index;
        return null;
    }

    pub fn bucketService(self: *Application) ?bucket_service.BucketService {
        if (!self.recovery_state.isReady()) return null;
        const io = self.io orelse return null;
        const store = if (self.bucket_store) |*bucket_store|
            bucket_store.interface()
        else
            return null;
        const index = if (self.metadata_index) |*metadata_index|
            metadata_index
        else
            return null;
        return bucket_service.BucketService.init(
            self.allocator,
            io,
            store,
            index,
            &self.state_mutex,
        );
    }

    pub fn objectService(self: *Application) ?object_service.ObjectService {
        if (!self.recovery_state.isReady()) return null;
        const io = self.io orelse return null;
        const bucket_store = if (self.bucket_store) |*store|
            store.interface()
        else
            return null;
        const object_store = if (self.object_store) |*store|
            store.interface()
        else
            return null;
        const data_store = if (self.local_object_data) |*store|
            store.interface()
        else
            return null;
        const index = if (self.metadata_index) |*metadata_index|
            metadata_index
        else
            return null;
        return object_service.ObjectService.init(
            self.allocator,
            io,
            bucket_store,
            object_store,
            data_store,
            index,
            &self.state_mutex,
            &self.object_locks,
        );
    }

    pub fn credentialService(self: *Application) ?credential_service.CredentialService {
        if (!self.recovery_state.isReady()) return null;
        const io = self.io orelse return null;
        const store = if (self.credential_store) |*credential_store|
            credential_store.interface()
        else
            return null;
        const index = if (self.metadata_index) |*metadata_index|
            metadata_index
        else
            return null;
        const master_key = if (self.master_key) |*master_key|
            &master_key.bytes
        else
            return null;
        return credential_service.CredentialService.init(
            self.allocator,
            io,
            store,
            index,
            &self.state_mutex,
            master_key,
        );
    }

    pub fn objectListing(self: *Application) ?object_listing.ObjectListingService {
        if (!self.recovery_state.isReady()) return null;
        const io = self.io orelse return null;
        const bucket_store = if (self.bucket_store) |*store|
            store.interface()
        else
            return null;
        const object_store = if (self.object_store) |*store|
            store.interface()
        else
            return null;
        const index = if (self.metadata_index) |*metadata_index|
            metadata_index
        else
            return null;
        return object_listing.ObjectListingService.init(
            self.allocator,
            io,
            bucket_store,
            object_store,
            index,
            &self.state_mutex,
        );
    }

    pub fn objectGc(self: *Application) ?object_gc.ObjectGcService {
        if (!self.recovery_state.isReady()) return null;
        const io = self.io orelse return null;
        const object_store = if (self.object_store) |*store|
            store.interface()
        else
            return null;
        const data_store = if (self.local_object_data) |*store|
            store.interface()
        else
            return null;
        const index = if (self.metadata_index) |*metadata_index|
            metadata_index
        else
            return null;
        return object_gc.ObjectGcService.init(
            self.allocator,
            io,
            object_store,
            data_store,
            index,
            &self.state_mutex,
            &self.object_locks,
        );
    }

    pub fn recoveryState(self: *const Application) *const recovery.State {
        return &self.recovery_state;
    }
};

fn testDataRootPath(
    allocator: std.mem.Allocator,
    tmp: *const std.testing.TmpDir,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/data",
        .{tmp.sub_path},
    );
}

test "application becomes ready only after recovery and index rebuild" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(data_root);

    var app = Application.initWithAllocator(
        .{ .data_root = data_root, .metrics_enabled = false },
        std.testing.allocator,
    );
    defer app.deinit(std.testing.io);
    try app.initialize(std.testing.io);
    try std.testing.expect(app.recoveryState().isReady());
    try std.testing.expect(app.metadataIndex() != null);
    try std.testing.expect(app.bucketService() != null);
    try std.testing.expect(app.credentialService() != null);
    try std.testing.expect(app.objectService() != null);
    try std.testing.expect(app.objectListing() != null);
    try std.testing.expect(app.objectGc() != null);
    try std.testing.expect(app.recovery_report != null);
}

test "application stays alive but not ready when journal is corrupt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "data/.zigfs/journal");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "data/.zigfs/journal/corrupt.journal",
        .data = "corrupt",
    });
    const data_root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(data_root);

    var app = Application.initWithAllocator(
        .{ .data_root = data_root, .metrics_enabled = false },
        std.testing.allocator,
    );
    defer app.deinit(std.testing.io);
    try app.initialize(std.testing.io);
    try std.testing.expectEqual(recovery.Status.recovery_required, app.recoveryState().status);
    try std.testing.expectEqual(recovery.Failure.corrupt_journal, app.recoveryState().failure);
    try std.testing.expect(app.metadataIndex() == null);
    try std.testing.expect(app.bucketService() == null);
    try std.testing.expect(app.objectService() == null);
    try std.testing.expect(app.objectListing() == null);
    try std.testing.expect(app.objectGc() == null);
}

test "application stays alive but not ready when a committed record is corrupt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(data_root);
    const config: Config = .{ .data_root = data_root, .metrics_enabled = false };

    var writer = Application.initWithAllocator(config, std.testing.allocator);
    errdefer writer.deinit(std.testing.io);
    try writer.initialize(std.testing.io);
    _ = try writer.metadataRepository().?.put(
        std.testing.allocator,
        .object,
        "bucket/corrupt.txt",
        .missing,
        "object",
    );
    writer.deinit(std.testing.io);

    const key_hash = local_layout.hashKey("bucket/corrupt.txt");
    var record_path_buffer: [local_layout.max_path_length]u8 = undefined;
    const record_path = try local_layout.recordPath(.object, key_hash, &record_path_buffer);
    var test_path_buffer: [local_layout.max_path_length + 8]u8 = undefined;
    const test_path = try std.fmt.bufPrint(&test_path_buffer, "data/{s}", .{record_path});
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = test_path,
        .data = "corrupt",
    });

    var reader = Application.initWithAllocator(config, std.testing.allocator);
    defer reader.deinit(std.testing.io);
    try reader.initialize(std.testing.io);
    try std.testing.expectEqual(recovery.Status.recovery_required, reader.recoveryState().status);
    try std.testing.expectEqual(recovery.Failure.corrupt_record, reader.recoveryState().failure);
    try std.testing.expect(reader.metadataIndex() == null);
    try std.testing.expect(reader.bucketService() == null);
    try std.testing.expect(reader.objectService() == null);
    try std.testing.expect(reader.objectListing() == null);
    try std.testing.expect(reader.objectGc() == null);
}

test "bucket service persists create and delete across application restarts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(data_root);
    const config: Config = .{ .data_root = data_root, .metrics_enabled = false };

    var writer = Application.initWithAllocator(config, std.testing.allocator);
    errdefer writer.deinit(std.testing.io);
    try writer.initialize(std.testing.io);
    const created = try writer.bucketService().?.create("project-assets", "owner-a");
    const created_id = created.bucket.id;
    const created_generation = created.bucket.generation;
    created.deinit(std.testing.allocator);
    writer.deinit(std.testing.io);

    var reader = Application.initWithAllocator(config, std.testing.allocator);
    errdefer reader.deinit(std.testing.io);
    try reader.initialize(std.testing.io);
    const headed = try reader.bucketService().?.head("project-assets");
    defer headed.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &created_id, &headed.id);
    try std.testing.expectEqual(created_generation, headed.generation);
    try std.testing.expectEqualStrings("owner-a", headed.owner);
    const listed = try reader.bucketService().?.list();
    defer listed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), listed.buckets.len);
    try reader.bucketService().?.delete("project-assets");
    reader.deinit(std.testing.io);

    var after_delete = Application.initWithAllocator(config, std.testing.allocator);
    defer after_delete.deinit(std.testing.io);
    try after_delete.initialize(std.testing.io);
    try std.testing.expectError(
        error.BucketNotFound,
        after_delete.bucketService().?.head("project-assets"),
    );
    const empty = try after_delete.bucketService().?.list();
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.buckets.len);
}

test "credential secret stays encrypted and authentication state survives restarts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(data_root);
    const config: Config = .{ .data_root = data_root, .metrics_enabled = false };
    var access_key: [20]u8 = undefined;
    var secret_key: [40]u8 = undefined;
    defer std.crypto.secureZero(u8, &secret_key);

    {
        var writer = Application.initWithAllocator(config, std.testing.allocator);
        defer writer.deinit(std.testing.io);
        try writer.initialize(std.testing.io);
        var created = try writer.credentialService().?.create("tenant-a", .all);
        defer created.deinit(std.testing.allocator);
        @memcpy(&access_key, created.credential.access_key);
        @memcpy(&secret_key, &created.secret_key);
    }

    const key_hash = local_layout.hashKey(&access_key);
    var record_path_buffer: [local_layout.max_path_length]u8 = undefined;
    const record_path = try local_layout.recordPath(.credential, key_hash, &record_path_buffer);
    var test_path_buffer: [local_layout.max_path_length + 8]u8 = undefined;
    const test_path = try std.fmt.bufPrint(&test_path_buffer, "data/{s}", .{record_path});
    var record_buffer: [4096]u8 = undefined;
    const record_bytes = try tmp.dir.readFile(std.testing.io, test_path, &record_buffer);
    try std.testing.expect(std.mem.indexOf(u8, record_bytes, &secret_key) == null);

    var master_key_buffer: [credential_master_key.encoded_length + 1]u8 = undefined;
    const master_key_bytes = try tmp.dir.readFile(
        std.testing.io,
        "data/" ++ credential_master_key.path,
        &master_key_buffer,
    );
    try std.testing.expect(std.mem.indexOf(u8, master_key_bytes, &secret_key) == null);

    {
        var reader = Application.initWithAllocator(config, std.testing.allocator);
        defer reader.deinit(std.testing.io);
        try reader.initialize(std.testing.io);
        var auth_material = try reader.credentialService().?.resolveForAuth(&access_key);
        defer auth_material.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(&secret_key, auth_material.secret_key);
        const disabled = try reader.credentialService().?.update(&access_key, .{ .enabled = false });
        disabled.deinit(std.testing.allocator);
    }

    var after_disable = Application.initWithAllocator(config, std.testing.allocator);
    defer after_disable.deinit(std.testing.io);
    try after_disable.initialize(std.testing.io);
    try std.testing.expectError(
        error.CredentialDisabled,
        after_disable.credentialService().?.resolveForAuth(&access_key),
    );
}

test "invalid bucket payload keeps a restarted application not ready" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(data_root);
    const config: Config = .{ .data_root = data_root, .metrics_enabled = false };

    var writer = Application.initWithAllocator(config, std.testing.allocator);
    errdefer writer.deinit(std.testing.io);
    try writer.initialize(std.testing.io);
    _ = try writer.metadataRepository().?.put(
        std.testing.allocator,
        .bucket,
        "invalid-payload",
        .missing,
        "not-a-bucket-payload",
    );
    writer.deinit(std.testing.io);

    var reader = Application.initWithAllocator(config, std.testing.allocator);
    defer reader.deinit(std.testing.io);
    try reader.initialize(std.testing.io);
    try std.testing.expectEqual(recovery.Status.recovery_required, reader.recoveryState().status);
    try std.testing.expectEqual(recovery.Failure.corrupt_record, reader.recoveryState().failure);
    try std.testing.expect(reader.metadataIndex() == null);
    try std.testing.expect(reader.bucketService() == null);
    try std.testing.expect(reader.objectService() == null);
    try std.testing.expect(reader.objectListing() == null);
    try std.testing.expect(reader.objectGc() == null);
}

test "object service streams persists overwrites and tombstones across restarts" {
    const test_streams = @import("../testing/streams.zig");
    const object_data_port = @import("../ports/object_data_store.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(data_root);
    const config: Config = .{
        .data_root = data_root,
        .metrics_enabled = false,
        .stream_buffer_size = 16 * 1024,
    };
    const object_size: u64 = 1024 * 1024;
    var first_id: @import("../common/id.zig").Uuid = undefined;
    var first_data_generation: @import("../common/id.zig").Uuid = undefined;
    var first_metadata_generation: u64 = 0;

    {
        var writer = Application.initWithAllocator(config, std.testing.allocator);
        defer writer.deinit(std.testing.io);
        try writer.initialize(std.testing.io);
        const bucket = try writer.bucketService().?.create("project-assets", "owner-a");
        defer bucket.deinit(std.testing.allocator);
        var source = test_streams.RepeatingSource.init(object_size, 0x5a);
        const object = try writer.objectService().?.put(
            "project-assets",
            "../../archive/large.bin",
            source.interface(),
            .{
                .content_type = "application/octet-stream",
                .user_metadata = &.{.{ .name = "source", .value = "integration-test" }},
            },
        );
        defer object.deinit(std.testing.allocator);
        first_id = object.id;
        first_data_generation = object.data_generation;
        first_metadata_generation = object.metadata_generation;
        try std.testing.expectEqual(object_size, object.size);
    }

    {
        var reader = Application.initWithAllocator(config, std.testing.allocator);
        defer reader.deinit(std.testing.io);
        try reader.initialize(std.testing.io);
        var sink: test_streams.CountingSink = .{};
        const restored = try reader.objectService().?.get(
            "project-assets",
            "../../archive/large.bin",
            sink.interface(),
        );
        defer restored.deinit(std.testing.allocator);
        try std.testing.expectEqual(object_size, sink.size);
        try std.testing.expectEqualSlices(u8, &first_id, &restored.id);
        try std.testing.expectEqual(first_metadata_generation, restored.metadata_generation);

        var replacement_source = test_streams.SliceSource.init("replacement-body");
        const replacement = try reader.objectService().?.put(
            "project-assets",
            "../../archive/large.bin",
            replacement_source.interface(),
            .{ .content_type = "text/plain" },
        );
        defer replacement.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, &first_id, &replacement.id);
        try std.testing.expect(replacement.metadata_generation > first_metadata_generation);
        try std.testing.expect(!std.mem.eql(
            u8,
            &first_data_generation,
            &replacement.data_generation,
        ));
        const old_size = try reader.local_object_data.?.interface().stat(
            object_data_port.Location{
                .bucket_id = restored.bucket_id,
                .object_id = first_id,
                .data_generation = first_data_generation,
            },
        );
        try std.testing.expectEqual(object_size, old_size);
        try std.testing.expect((try reader.objectService().?.delete(
            "project-assets",
            "../../archive/large.bin",
        )).deleted);
        try std.testing.expect(!(try reader.objectService().?.delete(
            "project-assets",
            "../../archive/large.bin",
        )).deleted);
    }

    {
        var after_delete = Application.initWithAllocator(config, std.testing.allocator);
        defer after_delete.deinit(std.testing.io);
        try after_delete.initialize(std.testing.io);
        try std.testing.expectError(
            error.ObjectNotFound,
            after_delete.objectService().?.head(
                "project-assets",
                "../../archive/large.bin",
            ),
        );
        try after_delete.bucketService().?.delete("project-assets");
    }
}

test "application restart removes only staged object data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(data_root);
    const config: Config = .{ .data_root = data_root, .metrics_enabled = false };

    {
        var writer = Application.initWithAllocator(config, std.testing.allocator);
        defer writer.deinit(std.testing.io);
        try writer.initialize(std.testing.io);
    }
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "data/.zigfs/tmp/object-stale.data",
        .data = "partial-object",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "data/.zigfs/tmp/metadata.keep",
        .data = "keep",
    });

    var reader = Application.initWithAllocator(config, std.testing.allocator);
    defer reader.deinit(std.testing.io);
    try reader.initialize(std.testing.io);
    try std.testing.expect(reader.recoveryState().isReady());
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, "data/.zigfs/tmp/object-stale.data", .{}),
    );
    _ = try tmp.dir.statFile(std.testing.io, "data/.zigfs/tmp/metadata.keep", .{});
}

test "object listing paginates metadata with a restart-stable bound token" {
    const test_streams = @import("../testing/streams.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(data_root);
    const config: Config = .{ .data_root = data_root, .metrics_enabled = false };
    var continuation: []u8 = undefined;

    {
        var writer = Application.initWithAllocator(config, std.testing.allocator);
        defer writer.deinit(std.testing.io);
        try writer.initialize(std.testing.io);
        const bucket = try writer.bucketService().?.create("project-assets", "owner-a");
        defer bucket.deinit(std.testing.allocator);
        const fixtures = [_]struct { key: []const u8, body: []const u8 }{
            .{ .key = "a.txt", .body = "a" },
            .{ .key = "dir/a.jpg", .body = "aa" },
            .{ .key = "dir/b.jpg", .body = "bbb" },
            .{ .key = "dir2/x.jpg", .body = "xxxx" },
            .{ .key = "z.txt", .body = "zzzzz" },
        };
        for (fixtures) |fixture| {
            var source = test_streams.SliceSource.init(fixture.body);
            const object = try writer.objectService().?.put(
                "project-assets",
                fixture.key,
                source.interface(),
                .{},
            );
            object.deinit(std.testing.allocator);
        }

        const first = try writer.objectListing().?.list("project-assets", .{
            .delimiter = "/",
            .max_keys = 2,
        });
        defer first.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), first.key_count);
        try std.testing.expectEqual(@as(usize, 1), first.objects.len);
        try std.testing.expectEqualStrings("a.txt", first.objects[0].key);
        try std.testing.expectEqual(@as(u64, 1), first.objects[0].size);
        try std.testing.expect(first.objects[0].last_modified_unix_seconds > 0);
        try std.testing.expectEqual(@as(usize, 1), first.common_prefixes.len);
        try std.testing.expectEqualStrings("dir/", first.common_prefixes[0]);
        try std.testing.expect(first.is_truncated);
        continuation = try std.testing.allocator.dupe(
            u8,
            first.next_continuation_token.?,
        );

        try std.testing.expectError(
            error.InvalidContinuationToken,
            writer.objectListing().?.list("project-assets", .{
                .prefix = "different/",
                .delimiter = "/",
                .continuation_token = continuation,
            }),
        );
        try std.testing.expectError(
            error.InvalidListOptions,
            writer.objectListing().?.list("project-assets", .{ .max_keys = 1001 }),
        );
        try std.testing.expectError(
            error.BucketNotFound,
            writer.objectListing().?.list("missing-bucket", .{}),
        );
    }
    defer std.testing.allocator.free(continuation);

    var reader = Application.initWithAllocator(config, std.testing.allocator);
    defer reader.deinit(std.testing.io);
    try reader.initialize(std.testing.io);
    const second = try reader.objectListing().?.list("project-assets", .{
        .delimiter = "/",
        .start_after = "zzzz",
        .continuation_token = continuation,
        .max_keys = 2,
    });
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), second.key_count);
    try std.testing.expectEqual(@as(usize, 1), second.objects.len);
    try std.testing.expectEqualStrings("z.txt", second.objects[0].key);
    try std.testing.expectEqual(@as(u64, 5), second.objects[0].size);
    try std.testing.expectEqual(@as(usize, 1), second.common_prefixes.len);
    try std.testing.expectEqualStrings("dir2/", second.common_prefixes[0]);
    try std.testing.expect(!second.is_truncated);
    try std.testing.expect(second.next_continuation_token == null);
}

test "object gc retains current data and reclaims old deleted and orphan generations" {
    const id = @import("../common/id.zig");
    const object_data_port = @import("../ports/object_data_store.zig");
    const test_streams = @import("../testing/streams.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(data_root);
    const config: Config = .{ .data_root = data_root, .metrics_enabled = false };
    var current_location: object_data_port.Location = undefined;

    {
        var app = Application.initWithAllocator(config, std.testing.allocator);
        defer app.deinit(std.testing.io);
        try app.initialize(std.testing.io);
        const bucket_result = try app.bucketService().?.create("project-assets", "owner-a");
        defer bucket_result.deinit(std.testing.allocator);

        var first_source = test_streams.SliceSource.init("old-body");
        const first = try app.objectService().?.put(
            "project-assets",
            "live.txt",
            first_source.interface(),
            .{},
        );
        defer first.deinit(std.testing.allocator);
        const old_location: object_data_port.Location = .{
            .bucket_id = first.bucket_id,
            .object_id = first.id,
            .data_generation = first.data_generation,
        };
        var second_source = test_streams.SliceSource.init("current-body");
        const current = try app.objectService().?.put(
            "project-assets",
            "live.txt",
            second_source.interface(),
            .{},
        );
        defer current.deinit(std.testing.allocator);
        current_location = .{
            .bucket_id = current.bucket_id,
            .object_id = current.id,
            .data_generation = current.data_generation,
        };

        var deleted_source = test_streams.SliceSource.init("deleted-body");
        const deleted = try app.objectService().?.put(
            "project-assets",
            "deleted.txt",
            deleted_source.interface(),
            .{},
        );
        defer deleted.deinit(std.testing.allocator);
        const deleted_location: object_data_port.Location = .{
            .bucket_id = deleted.bucket_id,
            .object_id = deleted.id,
            .data_generation = deleted.data_generation,
        };
        try std.testing.expect((try app.objectService().?.delete(
            "project-assets",
            "deleted.txt",
        )).deleted);

        const orphan_location: object_data_port.Location = .{
            .bucket_id = current.bucket_id,
            .object_id = try id.randomV4(std.testing.io),
            .data_generation = try id.randomV4(std.testing.io),
        };
        var orphan_source = test_streams.SliceSource.init("orphan-body");
        const staged = try app.local_object_data.?.interface().stage(
            orphan_location.data_generation,
            orphan_source.interface(),
        );
        try app.local_object_data.?.interface().publish(staged, orphan_location);

        const report = try app.objectGc().?.collect();
        try std.testing.expectEqual(@as(usize, 4), report.scanned_generations);
        try std.testing.expectEqual(@as(usize, 1), report.retained_generations);
        try std.testing.expectEqual(@as(usize, 3), report.removed_generations);
        try std.testing.expectEqual(@as(u64, "current-body".len), try app.local_object_data.?.interface().stat(current_location));
        try std.testing.expectError(error.NotFound, app.local_object_data.?.interface().stat(old_location));
        try std.testing.expectError(error.NotFound, app.local_object_data.?.interface().stat(deleted_location));
        try std.testing.expectError(error.NotFound, app.local_object_data.?.interface().stat(orphan_location));

        const second_report = try app.objectGc().?.collect();
        try std.testing.expectEqual(@as(usize, 1), second_report.scanned_generations);
        try std.testing.expectEqual(@as(usize, 1), second_report.retained_generations);
        try std.testing.expectEqual(@as(usize, 0), second_report.removed_generations);
    }

    var restarted = Application.initWithAllocator(config, std.testing.allocator);
    defer restarted.deinit(std.testing.io);
    try restarted.initialize(std.testing.io);
    var sink = test_streams.CollectingSink.init(std.testing.allocator);
    defer sink.deinit();
    const restored = try restarted.objectService().?.get(
        "project-assets",
        "live.txt",
        sink.interface(),
    );
    defer restored.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("current-body", sink.bytes.items);
    try std.testing.expectError(
        error.ObjectNotFound,
        restarted.objectService().?.head("project-assets", "deleted.txt"),
    );
    try std.testing.expectEqual(@as(u64, "current-body".len), try restarted.local_object_data.?.interface().stat(current_location));
}

test "object gc reports referenced data loss" {
    const object_data_port = @import("../ports/object_data_store.zig");
    const test_streams = @import("../testing/streams.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(data_root);
    const config: Config = .{ .data_root = data_root, .metrics_enabled = false };
    var app = Application.initWithAllocator(config, std.testing.allocator);
    defer app.deinit(std.testing.io);
    try app.initialize(std.testing.io);
    const bucket = try app.bucketService().?.create("project-assets", "owner-a");
    defer bucket.deinit(std.testing.allocator);
    var source = test_streams.SliceSource.init("body");
    const object = try app.objectService().?.put(
        "project-assets",
        "lost.txt",
        source.interface(),
        .{},
    );
    defer object.deinit(std.testing.allocator);
    const location: object_data_port.Location = .{
        .bucket_id = object.bucket_id,
        .object_id = object.id,
        .data_generation = object.data_generation,
    };
    try std.testing.expect(try app.local_object_data.?.interface().deleteGeneration(location));
    try std.testing.expectError(error.CorruptData, app.objectGc().?.collect());
}

test "invalid object payload keeps a restarted application not ready" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(data_root);
    const config: Config = .{ .data_root = data_root, .metrics_enabled = false };

    {
        var writer = Application.initWithAllocator(config, std.testing.allocator);
        defer writer.deinit(std.testing.io);
        try writer.initialize(std.testing.io);
        const bucket = try writer.bucketService().?.create("project-assets", "owner-a");
        defer bucket.deinit(std.testing.allocator);
        _ = try writer.metadataRepository().?.put(
            std.testing.allocator,
            .object,
            "project-assets/corrupt.txt",
            .missing,
            "not-an-object-payload",
        );
    }

    var reader = Application.initWithAllocator(config, std.testing.allocator);
    defer reader.deinit(std.testing.io);
    try reader.initialize(std.testing.io);
    try std.testing.expectEqual(recovery.Status.recovery_required, reader.recoveryState().status);
    try std.testing.expectEqual(recovery.Failure.corrupt_record, reader.recoveryState().failure);
    try std.testing.expect(reader.metadataIndex() == null);
    try std.testing.expect(reader.bucketService() == null);
    try std.testing.expect(reader.objectService() == null);
    try std.testing.expect(reader.objectListing() == null);
    try std.testing.expect(reader.objectGc() == null);
}

test {
    std.testing.refAllDecls(@This());
}
