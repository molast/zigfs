const std = @import("std");
const builtin = @import("builtin");
const Config = @import("../config.zig").Config;
const fault_injection = @import("../common/fault_injection.zig");
const LocalStorageBackend = @import("../backend/local.zig").LocalStorageBackend;
const CredentialMasterKey = @import("../backend/credential_master_key.zig").MasterKey;
const credential_master_key = @import("../backend/credential_master_key.zig");
const LocalObjectDataStore = @import("../backend/local_object_data.zig").LocalObjectDataStore;
const LocalMultipartDataStore = @import("../backend/local_multipart_data.zig").LocalMultipartDataStore;
const LocalTransactionJournal = @import("../metadata/local_journal.zig").LocalTransactionJournal;
const LocalRecoveryStore = @import("../metadata/local_recovery_store.zig").LocalRecoveryStore;
const LocalMetadataRepository = @import("../metadata/local_repository.zig").LocalMetadataRepository;
const MetadataBucketStore = @import("../metadata/bucket_store.zig").MetadataBucketStore;
const MetadataCredentialStore = @import("../metadata/credential_store.zig").MetadataCredentialStore;
const MetadataObjectStore = @import("../metadata/object_store.zig").MetadataObjectStore;
const MetadataMultipartStore = @import("../metadata/multipart_store.zig").MetadataMultipartStore;
const index_module = @import("../metadata/index.zig");
const recovery = @import("../metadata/recovery.zig");
const local_layout = @import("../metadata/local_layout.zig");
const multipart_domain = @import("../domain/multipart.zig");
const MetadataRepository = @import("../ports/metadata_repository.zig").MetadataRepository;

pub const bucket_service = @import("bucket_service.zig");
pub const continuation_token = @import("continuation_token.zig");
pub const credential_service = @import("credential_service.zig");
pub const object_gc = @import("object_gc.zig");
pub const object_lock_pool = @import("object_lock_pool.zig");
pub const object_listing = @import("object_listing.zig");
pub const multipart_service = @import("multipart_service.zig");
pub const management_service = @import("management_service.zig");
pub const object_service = @import("object_service.zig");
pub const lifecycle_service = @import("lifecycle_service.zig");

pub const StorageScanReport = struct {
    partition: ?u8,
    partitions: u8,
    scanned_generations: usize,
    retained_generations: usize,
    removed_generations: usize,
    scanned_bytes: u64,
    retained_bytes: u64,
    removed_bytes: u64,
    expired_multipart_uploads: usize,
};

