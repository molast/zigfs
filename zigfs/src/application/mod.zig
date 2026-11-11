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
const MetadataDirectoryStore = @import("../metadata/directory_store.zig").MetadataDirectoryStore;
const MetadataMultipartStore = @import("../metadata/multipart_store.zig").MetadataMultipartStore;
const index_module = @import("../metadata/index.zig");
const recovery = @import("../metadata/recovery.zig");
const local_layout = @import("../metadata/local_layout.zig");
const multipart_domain = @import("../domain/multipart.zig");
const MetadataRepository = @import("../ports/metadata_repository.zig").MetadataRepository;

pub const logging = @import("logging.zig");

pub const bucket_service = @import("bucket_service.zig");
pub const continuation_token = @import("continuation_token.zig");
pub const credential_service = @import("credential_service.zig");
pub const object_gc = @import("object_gc.zig");
pub const object_lock_pool = @import("object_lock_pool.zig");
pub const object_listing = @import("object_listing.zig");
pub const multipart_service = @import("multipart_service.zig");
pub const management_service = @import("management_service.zig");
pub const object_service = @import("object_service.zig");
pub const object_encryption = @import("object_encryption.zig");
pub const object_encryption_frames = @import("object_encryption_frames.zig");
pub const object_encrypted_stream = @import("object_encrypted_stream.zig");
pub const lifecycle_service = @import("lifecycle_service.zig");
pub const directory_service = @import("directory_service.zig");

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
    running: bool,
    last_completed_at: ?i64,
    last_duration_ms: ?u64,
    last_attempt_succeeded: ?bool,
    next_partition: u8,
    last_scan: ?StorageScanReport,
};

pub const audit_schema = @import("audit_schema.zig");
pub const AuditEvent = audit_schema.Event;

pub const AuditEventPage = struct {
    items: []AuditEvent,
    next_cursor: ?[]const u8 = null,

    pub fn deinit(self: *AuditEventPage, allocator: std.mem.Allocator) void {
        for (self.items) |event| audit_schema.free(allocator, event);
        allocator.free(self.items);
        if (self.next_cursor) |cursor| allocator.free(cursor);
        self.* = .{ .items = &.{} };
    }
};

