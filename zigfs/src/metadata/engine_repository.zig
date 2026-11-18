const std = @import("std");
const engine_package = @import("metadata_engine");
const port = @import("../ports/metadata_repository.zig");
const fault = @import("../common/fault_injection.zig");

pub const directory = ".zigfs.sys";
pub const MaintenanceReport = struct {
    checkpoint_generation: u64,
    gc_epoch: u48,
    removed_tombstones: usize,
};
pub const MaintenanceError = port.Error || error{RecoveryRequired};

/// Owns its directory and Engine. Keep at a stable address after start().
/// Business read/conditional-write sequences and collect() share Application's
/// state mutex. This permits translating the business missing predicate to the
/// current engine epoch without allowing GC to cross a business decision.
/// Do not call collect() directly from a background task without that guard.
pub const EngineRepository = struct {
    root: std.Io.Dir,
    io: std.Io,
    engine: engine_package.Engine,
    runtime: engine_package.Runtime = undefined,
    started: bool = false,
    fault_injector: fault.Injector = .disabled,

    pub fn open(allocator: std.mem.Allocator, root: std.Io.Dir, io: std.Io) !EngineRepository {
        return openWithInitialization(allocator, root, io, true);
    }

    /// Existing ZigFS roots must already have an engine WAL and lock. A lost
    /// database directory must never become a successful empty initialization.
    pub fn openWithInitialization(
        allocator: std.mem.Allocator,
        root: std.Io.Dir,
        io: std.Io,
        allow_create: bool,
    ) !EngineRepository {
        if (!allow_create) {
            _ = root.statFile(io, directory ++ "/wal", .{}) catch return error.CorruptRecord;
            _ = root.statFile(io, directory ++ "/LOCK", .{}) catch return error.CorruptRecord;
        }
        var db = try root.createDirPathOpen(io, directory, .{});
        errdefer db.close(io);
        var engine = try engine_package.Engine.open(allocator, io, db);
        errdefer engine.deinit();
        try @import("durable.zig").syncParent(root, io, directory);
        return .{ .root = db, .io = io, .engine = engine };
    }

    pub fn start(self: *EngineRepository) !void {
        self.runtime = .{ .engine = &self.engine };
        try self.runtime.start();
        self.started = true;
    }

    pub fn deinit(self: *EngineRepository) void {
        if (self.started) self.runtime.stop();
        self.engine.deinit();
        self.root.close(self.io);
    }

    pub fn collect(self: *EngineRepository) MaintenanceError!MaintenanceReport {
        const collected = self.engine.collectTombstones() catch |err| return mapError(err);
        // With no tombstones, still checkpoint writes and retry covered WAL cleanup.
        if (collected.reclaimed == 0) self.engine.checkpoint() catch |err| return mapError(err);
        const stats = self.engine.stats();
        return .{
            .checkpoint_generation = stats.checkpoint_generation,
            .gc_epoch = stats.gc_epoch,
            .removed_tombstones = collected.reclaimed,
        };
    }

    pub fn setFaultInjectorForTesting(self: *EngineRepository, injector: fault.Injector) void {
        self.fault_injector = injector;
    }

    pub fn interface(self: *EngineRepository) port.MetadataRepository {
        return .{ .context = self, .vtable = &.{
            .get = get,
            .put = put,
            .tombstone = tombstone,
            .scan = scan,
        } };
    }

    fn get(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        namespace: engine_package.Type,
        key: []const u8,
    ) port.Error!port.Record {
        const self: *EngineRepository = @ptrCast(@alignCast(context));
        return self.engine.interface().get(allocator, namespace, key) catch |err| mapError(err);
    }

    fn scan(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        namespace: engine_package.Type,
    ) port.Error!port.ScanResult {
        const self: *EngineRepository = @ptrCast(@alignCast(context));
        return self.engine.interface().scan(allocator, namespace) catch |err| mapError(err);
    }

    fn put(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        namespace: engine_package.Type,
        key: []const u8,
        expected: port.ExpectedGeneration,
        payload: []const u8,
    ) port.Error!u64 {
        _ = allocator;
        const self: *EngineRepository = @ptrCast(@alignCast(context));
        return self.write(namespace, key, expected, payload, false);
    }

    fn tombstone(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        namespace: engine_package.Type,
        key: []const u8,
        expected: port.ExpectedGeneration,
    ) port.Error!u64 {
        _ = allocator;
        const self: *EngineRepository = @ptrCast(@alignCast(context));
        return self.write(namespace, key, expected, "", true);
    }

    fn write(
        self: *EngineRepository,
        namespace: engine_package.Type,
        key: []const u8,
        expected: port.ExpectedGeneration,
        payload: []const u8,
        deleted: bool,
    ) port.Error!u64 {
        if (@import("builtin").is_test and self.fault_injector.trigger(.metadata_before_commit)) return error.Unavailable;
        const predicate: engine_package.ExpectedGeneration = switch (expected) {
            .any => .any,
            .missing => .{ .missing_at = self.engine.stats().gc_epoch },
            .exact => |generation| .{ .exact = generation },
        };
        const mutations = [_]engine_package.Mutation{.{
            .record_type = namespace,
            .key = key,
            .expected = predicate,
            .payload = payload,
            .tombstone = deleted,
        }};
        const generation = if (self.started)
            self.runtime.commit(&mutations) catch |err| return mapError(err)
        else
            self.engine.commit(&mutations) catch |err| return mapError(err);
        if (@import("builtin").is_test and self.fault_injector.trigger(.metadata_after_commit)) return error.Unavailable;
        return generation;
    }
};

fn mapError(err: anyerror) port.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotFound => error.NotFound,
        error.Conflict => error.Conflict,
        error.InvalidKey => error.InvalidKey,
        error.PayloadTooLarge => error.PayloadTooLarge,
        error.GenerationExhausted => error.GenerationExhausted,
        error.CorruptRecord, error.CorruptJournal, error.UnsupportedFormat => error.CorruptRecord,
        else => error.Unavailable,
    };
}

test "engine adapter repository contract recovery and reclaimed key recreation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repository = try EngineRepository.open(std.testing.allocator, tmp.dir, std.testing.io);
    var opened = true;
    defer if (opened) repository.deinit();
    try repository.start();
    try @import("test_support").metadata_repository_contract.run(repository.interface());
    const deleted = try repository.interface().tombstone(std.testing.allocator, .object, "reclaimed", .missing);
    _ = try repository.collect();
    try std.testing.expectError(error.Conflict, repository.interface().put(std.testing.allocator, .object, "reclaimed", .{ .exact = deleted }, "old"));
    _ = try repository.interface().put(std.testing.allocator, .object, "reclaimed", .missing, "new");
    repository.deinit();
    opened = false;
    var reopened = try EngineRepository.open(std.testing.allocator, tmp.dir, std.testing.io);
    defer reopened.deinit();
    const record = try reopened.interface().get(std.testing.allocator, .object, "reclaimed");
    defer record.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("new", record.payload);
}