pub const StorageScannerSnapshot = struct {
    next_partition: u8,
    last_scan: ?StorageScanReport,
};

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
    multipart_store: ?MetadataMultipartStore = null,
    master_key: ?CredentialMasterKey = null,
    local_object_data: ?LocalObjectDataStore = null,
    local_multipart_data: ?LocalMultipartDataStore = null,
    metadata_index: ?index_module.MetadataIndex = null,
    io: ?std.Io = null,
    state_mutex: std.Io.Mutex = .init,
    object_locks: object_lock_pool.ObjectLockPool = .{},
    multipart_locks: object_lock_pool.ObjectLockPool = .{},
    recovery_state: recovery.State = .{},
    recovery_report: ?recovery.Report = null,
    started_at_unix_seconds: i64 = 0,
    fault_injector: fault_injection.Injector = .disabled,
    scanner_mutex: std.Io.Mutex = .init,
    scanner_state_mutex: std.Io.Mutex = .init,
    scanner_partition: u8 = 0,
    last_scanner_report: ?StorageScanReport = null,

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
        self.started_at_unix_seconds = std.Io.Clock.real.now(io).toSeconds();
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
        self.multipart_store = MetadataMultipartStore.init(self.local_repository.?.interface());
        self.local_object_data = LocalObjectDataStore.init(
            self.allocator,
            self.data_root.?,
            io,
            self.config.stream_buffer_size,
        );
        self.local_object_data.?.setFaultInjectorForTesting(self.fault_injector);
        self.local_repository.?.setFaultInjectorForTesting(self.fault_injector);
        self.local_multipart_data = LocalMultipartDataStore.init(
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
        _ = self.local_multipart_data.?.interface().cleanupStaged() catch |err| {
            self.recovery_state.markRequired(error.Unavailable);
            if (!builtin.is_test) std.log.err("ZigFS staged multipart cleanup failed: {t}", .{err});
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
        const now = std.Io.Clock.real.now(io).toSeconds();
        _ = self.multipartService().?.cleanupExpired(
            now,
            self.config.s3_multipart_expiry_seconds,
        ) catch |err| {
            self.recovery_state.markRequired(switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.CorruptMetadata, error.CorruptData => error.CorruptRecord,
                else => error.Unavailable,
            });
            if (!builtin.is_test) std.log.err("ZigFS multipart recovery cleanup failed: {t}", .{err});
            return;
        };
        _ = self.objectGc().?.collectMultipart() catch |err| {
            self.recovery_state.markRequired(switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.CorruptMetadata, error.CorruptData => error.CorruptRecord,
                error.Unavailable => error.Unavailable,
            });
            if (!builtin.is_test) std.log.err("ZigFS object data reachability scan failed: {t}", .{err});
            return;
        };
    }

    pub fn runStorageScanner(self: *Application) object_gc.Error!StorageScanReport {
        const io = self.io orelse return error.Unavailable;
        self.scanner_mutex.lockUncancelable(io);
        defer self.scanner_mutex.unlock(io);

        self.scanner_state_mutex.lockUncancelable(io);
        const partition = self.scanner_partition;
        self.scanner_state_mutex.unlock(io);
        const gc_report = (self.objectGc() orelse return error.Unavailable).collectPartition(partition) catch |err| return err;
        const now = std.Io.Clock.real.now(io).toSeconds();
        const expired = (self.multipartService() orelse return error.Unavailable).cleanupExpired(
            now,
            self.config.s3_multipart_expiry_seconds,
        ) catch |err| return mapScannerMultipartError(err);
        const report = StorageScanReport{
            .partition = partition,
            .partitions = object_gc.partition_count,
            .scanned_generations = gc_report.scanned_generations,
            .retained_generations = gc_report.retained_generations,
            .removed_generations = gc_report.removed_generations,
            .scanned_bytes = gc_report.scanned_bytes,
            .retained_bytes = gc_report.retained_bytes,
            .removed_bytes = gc_report.removed_bytes,
            .expired_multipart_uploads = expired,
        };
        self.scanner_state_mutex.lockUncancelable(io);
        defer self.scanner_state_mutex.unlock(io);
        self.scanner_partition = (partition + 1) % object_gc.partition_count;
        self.last_scanner_report = report;
        return report;
    }

    pub fn runStorageGc(self: *Application) object_gc.Error!StorageScanReport {
        const io = self.io orelse return error.Unavailable;
        self.scanner_mutex.lockUncancelable(io);
        defer self.scanner_mutex.unlock(io);
        const now = std.Io.Clock.real.now(io).toSeconds();
        const expired = (self.multipartService() orelse return error.Unavailable).cleanupExpired(
            now,
            self.config.s3_multipart_expiry_seconds,
        ) catch |err| return mapScannerMultipartError(err);
        const gc_report = (self.objectGc() orelse return error.Unavailable).collect() catch |err| return err;
        const report = StorageScanReport{
            .partition = null,
            .partitions = 1,
            .scanned_generations = gc_report.scanned_generations,
            .retained_generations = gc_report.retained_generations,
            .removed_generations = gc_report.removed_generations,
            .scanned_bytes = gc_report.scanned_bytes,
            .retained_bytes = gc_report.retained_bytes,
            .removed_bytes = gc_report.removed_bytes,
            .expired_multipart_uploads = expired,
        };
        self.scanner_state_mutex.lockUncancelable(io);
        defer self.scanner_state_mutex.unlock(io);
        self.last_scanner_report = report;
        return report;
    }

    pub fn storageScannerSnapshot(self: *Application) ?StorageScannerSnapshot {
        const io = self.io orelse return null;
        self.scanner_state_mutex.lockUncancelable(io);
        defer self.scanner_state_mutex.unlock(io);
        return .{
            .next_partition = self.scanner_partition,
            .last_scan = self.last_scanner_report,
        };
    }

    pub fn deinit(self: *Application, io: std.Io) void {
        if (self.metadata_index) |*metadata_index| {
            metadata_index.deinit();
            self.metadata_index = null;
        }
        self.bucket_store = null;
        self.credential_store = null;
        self.object_store = null;
        self.multipart_store = null;
        self.local_object_data = null;
        self.local_multipart_data = null;
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

    pub fn setFaultInjectorForTesting(
        self: *Application,
        injector: fault_injection.Injector,
    ) void {
        self.fault_injector = injector;
        if (self.local_object_data) |*store| store.setFaultInjectorForTesting(injector);
        if (self.local_repository) |*repository| repository.setFaultInjectorForTesting(injector);
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
        const multipart_data_store = if (self.local_multipart_data) |*store|
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
            multipart_data_store,
            index,
            &self.state_mutex,
            &self.object_locks,
        );
    }

    pub fn lifecycleService(self: *Application) ?lifecycle_service.LifecycleService {
        return .{
            .allocator = self.allocator,
            .buckets = self.bucketService() orelse return null,
            .objects = self.objectService() orelse return null,
        };
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

    pub fn multipartService(self: *Application) ?multipart_service.MultipartService {
        if (!self.recovery_state.isReady()) return null;
        const io = self.io orelse return null;
        const bucket_store = if (self.bucket_store) |*store| store.interface() else return null;
        const multipart_store = if (self.multipart_store) |*store| store.interface() else return null;
        const data_store = if (self.local_multipart_data) |*store| store.interface() else return null;
        const objects = self.objectService() orelse return null;
        const index = if (self.metadata_index) |*metadata_index| metadata_index else return null;
        return multipart_service.MultipartService.init(
            self.allocator,
            io,
            bucket_store,
            multipart_store,
            data_store,
            objects,
            index,
            &self.state_mutex,
            &self.multipart_locks,
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
        const multipart_store = if (self.multipart_store) |*store|
            store.interface()
        else
            return null;
        const multipart_data_store = if (self.local_multipart_data) |*store|
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
            multipart_store,
            multipart_data_store,
            index,
            &self.state_mutex,
            &self.object_locks,
            &self.multipart_locks,
        );
    }

    pub fn managementService(self: *Application) ?management_service.ManagementService {
        if (!self.recovery_state.isReady()) return null;
        const io = self.io orelse return null;
        const object_store = if (self.object_store) |*store| store.interface() else return null;
        const index = if (self.metadata_index) |*metadata_index| metadata_index else return null;
        return management_service.ManagementService.init(
            self.allocator,
            io,
            object_store,
            index,
            &self.state_mutex,
            self.started_at_unix_seconds,
        );
    }

    pub fn recoveryState(self: *const Application) *const recovery.State {
        return &self.recovery_state;
    }
};