// Retain a practical single-node audit window while keeping query memory bounded.
// Durable long-term archival is planned as a separate storage tier.
const audit_event_capacity: usize = 4096;
const audit_events_path = ".zigfs/system/audit-events.json";
const audit_archive_dir = ".zigfs/system/audit-archive";

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
    directory_store: ?MetadataDirectoryStore = null,
    multipart_store: ?MetadataMultipartStore = null,
    master_key: ?CredentialMasterKey = null,
    logger: ?logging.Service = null,
    kms: ?@import("kms.zig").Service = null,
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
    scanner_running: bool = false,
    scanner_completed_at: ?i64 = null,
    scanner_duration_ms: ?u64 = null,
    scanner_last_success: ?bool = null,
    policy_mutex: std.Io.Mutex = .init,
    audit_mutex: std.Io.Mutex = .init,
    audit_events: std.ArrayListUnmanaged(AuditEvent) = .empty,

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

    pub fn recordAudit(self: *Application, event: AuditEvent) void {
        self.audit_mutex.lockUncancelable(self.io orelse return);
        defer self.audit_mutex.unlock(self.io.?);
        if (self.audit_events.items.len == audit_event_capacity) {
            self.persistArchivedEvent(self.audit_events.items[0]);
            self.freeAuditEvent(self.audit_events.items[0]);
            _ = self.audit_events.orderedRemove(0);
        }
        const owned = self.cloneAuditEvent(event) catch return;
        self.audit_events.append(self.allocator, owned) catch {
            self.freeAuditEvent(owned);
            return;
        };
        self.persistAuditEvents();
    }

    fn persistArchivedEvent(self: *Application, event: AuditEvent) void {
        const io = self.io orelse return;
        const root = self.data_root orelse return;
        root.createDirPath(io, audit_archive_dir) catch return;
        var path_buffer: [180]u8 = undefined;
        const archive_id = @import("../common/id.zig").randomV4(io) catch return;
        const path = std.fmt.bufPrint(&path_buffer, "{s}/{d}-{s}.json", .{ audit_archive_dir, event.timestamp_unix_seconds, std.fmt.bytesToHex(archive_id, .lower) }) catch return;
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        var json: std.json.Stringify = .{ .writer = &output.writer };
        json.write(event) catch return;
        var atomic = root.createFileAtomic(io, path, .{ .replace = false }) catch return;
        defer atomic.deinit(io);
        atomic.file.setPermissions(io, .fromMode(0o600)) catch return;
        atomic.file.writeStreamingAll(io, output.written()) catch return;
        atomic.file.sync(io) catch return;
        atomic.link(io) catch return;
    }

    fn persistAuditEvents(self: *Application) void {
        const io = self.io orelse return;
        const root = self.data_root orelse return;
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        var json: std.json.Stringify = .{ .writer = &output.writer };
        json.write(self.audit_events.items) catch return;
        var atomic = root.createFileAtomic(io, audit_events_path, .{ .replace = true }) catch return;
        defer atomic.deinit(io);
        atomic.file.setPermissions(io, .fromMode(0o600)) catch return;
        atomic.file.writeStreamingAll(io, output.written()) catch return;
        atomic.file.sync(io) catch return;
        atomic.replace(io) catch return;
    }

    fn loadAuditEvents(self: *Application) void {
        const io = self.io orelse return;
        const root = self.data_root orelse return;
        const bytes = root.readFileAlloc(io, audit_events_path, self.allocator, .limited(32 * 1024 * 1024)) catch return;
        defer self.allocator.free(bytes);
        const parsed = std.json.parseFromSlice([]AuditEvent, self.allocator, bytes, .{ .allocate = .alloc_always }) catch return;
        defer parsed.deinit();
        for (parsed.value) |event| {
            if (self.audit_events.items.len == audit_event_capacity) break;
            const owned = self.cloneAuditEvent(event) catch break;
            self.audit_events.append(self.allocator, owned) catch {
                self.freeAuditEvent(owned);
                break;
            };
        }
    }

    fn freeAuditEvent(self: *Application, event: AuditEvent) void {
        audit_schema.free(self.allocator, event);
    }
    fn cloneAuditEvent(self: *Application, event: AuditEvent) !AuditEvent {
        return audit_schema.clone(self.allocator, event);
    }

    fn auditEventNewestFirst(_: void, left: AuditEvent, right: AuditEvent) bool {
        return left.timestamp_unix_seconds > right.timestamp_unix_seconds;
    }

    pub fn listAuditEvents(self: *Application, bucket: []const u8, offset: usize, limit: usize, from: ?i64, to: ?i64, action: ?[]const u8, outcome: ?[]const u8) !AuditEventPage {
        return self.queryAuditEvents(bucket, offset, limit, from, to, action, outcome, .{});
    }
    pub fn queryAuditEvents(self: *Application, bucket: []const u8, offset: usize, limit: usize, from: ?i64, to: ?i64, action: ?[]const u8, outcome: ?[]const u8, filters: audit_schema.Filters) !AuditEventPage {
        const io = self.io orelse return error.Unavailable;
        self.audit_mutex.lockUncancelable(io);
        defer self.audit_mutex.unlock(io);
        var candidates: std.ArrayListUnmanaged(AuditEvent) = .empty;
        defer candidates.deinit(self.allocator);
        defer for (candidates.items) |event| self.freeAuditEvent(event);
        for (self.audit_events.items) |event| try candidates.append(self.allocator, try self.cloneAuditEvent(event));
        if (self.data_root) |root| if (root.openDir(io, audit_archive_dir, .{ .iterate = true })) |directory_value| {
            var directory = directory_value;
            defer directory.close(io);
            var iterator = directory.iterate();
            while (try iterator.next(io)) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
                const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ audit_archive_dir, entry.name });
                defer self.allocator.free(path);
                const bytes = root.readFileAlloc(io, path, self.allocator, .limited(64 * 1024)) catch continue;
                defer self.allocator.free(bytes);
                const parsed = std.json.parseFromSlice(AuditEvent, self.allocator, bytes, .{ .allocate = .alloc_always }) catch continue;
                defer parsed.deinit();
                try candidates.append(self.allocator, try self.cloneAuditEvent(parsed.value));
            }
        } else |_| {};
        std.mem.sort(AuditEvent, candidates.items, {}, auditEventNewestFirst);
        var items = try self.allocator.alloc(AuditEvent, @min(limit, candidates.items.len));
        var count: usize = 0;
        var skipped: usize = 0;
        var matched_total: usize = 0;
        for (candidates.items) |event| {
            if (!audit_schema.matches(event, filters)) continue;
            if (bucket.len > 0 and !std.mem.eql(u8, event.target, bucket)) {
                const s3_prefix = try std.fmt.allocPrint(self.allocator, "/{s}", .{bucket});
                defer self.allocator.free(s3_prefix);
                const admin_prefix = try std.fmt.allocPrint(self.allocator, "/_admin/v1/buckets/{s}", .{bucket});
                defer self.allocator.free(admin_prefix);
                const match_s3 = std.mem.startsWith(u8, event.target, s3_prefix) and (event.target.len == s3_prefix.len or event.target[s3_prefix.len] == '/');
                const match_admin = std.mem.startsWith(u8, event.target, admin_prefix) and (event.target.len == admin_prefix.len or event.target[admin_prefix.len] == '/');
                if (!match_s3 and !match_admin) continue;
            }
            if (from) |value| if (event.timestamp_unix_seconds < value) continue;
            if (to) |value| if (event.timestamp_unix_seconds > value) continue;
            if (action) |value| if (!std.mem.eql(u8, event.action, value) and !std.mem.eql(u8, event.event_action, value)) continue;
            if (outcome) |value| {
                if (!std.mem.eql(u8, event.outcome, value) and !std.mem.eql(u8, event.response.status, value) and !(std.mem.eql(u8, value, "success") and std.mem.startsWith(u8, event.outcome, "success:"))) continue;
            }
            matched_total += 1;
            if (skipped < offset) {
                skipped += 1;
                continue;
            }
            if (count == items.len) break;
            items[count] = try self.cloneAuditEvent(event);
            count += 1;
        }
        items = try self.allocator.realloc(items, count);
        const has_more = offset + count < matched_total;
        const next_cursor = if (has_more) try std.fmt.allocPrint(self.allocator, "{d}", .{offset + count}) else null;
        return .{ .items = items, .next_cursor = next_cursor };
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
        self.directory_store = MetadataDirectoryStore.init(self.local_repository.?.interface());
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
        self.loadAuditEvents();

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
        self.logger = .{ .root = self.data_root.?, .io = io, .allocator = self.allocator };
        try self.logger.?.init();
        self.kms = .{ .root = self.data_root.?, .io = io, .master = self.master_key.?.bytes, .allocator = self.allocator };
        self.local_multipart_data.?.master_key = self.master_key.?.bytes;

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
        // Object tags are persisted as version-scoped sidecars. Validate them
        // before advertising readiness so malformed authorization context is
        // treated as recovery corruption instead of being ignored.
        _ = object_tag_store.validateAll(self.allocator, self.data_root.?, io) catch |err| {
            self.recovery_state.markRequired(switch (err) {
                error.InvalidTag => error.CorruptRecord,
                error.OutOfMemory => error.OutOfMemory,
                else => error.Unavailable,
            });
            if (!builtin.is_test) std.log.err("ZigFS object tag sidecar validation failed: {t}", .{err});
            return;
        };
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
        const started = std.Io.Clock.awake.now(io);
        self.scanner_state_mutex.lockUncancelable(io);
        self.scanner_running = true;
        self.scanner_state_mutex.unlock(io);
        var succeeded = false;
        defer self.finishScanner(started, succeeded);

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
        succeeded = true;
        return report;
    }

    pub fn runStorageGc(self: *Application) object_gc.Error!StorageScanReport {
        const io = self.io orelse return error.Unavailable;
        self.scanner_mutex.lockUncancelable(io);
        defer self.scanner_mutex.unlock(io);
        const started = std.Io.Clock.awake.now(io);
        self.scanner_state_mutex.lockUncancelable(io);
        self.scanner_running = true;
        self.scanner_state_mutex.unlock(io);
        var succeeded = false;
        defer self.finishScanner(started, succeeded);
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
        succeeded = true;
        return report;
    }

    fn finishScanner(self: *Application, started: std.Io.Timestamp, succeeded: bool) void {
        const io = self.io.?;
        self.scanner_state_mutex.lockUncancelable(io);
        defer self.scanner_state_mutex.unlock(io);
        self.scanner_running = false;
        self.scanner_last_success = succeeded;
        self.scanner_duration_ms = @intCast(@max(0, started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds()));
        if (succeeded) self.scanner_completed_at = std.Io.Clock.real.now(io).toSeconds();
    }

    pub fn storageScannerSnapshot(self: *Application) ?StorageScannerSnapshot {
        const io = self.io orelse return null;
        self.scanner_state_mutex.lockUncancelable(io);
        defer self.scanner_state_mutex.unlock(io);
        return .{
            .running = self.scanner_running,
            .last_completed_at = self.scanner_completed_at,
            .last_duration_ms = self.scanner_duration_ms,
            .last_attempt_succeeded = self.scanner_last_success,
            .next_partition = self.scanner_partition,
            .last_scan = self.last_scanner_report,
        };
    }

    pub fn deinit(self: *Application, io: std.Io) void {
        if (self.logger) |*logger| logger.deinit();
        self.logger = null;
        for (self.audit_events.items) |event| self.freeAuditEvent(event);
        self.audit_events.deinit(self.allocator);
        if (self.metadata_index) |*metadata_index| {
            metadata_index.deinit();
            self.metadata_index = null;
        }
        self.bucket_store = null;
        self.credential_store = null;
        self.object_store = null;
        self.directory_store = null;
        self.multipart_store = null;
        self.local_object_data = null;
        self.local_multipart_data = null;
        self.local_repository = null;
        self.local_recovery_store = null;
        self.local_journal = null;
        if (self.kms) |*kms| {
            kms.deinit();
            self.kms = null;
        }
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
        const directories = self.directoryService() orelse return null;
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
        var service = object_service.ObjectService.init(
            self.allocator,
            io,
            bucket_store,
            object_store,
            data_store,
            multipart_data_store,
            if (self.master_key) |*master_key| &master_key.bytes else null,
            index,
            &self.state_mutex,
            &self.object_locks,
            directories,
        );
        service.kms = if (self.kms) |*kms| kms else null;
        return service;
    }

    pub fn folderService(self: *Application) ?@import("folder_service.zig").FolderService {
        return .{
            .allocator = self.allocator,
            .directories = self.directoryService() orelse return null,
            .objects = self.objectService() orelse return null,
            .uploads = self.multipartService() orelse return null,
            .garbage = self.objectGc() orelse return null,
        };
    }

    pub fn directoryService(self: *Application) ?directory_service.DirectoryService {
        if (!self.recovery_state.isReady()) return null;
        const io = self.io orelse return null;
        const bucket_store = if (self.bucket_store) |*store| store.interface() else return null;
        const directory_store = if (self.directory_store) |*store| store.interface() else return null;
        const object_store = if (self.object_store) |*store| store.interface() else return null;
        const index = if (self.metadata_index) |*value| value else return null;
        return directory_service.DirectoryService.init(self.allocator, io, bucket_store, directory_store, object_store, index, &self.state_mutex);
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
        var service = credential_service.CredentialService.init(
            self.allocator,
            io,
            store,
            index,
            &self.state_mutex,
            master_key,
        );
        service.identity_root = self.data_root;
        service.identity_mutex = &self.policy_mutex;
        return service;
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
            self.data_root orelse return null,
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
            .{ .number = 1, .etag_md5 = @as([16]u8, @splat(0)) },
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
        @memcpy(&secret_key, created.secret_key);
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

test "directories can be recreated after deletion and restart" {
    const test_streams = @import("../testing/streams.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(data_root);
    const config: Config = .{ .data_root = data_root, .metrics_enabled = false };

    {
        var app = Application.initWithAllocator(config, std.testing.allocator);
        defer app.deinit(std.testing.io);
        try app.initialize(std.testing.io);
        const bucket = try app.bucketService().?.create("project-assets", "owner-a");
        bucket.deinit(std.testing.allocator);
        const directories = app.directoryService().?;
        var previous_generation: u64 = 0;
        for (0..3) |_| {
            const created = try directories.create("project-assets", "images/");
            defer created.deinit(std.testing.allocator);
            try std.testing.expect(created.generation > previous_generation);
            previous_generation = created.generation;
            const repeated = try directories.create("project-assets", "images/");
            defer repeated.deinit(std.testing.allocator);
            try std.testing.expectEqual(created.generation, repeated.generation);
            try std.testing.expect((try directories.delete("project-assets", "images/")).deleted);
            try std.testing.expect(!(try directories.delete("project-assets", "images/")).deleted);

            const listed = try app.objectListing().?.list("project-assets", .{ .delimiter = "/" });
            defer listed.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 0), listed.objects.len);
            try std.testing.expectEqual(@as(usize, 0), listed.directories.len);
            try std.testing.expectEqual(@as(usize, 0), listed.common_prefixes.len);
        }

        const nested = try directories.create("project-assets", "images/nested/");
        nested.deinit(std.testing.allocator);
        try std.testing.expect((try directories.delete("project-assets", "images/")).deleted);
        try std.testing.expect(!(try directories.delete("project-assets", "images/nested/")).deleted);
        try std.testing.expect(!(try directories.delete("project-assets", "images/")).deleted);
    }

    var restarted = Application.initWithAllocator(config, std.testing.allocator);
    defer restarted.deinit(std.testing.io);
    try restarted.initialize(std.testing.io);
    try std.testing.expect(restarted.recoveryState().isReady());
    const directories = restarted.directoryService().?;
    const nested = try directories.create("project-assets", "images/nested/");
    nested.deinit(std.testing.allocator);
    try std.testing.expect((try directories.delete("project-assets", "images/nested/")).deleted);
    try std.testing.expect((try directories.delete("project-assets", "images/")).deleted);

    // Upload commits must also be able to recreate deleted parent directories.
    var source = test_streams.SliceSource.init("body");
    const object = try restarted.objectService().?.put("project-assets", "images/nested/file.txt", source.interface(), .{});
    object.deinit(std.testing.allocator);
    try std.testing.expect(restarted.metadata_index.?.directoryGeneration("project-assets", "images/") != null);
    try std.testing.expect(restarted.metadata_index.?.directoryGeneration("project-assets", "images/nested/") != null);
    try std.testing.expect((try directories.delete("project-assets", "images/nested/")).deleted);
}

