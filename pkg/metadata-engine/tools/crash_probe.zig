const std = @import("std");
const metadata = @import("metadata_engine");

const Barrier = struct {
    root: std.Io.Dir,
    io: std.Io,
    target: metadata.Point,
    engine: ?*metadata.Engine = null,
    mutate_on_capture: bool = false,

    fn hook(context: *anyopaque, point: metadata.Point) void {
        const self: *Barrier = @ptrCast(@alignCast(context));
        if ((point == .checkpoint_captured or point == .backup_captured) and self.mutate_on_capture) {
            self.mutate_on_capture = false;
            const engine = self.engine.?;
            _ = engine.commit(&.{
                .{ .record_type = .object, .key = "acknowledged", .payload = "intermediate" },
                .{ .record_type = .object, .key = "during-view", .payload = "new-value" },
                .{ .record_type = .credential, .key = "deleted-during-view", .tombstone = true },
            }) catch std.process.exit(94);
            _ = engine.interface().put(std.heap.smp_allocator, .object, "acknowledged", .any, "latest") catch std.process.exit(95);
        }
        if (point != self.target) return;
        var ready = self.root.createFile(self.io, "READY", .{}) catch std.process.exit(91);
        ready.writeStreamingAll(self.io, @tagName(point)) catch std.process.exit(92);
        ready.sync(self.io) catch std.process.exit(93);
        ready.close(self.io);
        // The Python parent sends SIGKILL; no Engine defers will execute.
        while (true) self.io.sleep(.fromSeconds(1), .awake) catch {};
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return error.InvalidArguments;
    const mode = args[1];
    var root = try std.Io.Dir.cwd().openDir(init.io, args[2], .{});
    defer root.close(init.io);
    var engine = try metadata.Engine.openWithOptions(std.heap.smp_allocator, init.io, root, .{ .segment_bytes = 128 });
    defer engine.deinit();
    const repository = engine.interface();
    if (std.mem.eql(u8, mode, "gc-crash") or std.mem.eql(u8, mode, "backup-crash")) {
        if (args.len != 4) return error.InvalidArguments;
        _ = try repository.tombstone(std.heap.smp_allocator, .bucket, "gc-deleted", .missing);
        const backup = std.mem.eql(u8, mode, "backup-crash");
        if (backup) _ = try engine.collectTombstones();
        const target = std.meta.stringToEnum(metadata.Point, args[3]) orelse return error.InvalidArguments;
        var barrier: Barrier = .{
            .root = root,
            .io = init.io,
            .target = target,
            .engine = &engine,
            .mutate_on_capture = backup,
        };
        engine.hook = .{ .context = &barrier, .call = Barrier.hook };
        if (backup) {
            _ = try engine.backup(root, "backup");
        } else {
            _ = try engine.collectTombstones();
        }
        return error.FaultPointNotReached;
    }
    if (std.mem.eql(u8, mode, "gc-verify")) {
        const epoch = engine.stats().gc_epoch;
        if (epoch > 1) return error.ValidationFailed;
        if (epoch == 0) {
            const record = try repository.get(std.heap.smp_allocator, .bucket, "gc-deleted");
            defer record.deinit(std.heap.smp_allocator);
            if (!record.tombstone) return error.ValidationFailed;
        } else {
            if (repository.get(std.heap.smp_allocator, .bucket, "gc-deleted")) |record| {
                record.deinit(std.heap.smp_allocator);
                return error.ValidationFailed;
            } else |err| if (err != error.NotFound) return err;
            if (repository.put(std.heap.smp_allocator, .bucket, "gc-deleted", .{ .missing_at = 0 }, "stale")) |_| {
                return error.ValidationFailed;
            } else |err| if (err != error.Conflict) return err;
            _ = try repository.put(std.heap.smp_allocator, .bucket, "gc-deleted", .{ .missing_at = epoch }, "fresh");
        }
        const acknowledged = try repository.get(std.heap.smp_allocator, .object, "acknowledged");
        defer acknowledged.deinit(std.heap.smp_allocator);
        if (!std.mem.eql(u8, acknowledged.payload, "durable")) return error.ValidationFailed;
        try engine.checkpoint();
        return;
    }
    if (std.mem.eql(u8, mode, "group-crash") or std.mem.eql(u8, mode, "group-verify")) {
        if (args.len != 4) return error.InvalidArguments;
        if (std.mem.eql(u8, mode, "group-crash")) {
            return @import("group_crash.zig").crash(&engine, args[3]);
        }
        return @import("group_crash.zig").verify(&engine, args[3]);
    }
    if (std.mem.eql(u8, mode, "seed")) {
        _ = try repository.put(std.heap.smp_allocator, .object, "acknowledged", .missing, "durable");
        return;
    }
    if (std.mem.eql(u8, mode, "pinned-verify")) {
        const record = try repository.get(std.heap.smp_allocator, .object, "acknowledged");
        defer record.deinit(std.heap.smp_allocator);
        if (!std.mem.eql(u8, record.payload, "latest")) return error.ValidationFailed;
        const inserted = try repository.get(std.heap.smp_allocator, .object, "during-view");
        defer inserted.deinit(std.heap.smp_allocator);
        if (!std.mem.eql(u8, inserted.payload, "new-value")) return error.ValidationFailed;
        const deleted = try repository.get(std.heap.smp_allocator, .credential, "deleted-during-view");
        defer deleted.deinit(std.heap.smp_allocator);
        if (!deleted.tombstone or record.generation <= deleted.generation) return error.ValidationFailed;
        _ = try repository.put(std.heap.smp_allocator, .object, "post-recovery", .any, "ok");
        try engine.checkpoint();
        return;
    }
    if (std.mem.eql(u8, mode, "verify")) {
        const record = try repository.get(std.heap.smp_allocator, .object, "acknowledged");
        defer record.deinit(std.heap.smp_allocator);
        if (!std.mem.eql(u8, record.payload, "durable")) return error.ValidationFailed;
        if (args.len > 3 and std.mem.eql(u8, args[3], "expect-new")) {
            const updated = try repository.get(std.heap.smp_allocator, .object, "new");
            defer updated.deinit(std.heap.smp_allocator);
            if (!std.mem.eql(u8, updated.payload, "new-value")) return error.ValidationFailed;
        }
        _ = try repository.put(std.heap.smp_allocator, .object, "post-recovery", .any, "ok");
        try engine.checkpoint();
        return;
    }
    const pinned_crash = std.mem.eql(u8, mode, "pinned-crash");
    if ((!std.mem.eql(u8, mode, "crash") and !pinned_crash) or args.len != 4) return error.InvalidArguments;
    const target = std.meta.stringToEnum(metadata.Point, args[3]) orelse return error.InvalidArguments;
    var barrier: Barrier = .{ .root = root, .io = init.io, .target = target, .engine = &engine, .mutate_on_capture = pinned_crash };
    engine.hook = .{ .context = &barrier, .call = Barrier.hook };
    if (pinned_crash or target == .checkpoint_captured or target == .snapshot_written or
        target == .snapshot_synced or target == .snapshot_published or target == .after_snapshot or target == .cleanup_started)
    {
        try engine.checkpoint();
    } else {
        _ = try repository.put(std.heap.smp_allocator, .object, "new", .missing, "new-value");
    }
    return error.FaultPointNotReached;
}