fn mapScannerMultipartError(err: multipart_service.Error) object_gc.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CorruptMetadata => error.CorruptMetadata,
        error.CorruptData => error.CorruptData,
        else => error.Unavailable,
    };
}

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

fn testObjectDataPath(
    buffer: []u8,
    object: @import("../domain/object.zig").Object,
) ![]u8 {
    const bucket_hex = std.fmt.bytesToHex(object.bucket_id, .lower);
    const object_hex = std.fmt.bytesToHex(object.id, .lower);
    const generation_hex = std.fmt.bytesToHex(object.data_generation, .lower);
    return std.fmt.bufPrint(
        buffer,
        "data/objects/{s}/{s}/{s}/{s}/data",
        .{ &bucket_hex, object_hex[0..2], &object_hex, &generation_hex },
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
    try std.testing.expect(app.multipartService() != null);
    try std.testing.expect(app.objectListing() != null);
    try std.testing.expect(app.objectGc() != null);
    try std.testing.expect(app.recovery_report != null);
}

test "multipart lifecycle streams concurrent parts completes and aborts without changing the object" {
    const object_data_port = @import("../ports/object_data_store.zig");
    const test_streams = @import("../testing/streams.zig");

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
    const bucket = try app.bucketService().?.create("project-assets", "owner-a");
    defer bucket.deinit(std.testing.allocator);
    const multiparts = app.multipartService().?;
    const upload = try multiparts.create("project-assets", "large/archive.bin", .{
        .content_type = "application/octet-stream",
        .user_metadata = &.{.{ .name = "client-id", .value = "mobile" }},
    });
    defer upload.deinit(std.testing.allocator);
    var upload_id_buffer: [32]u8 = undefined;
    const upload_id = multipart_domain.formatUploadId(upload.id, &upload_id_buffer);

    const UploadTask = struct {
        service: multipart_service.MultipartService,
        upload_id: []const u8,
        part_number: u16,
        size: u64,
        byte: u8,
        result: ?multipart_domain.Part = null,
        failure: ?multipart_service.Error = null,

        fn run(self: *@This()) void {
            var source = test_streams.RepeatingSource.init(self.size, self.byte);
            self.result = self.service.uploadPart(
                "project-assets",
                "large/archive.bin",
                self.upload_id,
                self.part_number,
                source.interface(),
                .{},
            ) catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var first_task: UploadTask = .{
        .service = multiparts,
        .upload_id = upload_id,
        .part_number = 1,
        .size = multipart_domain.min_nonfinal_part_size,
        .byte = 'A',
    };
    var second_task: UploadTask = .{
        .service = multiparts,
        .upload_id = upload_id,
        .part_number = 2,
        .size = 8,
        .byte = 'B',
    };
    var first_future = try std.testing.io.concurrent(UploadTask.run, .{&first_task});
    var second_future = try std.testing.io.concurrent(UploadTask.run, .{&second_task});
    first_future.await(std.testing.io);
    second_future.await(std.testing.io);
    try std.testing.expect(first_task.failure == null);
    try std.testing.expect(second_task.failure == null);

    var replacement_source = test_streams.SliceSource.init("tail");
    const second = try multiparts.uploadPart(
        "project-assets",
        "large/archive.bin",
        upload_id,
        2,
        replacement_source.interface(),
        .{},
    );
    try std.testing.expectError(error.NotFound, app.local_multipart_data.?.interface().stat(.{
        .upload_id = upload.id,
        .part_number = second_task.result.?.number,
        .data_generation = second_task.result.?.data_generation,
    }));
    const listed = try multiparts.listParts("project-assets", "large/archive.bin", upload_id);
    defer listed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), listed.parts.len);
    try std.testing.expectEqual(@as(u64, 4), listed.parts[1].size);
    try std.testing.expectError(error.InvalidPartOrder, multiparts.complete(
        "project-assets",
        "large/archive.bin",
        upload_id,
        &.{
            .{ .number = 2, .etag_md5 = second.etag_md5 },
            .{ .number = 1, .etag_md5 = first_task.result.?.etag_md5 },
        },
    ));
    try std.testing.expectError(error.InvalidPart, multiparts.complete(
        "project-assets",
        "large/archive.bin",
        upload_id,
        &.{
            .{ .number = 1, .etag_md5 = .{0} ** 16 },
            .{ .number = 2, .etag_md5 = second.etag_md5 },
        },
    ));
    var composite = std.crypto.hash.Md5.init(.{});
    composite.update(&first_task.result.?.etag_md5);
    composite.update(&second.etag_md5);
    var expected_etag: [16]u8 = undefined;
    composite.final(&expected_etag);
    const object = try multiparts.complete(
        "project-assets",
        "large/archive.bin",
        upload_id,
        &.{
            .{ .number = 1, .etag_md5 = first_task.result.?.etag_md5 },
            .{ .number = 2, .etag_md5 = second.etag_md5 },
        },
    );
    defer object.deinit(std.testing.allocator);
    try std.testing.expectEqual(multipart_domain.min_nonfinal_part_size + 4, object.size);
    try std.testing.expectEqual(@as(u16, 2), object.etag_part_count);
    try std.testing.expectEqualSlices(u8, &expected_etag, &object.etag_md5);
    try std.testing.expect(object.multipart_manifest != null);
    try std.testing.expectEqual(@as(usize, 2), object.multipart_manifest.?.parts.len);
    try std.testing.expectError(error.NotFound, app.local_object_data.?.interface().stat(object_data_port.Location{
        .bucket_id = object.bucket_id,
        .object_id = object.id,
        .data_generation = object.data_generation,
    }));
    try std.testing.expectError(
        error.UploadNotFound,
        multiparts.listParts("project-assets", "large/archive.bin", upload_id),
    );
    var sink = test_streams.CollectingSink.init(std.testing.allocator);
    defer sink.deinit();
    const downloaded = try app.objectService().?.get("project-assets", "large/archive.bin", sink.interface());
    defer downloaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, @intCast(object.size)), sink.bytes.items.len);
    try std.testing.expectEqual(@as(u8, 'A'), sink.bytes.items[0]);
    try std.testing.expectEqualStrings("tail", sink.bytes.items[sink.bytes.items.len - 4 ..]);
    var range_sink = test_streams.CollectingSink.init(std.testing.allocator);
    defer range_sink.deinit();
    var lease = try app.objectService().?.open("project-assets", "large/archive.bin");
    defer lease.deinit();
    try lease.streamRange(multipart_domain.min_nonfinal_part_size - 2, 5, range_sink.interface());
    try std.testing.expectEqualStrings("AAtai", range_sink.bytes.items);
    lease.deinit();
    const gc_report = try app.objectGc().?.collect();
    try std.testing.expectEqual(@as(usize, 2), gc_report.scanned_generations);
    try std.testing.expectEqual(@as(usize, 2), gc_report.retained_generations);
    try std.testing.expectEqual(@as(usize, 0), gc_report.removed_generations);

    const aborted = try multiparts.create("project-assets", "large/archive.bin", .{});
    defer aborted.deinit(std.testing.allocator);
    var aborted_id_buffer: [32]u8 = undefined;
    const aborted_id = multipart_domain.formatUploadId(aborted.id, &aborted_id_buffer);
    var aborted_source = test_streams.SliceSource.init("discarded");
    _ = try multiparts.uploadPart("project-assets", "large/archive.bin", aborted_id, 1, aborted_source.interface(), .{});
    try multiparts.abort("project-assets", "large/archive.bin", aborted_id);
    const after_abort = try app.objectService().?.head("project-assets", "large/archive.bin");
    defer after_abort.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &object.etag_md5, &after_abort.etag_md5);
}