test "directory deletion removes a same-key object marker from listings" {
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
    const directory = try app.directoryService().?.create("project-assets", "images/");
    directory.deinit(std.testing.allocator);

    // A trailing-slash PUT can leave both the typed directory and an object
    // marker at the same key. Directory deletion must clear both namespaces.
    var source = test_streams.SliceSource.init("");
    const marker = try app.objectService().?.put(
        "project-assets",
        "images/",
        source.interface(),
        .{},
    );
    marker.deinit(std.testing.allocator);

    const before = try app.objectListing().?.list("project-assets", .{ .delimiter = "/" });
    defer before.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), before.common_prefixes.len);
    try std.testing.expectEqualStrings("images/", before.common_prefixes[0]);

    const deleted = try app.directoryService().?.delete("project-assets", "images/");
    try std.testing.expect(deleted.deleted);

    const after = try app.objectListing().?.list("project-assets", .{ .delimiter = "/" });
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), after.objects.len);
    try std.testing.expectEqual(@as(usize, 0), after.common_prefixes.len);
    try std.testing.expectError(
        error.ObjectNotFound,
        app.objectService().?.head("project-assets", "images/"),
    );
}

test "removing a delete marker restores the object to management listings" {
    const test_streams = @import("../testing/streams.zig");
    const object_domain = @import("../domain/object.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(data_root);
    var app = Application.initWithAllocator(.{ .data_root = data_root, .metrics_enabled = false }, std.testing.allocator);
    defer app.deinit(std.testing.io);
    try app.initialize(std.testing.io);
    const bucket = try app.bucketService().?.create("project-assets", "owner-a");
    bucket.deinit(std.testing.allocator);
    const enabled = try app.bucketService().?.setVersioning("project-assets", .enabled);
    enabled.deinit(std.testing.allocator);
    var source = test_streams.SliceSource.init("body");
    const object = try app.objectService().?.put("project-assets", "restored.txt", source.interface(), .{});
    const object_version = object.version_id;
    object.deinit(std.testing.allocator);
    const marker = try app.objectService().?.delete("project-assets", "restored.txt");
    const marker_version = marker.version_id.?;
    try std.testing.expectError(error.ObjectNotFound, app.objectService().?.head("project-assets", "restored.txt"));
    _ = try app.objectService().?.deleteVersion("project-assets", "restored.txt", marker_version);
    const restored = try app.objectService().?.head("project-assets", "restored.txt");
    defer restored.deinit(std.testing.allocator);
    try std.testing.expect(object_domain.VersionId.eql(restored.version_id, object_version));
    const listed = try app.objectListing().?.list("project-assets", .{ .delimiter = "/" });
    defer listed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), listed.objects.len);
    try std.testing.expectEqualStrings("restored.txt", listed.objects[0].key);
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
    try std.testing.expect(!initial.running);
    try std.testing.expect(initial.last_completed_at == null);
    try std.testing.expect(initial.last_duration_ms == null);

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
        try std.testing.expect(!snapshot.running);
        try std.testing.expect(snapshot.last_completed_at != null);
        try std.testing.expect(snapshot.last_duration_ms != null);
        try std.testing.expectEqual(true, snapshot.last_attempt_succeeded.?);
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