test "completed multipart manifest survives restart and its parts follow version reachability" {
    const object_domain = @import("../domain/object.zig");
    const multipart_data_port = @import("../ports/multipart_data_store.zig");
    const test_streams = @import("../testing/streams.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(data_root);
    const config: Config = .{ .data_root = data_root, .metrics_enabled = false };
    var version_id: object_domain.VersionId = .null_version;
    var part_location: multipart_data_port.Location = undefined;

    {
        var writer = Application.initWithAllocator(config, std.testing.allocator);
        defer writer.deinit(std.testing.io);
        try writer.initialize(std.testing.io);
        const created_bucket = try writer.bucketService().?.create("versioned-parts", "owner-a");
        created_bucket.deinit(std.testing.allocator);
        const configured_bucket = try writer.bucketService().?.setVersioning("versioned-parts", .enabled);
        configured_bucket.deinit(std.testing.allocator);
        const multiparts = writer.multipartService().?;
        const upload = try multiparts.create("versioned-parts", "restart.bin", .{});
        defer upload.deinit(std.testing.allocator);
        var upload_id_buffer: [32]u8 = undefined;
        const upload_id = multipart_domain.formatUploadId(upload.id, &upload_id_buffer);
        var source = test_streams.SliceSource.init("persistent multipart body");
        const part = try multiparts.uploadPart("versioned-parts", "restart.bin", upload_id, 1, source.interface(), .{});
        part_location = .{
            .upload_id = upload.id,
            .part_number = part.number,
            .data_generation = part.data_generation,
        };
        const object = try multiparts.complete("versioned-parts", "restart.bin", upload_id, &.{.{
            .number = part.number,
            .etag_md5 = part.etag_md5,
        }});
        defer object.deinit(std.testing.allocator);
        version_id = object.version_id;
        try std.testing.expect(object.multipart_manifest != null);
    }

    var recovered = Application.initWithAllocator(config, std.testing.allocator);
    defer recovered.deinit(std.testing.io);
    try recovered.initialize(std.testing.io);
    var sink = test_streams.CollectingSink.init(std.testing.allocator);
    defer sink.deinit();
    const restored = try recovered.objectService().?.get("versioned-parts", "restart.bin", sink.interface());
    defer restored.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("persistent multipart body", sink.bytes.items);
    const retained = try recovered.objectGc().?.collect();
    try std.testing.expectEqual(@as(usize, 1), retained.scanned_generations);
    try std.testing.expectEqual(@as(usize, 1), retained.retained_generations);
    try std.testing.expect((try recovered.objectService().?.deleteVersion("versioned-parts", "restart.bin", version_id)).deleted);
    const removed = try recovered.objectGc().?.collect();
    try std.testing.expectEqual(@as(usize, 1), removed.removed_generations);
    try std.testing.expectError(error.NotFound, recovered.local_multipart_data.?.interface().stat(part_location));
}

test "multipart upload listing supports discovery delimiters and stable resume markers" {
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
    const bucket = try app.bucketService().?.create("project-assets", "owner-a");
    defer bucket.deinit(std.testing.allocator);
    const multiparts = app.multipartService().?;

    const nested = try multiparts.create("project-assets", "photos/2026/a.bin", .{});
    defer nested.deinit(std.testing.allocator);
    const root = try multiparts.create("project-assets", "photos/root.bin", .{});
    defer root.deinit(std.testing.allocator);
    const duplicate_a = try multiparts.create("project-assets", "same.bin", .{});
    defer duplicate_a.deinit(std.testing.allocator);
    const duplicate_b = try multiparts.create("project-assets", "same.bin", .{});
    defer duplicate_b.deinit(std.testing.allocator);

    const first = try multiparts.listUploads("project-assets", .{
        .prefix = "photos/",
        .delimiter = "/",
        .max_uploads = 1,
    });
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.is_truncated);
    try std.testing.expectEqual(@as(usize, 0), first.uploads.len);
    try std.testing.expectEqual(@as(usize, 1), first.common_prefixes.len);
    try std.testing.expectEqualStrings("photos/2026/", first.common_prefixes[0]);
    try std.testing.expectEqualStrings("photos/2026/", first.next_key_marker.?);
    try std.testing.expect(first.next_upload_id_marker == null);

    const second = try multiparts.listUploads("project-assets", .{
        .prefix = "photos/",
        .delimiter = "/",
        .key_marker = first.next_key_marker,
        .max_uploads = 1,
    });
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(!second.is_truncated);
    try std.testing.expectEqual(@as(usize, 1), second.uploads.len);
    try std.testing.expectEqualStrings("photos/root.bin", second.uploads[0].key);

    const duplicate_page = try multiparts.listUploads("project-assets", .{
        .prefix = "same.bin",
        .max_uploads = 1,
    });
    defer duplicate_page.deinit(std.testing.allocator);
    try std.testing.expect(duplicate_page.is_truncated);
    try std.testing.expectEqual(@as(usize, 1), duplicate_page.uploads.len);
    try std.testing.expectEqualStrings("same.bin", duplicate_page.next_key_marker.?);
    try std.testing.expect(duplicate_page.next_upload_id_marker != null);

    const resumed = try multiparts.listUploads("project-assets", .{
        .prefix = "same.bin",
        .key_marker = duplicate_page.next_key_marker,
        .upload_id_marker = duplicate_page.next_upload_id_marker,
    });
    defer resumed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), resumed.uploads.len);
    try std.testing.expect(!std.mem.eql(u8, duplicate_page.uploads[0].upload_id, resumed.uploads[0].upload_id));
}

test "startup recovery expires multipart metadata and part data" {
    const multipart_payload = @import("../metadata/multipart_payload.zig");
    const test_streams = @import("../testing/streams.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(data_root);
    const config: Config = .{
        .data_root = data_root,
        .metrics_enabled = false,
        .s3_multipart_expiry_seconds = 60,
    };
    const upload_id = [_]u8{ 50, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 };
    const generation = [_]u8{ 51, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 };
    var upload_id_buffer: [32]u8 = undefined;
    const upload_id_text = multipart_domain.formatUploadId(upload_id, &upload_id_buffer);

    var writer = Application.initWithAllocator(config, std.testing.allocator);
    var writer_live = true;
    defer if (writer_live) writer.deinit(std.testing.io);
    try writer.initialize(std.testing.io);
    const bucket = try writer.bucketService().?.create("project-assets", "owner-a");
    defer bucket.deinit(std.testing.allocator);
    var source = test_streams.SliceSource.init("stale-part");
    const staged = try writer.local_multipart_data.?.interface().stage(generation, source.interface());
    try writer.local_multipart_data.?.interface().publish(staged, .{
        .upload_id = upload_id,
        .part_number = 1,
        .data_generation = generation,
    });
    const initiated_at = std.Io.Clock.real.now(std.testing.io).toSeconds() - 61;
    const payload = try multipart_payload.encode(std.testing.allocator, .{
        .id = upload_id,
        .bucket_id = bucket.bucket.id,
        .bucket_name = "project-assets",
        .key = "stale.bin",
        .content_type = "application/octet-stream",
        .user_metadata = &.{},
        .initiated_at_unix_seconds = initiated_at,
        .parts = &.{.{
            .number = 1,
            .size = staged.size,
            .etag_md5 = staged.etag_md5,
            .checksum_sha256 = staged.checksum_sha256,
            .data_generation = generation,
            .last_modified_unix_seconds = initiated_at,
        }},
    });
    defer std.testing.allocator.free(payload);
    _ = try writer.metadataRepository().?.put(
        std.testing.allocator,
        .multipart,
        upload_id_text,
        .missing,
        payload,
    );
    writer.deinit(std.testing.io);
    writer_live = false;

    var recovered = Application.initWithAllocator(config, std.testing.allocator);
    defer recovered.deinit(std.testing.io);
    try recovered.initialize(std.testing.io);
    try std.testing.expect(recovered.recoveryState().isReady());
    try std.testing.expect(!recovered.metadataIndex().?.containsUpload(upload_id_text));
    var sink = test_streams.CollectingSink.init(std.testing.allocator);
    defer sink.deinit();
    try std.testing.expectError(error.NotFound, recovered.local_multipart_data.?.interface().readRange(.{
        .upload_id = upload_id,
        .part_number = 1,
        .data_generation = generation,
    }, 0, 1, sink.interface()));
}

test "startup recovery removes part data left after multipart tombstone commit" {
    const test_streams = @import("../testing/streams.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(data_root);
    const config: Config = .{ .data_root = data_root, .metrics_enabled = false };

    var writer = Application.initWithAllocator(config, std.testing.allocator);
    var writer_live = true;
    defer if (writer_live) writer.deinit(std.testing.io);
    try writer.initialize(std.testing.io);
    const bucket = try writer.bucketService().?.create("project-assets", "owner-a");
    defer bucket.deinit(std.testing.allocator);
    const multiparts = writer.multipartService().?;
    const upload = try multiparts.create("project-assets", "interrupted.bin", .{});
    defer upload.deinit(std.testing.allocator);
    var upload_id_buffer: [32]u8 = undefined;
    const upload_id = multipart_domain.formatUploadId(upload.id, &upload_id_buffer);
    var source = test_streams.SliceSource.init("part-left-after-tombstone");
    const part = try multiparts.uploadPart(
        "project-assets",
        "interrupted.bin",
        upload_id,
        1,
        source.interface(),
        .{},
    );
    const current = try multiparts.listParts("project-assets", "interrupted.bin", upload_id);
    defer current.deinit(std.testing.allocator);

    _ = try writer.multipart_store.?.interface().tombstone(
        std.testing.allocator,
        upload_id,
        current.metadata_generation,
    );
    writer.deinit(std.testing.io);
    writer_live = false;

    var recovered = Application.initWithAllocator(config, std.testing.allocator);
    defer recovered.deinit(std.testing.io);
    try recovered.initialize(std.testing.io);
    try std.testing.expect(recovered.recoveryState().isReady());
    try std.testing.expect(!recovered.metadataIndex().?.containsUpload(upload_id));
    var sink = test_streams.CollectingSink.init(std.testing.allocator);
    defer sink.deinit();
    try std.testing.expectError(error.NotFound, recovered.local_multipart_data.?.interface().readRange(.{
        .upload_id = upload.id,
        .part_number = part.number,
        .data_generation = part.data_generation,
    }, 0, 1, sink.interface()));
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

test "object gc validates multipart reachability before deleting object orphans" {
    const id = @import("../common/id.zig");
    const object_data_port = @import("../ports/object_data_store.zig");
    const multipart_data_port = @import("../ports/multipart_data_store.zig");
    const test_streams = @import("../testing/streams.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(data_root);
    var app = Application.initWithAllocator(.{
        .data_root = data_root,
        .metrics_enabled = false,
    }, std.testing.allocator);
    defer app.deinit(std.testing.io);
    try app.initialize(std.testing.io);

    const bucket = try app.bucketService().?.create("project-assets", "owner-a");
    defer bucket.deinit(std.testing.allocator);
    const upload = try app.multipartService().?.create("project-assets", "pending.bin", .{});
    defer upload.deinit(std.testing.allocator);
    var upload_id_buffer: [32]u8 = undefined;
    const upload_id = multipart_domain.formatUploadId(upload.id, &upload_id_buffer);
    var part_source = test_streams.SliceSource.init("part-body");
    const part = try app.multipartService().?.uploadPart(
        "project-assets",
        "pending.bin",
        upload_id,
        1,
        part_source.interface(),
        .{},
    );
    const part_location: multipart_data_port.Location = .{
        .upload_id = upload.id,
        .part_number = part.number,
        .data_generation = part.data_generation,
    };

    const orphan_location: object_data_port.Location = .{
        .bucket_id = bucket.bucket.id,
        .object_id = try id.randomV4(std.testing.io),
        .data_generation = try id.randomV4(std.testing.io),
    };
    var orphan_source = test_streams.SliceSource.init("orphan-body");
    const staged = try app.local_object_data.?.interface().stage(
        orphan_location.data_generation,
        orphan_source.interface(),
    );
    try app.local_object_data.?.interface().publish(staged, orphan_location);

    try std.testing.expect(try app.local_multipart_data.?.interface().deleteGeneration(part_location));
    try std.testing.expectError(error.CorruptData, app.objectGc().?.collect());
    try std.testing.expectEqual(
        @as(u64, "orphan-body".len),
        try app.local_object_data.?.interface().stat(orphan_location),
    );
}

test "storage scanner advances one partition per successful cycle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(data_root);
    var app = Application.initWithAllocator(.{
        .data_root = data_root,
        .metrics_enabled = false,
    }, std.testing.allocator);
    defer app.deinit(std.testing.io);
    try app.initialize(std.testing.io);

    const initial = app.storageScannerSnapshot().?;
    try std.testing.expectEqual(@as(u8, 0), initial.next_partition);
    try std.testing.expect(initial.last_scan == null);

    for (0..object_gc.partition_count) |partition| {
        const report = try app.runStorageScanner();
        try std.testing.expectEqual(@as(?u8, @intCast(partition)), report.partition);
        try std.testing.expectEqual(object_gc.partition_count, report.partitions);
        const snapshot = app.storageScannerSnapshot().?;
        try std.testing.expectEqual(
            @as(u8, @intCast((partition + 1) % object_gc.partition_count)),
            snapshot.next_partition,
        );
        try std.testing.expectEqual(report.partition, snapshot.last_scan.?.partition);
    }

    try std.testing.expectEqual(@as(u8, 0), app.storageScannerSnapshot().?.next_partition);
}

test "phase 8 crash checkpoints recover only complete object generations" {
    const test_streams = @import("../testing/streams.zig");
    const cases = [_]struct {
        point: fault_injection.Point,
        skip_hits: usize = 0,
        replacement_committed: bool,
        orphan_generations: usize,
    }{
        .{
            .point = .object_data_write,
            .skip_hits = 1,
            .replacement_committed = false,
            .orphan_generations = 0,
        },
        .{
            .point = .object_stage_synced,
            .replacement_committed = false,
            .orphan_generations = 0,
        },
        .{
            .point = .object_generation_published,
            .replacement_committed = false,
            .orphan_generations = 1,
        },
        .{
            .point = .journal_intent_persisted,
            .replacement_committed = false,
            .orphan_generations = 1,
        },
        .{
            .point = .metadata_temporary_synced,
            .replacement_committed = false,
            .orphan_generations = 1,
        },
        .{
            .point = .metadata_commit_persisted,
            .replacement_committed = true,
            .orphan_generations = 1,
        },
        .{
            .point = .metadata_record_published,
            .replacement_committed = true,
            .orphan_generations = 1,
        },
    };

    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const data_root = try testDataRootPath(std.testing.allocator, &tmp);
        defer std.testing.allocator.free(data_root);
        const config: Config = .{
            .data_root = data_root,
            .stream_buffer_size = @import("../common/streaming.zig").min_buffer_size,
            .metrics_enabled = false,
        };
        const replacement_size = config.stream_buffer_size * 2 + 17;

        var writer = Application.initWithAllocator(config, std.testing.allocator);
        var writer_live = true;
        defer if (writer_live) writer.deinit(std.testing.io);
        try writer.initialize(std.testing.io);
        const bucket = try writer.bucketService().?.create("phase8-faults", "owner-a");
        bucket.deinit(std.testing.allocator);
        var original_source = test_streams.SliceSource.init("stable-old-generation");
        const original = try writer.objectService().?.put(
            "phase8-faults",
            "checkpoint.bin",
            original_source.interface(),
            .{},
        );
        original.deinit(std.testing.allocator);

        var fail_once = fault_injection.FailOnce.init(case.point, case.skip_hits);
        writer.setFaultInjectorForTesting(fail_once.interface());
        var replacement_source = test_streams.RepeatingSource.init(replacement_size, 'N');
        try std.testing.expectError(error.Unavailable, writer.objectService().?.put(
            "phase8-faults",
            "checkpoint.bin",
            replacement_source.interface(),
            .{},
        ));
        try std.testing.expect(fail_once.triggered);
        writer.deinit(std.testing.io);
        writer_live = false;

        var recovered = Application.initWithAllocator(config, std.testing.allocator);
        defer recovered.deinit(std.testing.io);
        try recovered.initialize(std.testing.io);
        try std.testing.expect(recovered.recoveryState().isReady());
        try std.testing.expect(recovered.recovery_report != null);
        if (case.replacement_committed) {
            var sink: test_streams.CountingSink = .{};
            const object = try recovered.objectService().?.get(
                "phase8-faults",
                "checkpoint.bin",
                sink.interface(),
            );
            defer object.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(u64, replacement_size), object.size);
            try std.testing.expectEqual(@as(u64, replacement_size), sink.size);
        } else {
            var sink = test_streams.CollectingSink.init(std.testing.allocator);
            defer sink.deinit();
            const object = try recovered.objectService().?.get(
                "phase8-faults",
                "checkpoint.bin",
                sink.interface(),
            );
            defer object.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("stable-old-generation", sink.bytes.items);
        }
        try std.testing.expectEqual(
            @as(usize, 0),
            try recovered.local_object_data.?.interface().cleanupStaged(),
        );
        const gc_report = try recovered.objectGc().?.collect();
        try std.testing.expectEqual(@as(usize, 1), gc_report.retained_generations);
        try std.testing.expectEqual(case.orphan_generations, gc_report.removed_generations);
    }
}

test "phase 8 rebuild ignores corrupt disposable index snapshots" {
    const test_streams = @import("../testing/streams.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(data_root);
    const config: Config = .{ .data_root = data_root, .metrics_enabled = false };

    var writer = Application.initWithAllocator(config, std.testing.allocator);
    var writer_live = true;
    defer if (writer_live) writer.deinit(std.testing.io);
    try writer.initialize(std.testing.io);
    const bucket = try writer.bucketService().?.create("phase8-index", "owner-a");
    bucket.deinit(std.testing.allocator);
    var source = test_streams.SliceSource.init("repository-remains-authoritative");
    const object = try writer.objectService().?.put(
        "phase8-index",
        "recoverable.txt",
        source.interface(),
        .{},
    );
    object.deinit(std.testing.allocator);
    writer.deinit(std.testing.io);
    writer_live = false;

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "data/.zigfs/indexes/corrupt.snapshot",
        .data = "not-a-valid-index-snapshot",
    });

    var recovered = Application.initWithAllocator(config, std.testing.allocator);
    defer recovered.deinit(std.testing.io);
    try recovered.initialize(std.testing.io);
    try std.testing.expect(recovered.recoveryState().isReady());
    var sink = test_streams.CollectingSink.init(std.testing.allocator);
    defer sink.deinit();
    const restored = try recovered.objectService().?.get(
        "phase8-index",
        "recoverable.txt",
        sink.interface(),
    );
    defer restored.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("repository-remains-authoritative", sink.bytes.items);
}