test "audit events support bucket filtering, time filtering, and cursor pagination" {
    var application = Application.initWithAllocator(.{}, std.testing.allocator);
    defer application.deinit(std.testing.io);
    application.io = std.testing.io;
    application.recordAudit(.{ .timestamp_unix_seconds = 10, .request_id = "r1", .actor = "admin", .action = "create", .target = "alpha", .outcome = "ok" });
    application.recordAudit(.{ .timestamp_unix_seconds = 20, .request_id = "r2", .actor = "admin", .action = "update", .target = "alpha", .outcome = "ok" });
    application.recordAudit(.{ .timestamp_unix_seconds = 30, .request_id = "r3", .actor = "admin", .action = "update", .target = "beta", .outcome = "ok" });

    var page = try application.listAuditEvents("alpha", 0, 1, null, null, null, null);
    defer page.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), page.items.len);
    try std.testing.expectEqualStrings("r2", page.items[0].request_id);
    try std.testing.expect(page.next_cursor != null);

    var filtered = try application.listAuditEvents("alpha", 0, 10, 15, null, null, null);
    defer filtered.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), filtered.items.len);
    try std.testing.expectEqualStrings("r2", filtered.items[0].request_id);

    var next = try application.listAuditEvents("alpha", 1, 10, null, null, null, null);
    defer next.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), next.items.len);
    try std.testing.expectEqualStrings("r1", next.items[0].request_id);
}

test {
    std.testing.refAllDecls(@This());
}

pub const object_tag_store = @import("object_tag_store.zig");

pub const role_store = @import("role_store.zig");
pub const oidc_auth = @import("oidc_auth.zig");
pub const oidc_store = @import("oidc_store.zig");

test "folder cleanup preserves valid data and uploads while reclaiming orphan data" {
    const streams = @import("../testing/streams.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(root);
    var app = Application.initWithAllocator(.{ .data_root = root, .metrics_enabled = false }, std.testing.allocator);
    defer app.deinit(std.testing.io);
    try app.initialize(std.testing.io);
    (try app.bucketService().?.create("folder-tests", "owner")).deinit(std.testing.allocator);
    (try app.bucketService().?.setVersioning("folder-tests", .enabled)).deinit(std.testing.allocator);
    const objects = app.objectService().?;
    for ([_][]const u8{ "target/nested/file.txt", "target/nested/file.txt", "target-other/file.txt" }) |key| {
        var source = streams.SliceSource.init("payload");
        (try objects.put("folder-tests", key, source.interface(), .{})).deinit(std.testing.allocator);
    }
    const folders = app.folderService().?;
    try std.testing.expectError(error.InvalidDirectoryKey, folders.delete("folder-tests", "", true, true));
    try std.testing.expectError(error.InvalidDirectoryKey, folders.delete("folder-tests", "/", true, true));
    try std.testing.expectError(error.InvalidDirectoryKey, folders.delete("folder-tests", "target", true, true));
    try folders.delete("folder-tests", "target/", true, true);
    {
        const live_history = try objects.listVersions("folder-tests", "target/");
        defer live_history.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), live_history.entries.len);
        try std.testing.expect(!live_history.entries[0].is_delete_marker);
    }
    try folders.delete("folder-tests", "target/", false, false);
    {
        const history = try objects.listVersions("folder-tests", "target/");
        defer history.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 3), history.entries.len);
        try std.testing.expect(history.entries[0].is_delete_marker);
    }
    try std.testing.expect(app.metadata_index.?.directoryGeneration("folder-tests", "target/") == null);
    // A retry can purge history even after the visible folder record is gone.
    try folders.delete("folder-tests", "target/", true, false);
    {
        const history = try objects.listVersions("folder-tests", "target/");
        defer history.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), history.entries.len);
    }
    const upload = try app.multipartService().?.create("folder-tests", "target/pending.txt", .{});
    defer upload.deinit(std.testing.allocator);
    const sibling_upload = try app.multipartService().?.create("folder-tests", "target-other/pending.txt", .{});
    defer sibling_upload.deinit(std.testing.allocator);
    const before = try app.objectGc().?.data_store.scanGenerations(std.testing.allocator);
    defer before.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), before.generations.len);
    const retained_folder = try app.directoryService().?.create("folder-tests", "target/");
    defer retained_folder.deinit(std.testing.allocator);
    (try app.directoryService().?.create("folder-tests", "target/empty-child/")).deinit(std.testing.allocator);
    try folders.delete("folder-tests", "target/", true, true);
    try std.testing.expectEqual(retained_folder.generation, app.metadata_index.?.directoryGeneration("folder-tests", "target/").?);
    try std.testing.expect(app.metadata_index.?.directoryGeneration("folder-tests", "target/empty-child/") != null);
    // Retrying cleanup must keep the same directory record, not recreate it.
    try folders.delete("folder-tests", "target/", true, true);
    try std.testing.expectEqual(retained_folder.generation, app.metadata_index.?.directoryGeneration("folder-tests", "target/").?);
    const after = try app.objectGc().?.data_store.scanGenerations(std.testing.allocator);
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), after.generations.len);
    const uploads = try app.multipartService().?.listUploads("folder-tests", .{});
    defer uploads.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), uploads.uploads.len);
    const sibling = try objects.listVersions("folder-tests", "target-other/");
    defer sibling.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), sibling.entries.len);
    // Legal hold blocks permanent cleanup before any metadata is deleted.
    var protected_source = streams.SliceSource.init("protected");
    const protected = try objects.put("folder-tests", "locked/file.txt", protected_source.interface(), .{});
    defer protected.deinit(std.testing.allocator);
    (try objects.setLegalHold("folder-tests", "locked/file.txt", protected.version_id, true)).deinit(std.testing.allocator);
    try std.testing.expectError(error.ObjectLocked, folders.delete("folder-tests", "locked/", true, false));
    try folders.delete("folder-tests", "locked/", true, true);
    const locked_history = try objects.listVersions("folder-tests", "locked/");
    defer locked_history.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), locked_history.entries.len);
    try std.testing.expect(locked_history.entries[0].legal_hold);
    try std.testing.expect(app.metadata_index.?.directoryGeneration("folder-tests", "locked/") != null);
}