test "phase 8 reports same-length object data checksum corruption after restart" {
    const test_streams = @import("../testing/streams.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(data_root);
    const config: Config = .{ .data_root = data_root, .metrics_enabled = false };
    var data_path_buffer: [512]u8 = undefined;
    var data_path_length: usize = 0;

    var writer = Application.initWithAllocator(config, std.testing.allocator);
    var writer_live = true;
    defer if (writer_live) writer.deinit(std.testing.io);
    try writer.initialize(std.testing.io);
    const bucket = try writer.bucketService().?.create("phase8-data", "owner-a");
    bucket.deinit(std.testing.allocator);
    var source = test_streams.SliceSource.init("expected-object-bytes");
    const object = try writer.objectService().?.put(
        "phase8-data",
        "corrupt.bin",
        source.interface(),
        .{},
    );
    const data_path = try testObjectDataPath(&data_path_buffer, object);
    data_path_length = data_path.len;
    object.deinit(std.testing.allocator);
    writer.deinit(std.testing.io);
    writer_live = false;

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = data_path_buffer[0..data_path_length],
        .data = "tampered-object-bytes",
    });

    var recovered = Application.initWithAllocator(config, std.testing.allocator);
    defer recovered.deinit(std.testing.io);
    try recovered.initialize(std.testing.io);
    try std.testing.expect(recovered.recoveryState().isReady());
    const metadata = try recovered.objectService().?.head("phase8-data", "corrupt.bin");
    defer metadata.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, "expected-object-bytes".len), metadata.size);
    var sink = test_streams.CollectingSink.init(std.testing.allocator);
    defer sink.deinit();
    try std.testing.expectError(
        error.CorruptData,
        recovered.objectService().?.get("phase8-data", "corrupt.bin", sink.interface()),
    );
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