test "folder deletion removes unversioned children and legacy markers but refuses new live children during prune" {
    const streams = @import("../testing/streams.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(root);
    var app = Application.initWithAllocator(.{ .data_root = root, .metrics_enabled = false }, std.testing.allocator);
    defer app.deinit(std.testing.io);
    try app.initialize(std.testing.io);
    (try app.bucketService().?.create("folder-tests", "owner")).deinit(std.testing.allocator);
    const objects = app.objectService().?;
    var content = streams.SliceSource.init("content");
    (try objects.put("folder-tests", "test/nested/file", content.interface(), .{})).deinit(std.testing.allocator);
    var empty = streams.SliceSource.init("");
    (try objects.put("folder-tests", "test/", empty.interface(), .{})).deinit(std.testing.allocator);
    try std.testing.expectError(error.DirectoryNotEmpty, app.directoryService().?.prune("folder-tests", "test/", false));
    try app.folderService().?.delete("folder-tests", "test/", false, false);
    const versions = try objects.listVersions("folder-tests", "test/");
    defer versions.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), versions.entries.len);
    try std.testing.expect(app.metadata_index.?.directoryGeneration("folder-tests", "test/") == null);
    try std.testing.expect(app.metadata_index.?.objectGeneration("folder-tests", "test/") == null);
}

test "folder cleanup repairs stale and missing indexes without removing healthy empty folders" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(root);
    var app = Application.initWithAllocator(.{ .data_root = root, .metrics_enabled = false }, std.testing.allocator);
    defer app.deinit(std.testing.io);
    try app.initialize(std.testing.io);
    (try app.bucketService().?.create("repair-tests", "owner")).deinit(std.testing.allocator);
    const directories = app.directoryService().?;
    const folders = app.folderService().?;
    const parent = try directories.create("repair-tests", "target/");
    defer parent.deinit(std.testing.allocator);
    const stale = try directories.create("repair-tests", "target/stale/");
    defer stale.deinit(std.testing.allocator);
    // Simulate a durable deletion whose index update was lost.
    _ = try directories.directory_store.tombstone(std.testing.allocator, "repair-tests", "target/stale/", stale.generation);
    try std.testing.expect(app.metadata_index.?.directoryGeneration("repair-tests", "target/stale/") != null);
    try folders.cleanup("repair-tests", "target/");
    try std.testing.expect(app.metadata_index.?.directoryGeneration("repair-tests", "target/stale/") == null);
    try std.testing.expectEqual(parent.generation, app.metadata_index.?.directoryGeneration("repair-tests", "target/").?);
    // Repair an outdated index from the authoritative generation.
    const updated = try directories.directory_store.put(std.testing.allocator, "repair-tests", "target/", parent.created_at_unix_seconds, parent.last_modified_unix_seconds + 1, .{ .exact = parent.generation });
    try folders.cleanup("repair-tests", "target/");
    try std.testing.expectEqual(updated, app.metadata_index.?.directoryGeneration("repair-tests", "target/").?);
    // Repair a missing target index, including a healthy empty directory.
    try std.testing.expect(app.metadata_index.?.removeDirectory("repair-tests", "target/"));
    try folders.cleanup("repair-tests", "target/");
    try std.testing.expectEqual(updated, app.metadata_index.?.directoryGeneration("repair-tests", "target/").?);
    // Corrupt authoritative payloads are never guessed to be disposable.
    const encoded = try @import("../metadata/object_key.zig").encode(std.testing.allocator, "repair-tests", "target/");
    defer std.testing.allocator.free(encoded);
    _ = try app.local_repository.?.interface().put(std.testing.allocator, .directory, encoded, .{ .exact = updated }, "broken-directory-payload");
    try std.testing.expectError(error.CorruptMetadata, folders.cleanup("repair-tests", "target/"));
    try std.testing.expectEqual(updated, app.metadata_index.?.directoryGeneration("repair-tests", "target/").?);
}

test "SSE-S3 multipart encryption snapshot survives default change and restart" {
    const test_streams = @import("../testing/streams.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try testDataRootPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(data_root);
    const config: Config = .{ .data_root = data_root, .metrics_enabled = false };
    var upload_ids: [2][32]u8 = undefined;
    var etags: [2][16]u8 = undefined;
    {
        var app = Application.initWithAllocator(config, std.testing.allocator);
        defer app.deinit(std.testing.io);
        try app.initialize(std.testing.io);
        (try app.bucketService().?.create("sse-parts", "owner-a")).deinit(std.testing.allocator);
        for ([_]bool{ false, true }, 0..) |encrypted, i| {
            const upload = try app.multipartService().?.create("sse-parts", if (encrypted) "encrypted" else "plain", .{ .encryption = encrypted });
            defer upload.deinit(std.testing.allocator);
            const upload_id = multipart_domain.formatUploadId(upload.id, &upload_ids[i]);
            var source = test_streams.SliceSource.init("restart encrypted multipart");
            const part = try app.multipartService().?.uploadPart("sse-parts", upload.key, upload_id, 1, source.interface(), .{});
            etags[i] = part.etag_md5;
        }
        (try app.bucketService().?.setEncryption("sse-parts", .enabled)).deinit(std.testing.allocator);
    }
    var app = Application.initWithAllocator(config, std.testing.allocator);
    defer app.deinit(std.testing.io);
    try app.initialize(std.testing.io);
    for ([_]bool{ false, true }, 0..) |encrypted, i| {
        const key = if (encrypted) "encrypted" else "plain";
        const object = try app.multipartService().?.complete("sse-parts", key, &upload_ids[i], &.{.{ .number = 1, .etag_md5 = etags[i] }});
        defer object.deinit(std.testing.allocator);
        try std.testing.expectEqual(encrypted, object.encryption == .encrypted);
        var sink = test_streams.CollectingSink.init(std.testing.allocator);
        defer sink.deinit();
        const read = try app.objectService().?.get("sse-parts", key, sink.interface());
        defer read.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("restart encrypted multipart", sink.bytes.items);
    }
}

test "global audit queries include failures and preserve bucket boundaries" {
    var app = Application.initWithAllocator(.{}, std.testing.allocator);
    defer app.deinit(std.testing.io);
    app.io = std.testing.io;
    app.recordAudit(.{ .timestamp_unix_seconds = 10, .request_id = "one", .actor = "alice", .action = "put_object", .target = "/alpha/a.txt", .outcome = "success:200" });
    app.recordAudit(.{ .timestamp_unix_seconds = 20, .request_id = "two", .actor = "bob", .action = "put_object", .target = "/alphabet/b.txt", .outcome = "failure:403" });
    app.recordAudit(.{ .timestamp_unix_seconds = 30, .request_id = "three", .actor = "alice", .action = "PUT /_admin/v1/settings/logs", .target = "/_admin/v1/settings/logs", .outcome = "failure:400" });
    var all = try app.listAuditEvents("", 0, 1, null, null, null, null);
    defer all.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("three", all.items[0].request_id);
    try std.testing.expectEqualStrings("1", all.next_cursor.?);
    var next = try app.listAuditEvents("", 1, 10, null, null, null, null);
    defer next.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("two", next.items[0].request_id);
    var bucket = try app.listAuditEvents("alpha", 0, 10, null, null, null, null);
    defer bucket.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), bucket.items.len);
    try std.testing.expectEqualStrings("alice", bucket.items[0].actor);
}

test "audit window and archives survive reload including repeated request IDs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".zigfs/system");
    {
        var app = Application.initWithAllocator(.{}, std.testing.allocator);
        defer app.deinit(std.testing.io);
        app.io = std.testing.io;
        const event: AuditEvent = .{ .timestamp_unix_seconds = 10, .request_id = "client-reused-id", .actor = "alice", .action = "get_object", .target = "/bucket/key", .outcome = "success:200" };
        // Seed in memory, then exercise overflow persistence without thousands of disk writes.
        for (0..audit_event_capacity) |_| app.recordAudit(event);
        app.data_root = try tmp.dir.openDir(std.testing.io, ".", .{});
        app.recordAudit(event);
        app.recordAudit(event);
    }
    var restored = Application.initWithAllocator(.{}, std.testing.allocator);
    defer restored.deinit(std.testing.io);
    restored.io = std.testing.io;
    restored.data_root = try tmp.dir.openDir(std.testing.io, ".", .{});
    restored.loadAuditEvents();
    try std.testing.expectEqual(audit_event_capacity, restored.audit_events.items.len);
    var page = try restored.listAuditEvents("", 0, audit_event_capacity + 10, null, null, null, null);
    defer page.deinit(std.testing.allocator);
    try std.testing.expectEqual(audit_event_capacity + 2, page.items.len);
}
