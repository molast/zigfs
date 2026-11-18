const std = @import("std");
const metadata = @import("metadata_engine");
const allocator = std.heap.smp_allocator;

/// Black-box probe for stopped backups and genuine filesystem faults. It does
/// not inject engine errors and never fills a host filesystem by itself.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.InvalidArguments;
    const mode = args[1];
    var root = try std.Io.Dir.cwd().openDir(init.io, args[2], .{});
    defer root.close(init.io);
    if (std.mem.eql(u8, mode, "readonly")) {
        if (metadata.Engine.open(allocator, init.io, root)) |value| {
            var writable = value;
            writable.deinit();
            return error.ExpectedReadOnlyFilesystem;
        } else |err| {
            if (err != error.ReadOnlyFileSystem and err != error.AccessDenied and err != error.PermissionDenied) return err;
            std.debug.print("{{\"write_open_rejected\":true,\"error\":\"{s}\"}}\n", .{@errorName(err)});
        }
        return;
    }
    var engine = try metadata.Engine.open(allocator, init.io, root);
    defer engine.deinit();
    if (std.mem.eql(u8, mode, "seed")) {
        for (1..metadata.namespace_count + 1) |namespace| {
            const kind: metadata.Type = @fromBackingInt(@intCast(namespace));
            _ = try engine.interface().put(allocator, kind, "acknowledged", .missing, "before-checkpoint");
            _ = try engine.interface().tombstone(allocator, kind, "deleted", .missing);
        }
        try engine.checkpoint();
        var mutations: [metadata.namespace_count]metadata.Mutation = undefined;
        for (&mutations, 1..) |*mutation, namespace| {
            mutation.* = .{ .record_type = @fromBackingInt(@intCast(namespace)), .key = "tail", .payload = "after-checkpoint" };
        }
        _ = try engine.commit(&mutations);
        std.debug.print("{{\"seeded\":true,\"generation\":{d}}}\n", .{engine.stats().generation});
        return;
    }
    try verify(&engine);
    if (std.mem.eql(u8, mode, "full-write")) {
        const bytes = try allocator.alloc(u8, 1024 * 1024);
        defer allocator.free(bytes);
        @memset(bytes, 71);
        const result = engine.commit(&.{
            .{ .record_type = .object, .key = "uncertain-a", .expected = .missing, .payload = bytes },
            .{ .record_type = .bucket, .key = "uncertain-b", .expected = .missing, .payload = bytes },
        });
        if (result) |_| return error.ExpectedDiskFailure else |err| {
            if (err != error.Unavailable or !engine.stats().recovery_required) return error.ExpectedFrozenEngine;
        }
        if (engine.interface().get(allocator, .object, "acknowledged")) |record| {
            record.deinit(allocator);
            return error.ExpectedFrozenEngine;
        } else |err| if (err != error.Unavailable) return err;
        std.debug.print("{{\"write_failed\":true,\"frozen\":true}}\n", .{});
        return;
    }
    if (!std.mem.eql(u8, mode, "verify")) return error.InvalidArguments;
    var found: usize = 0;
    var generation: ?u64 = null;
    for ([_]metadata.Type{ .object, .bucket }, [_][]const u8{ "uncertain-a", "uncertain-b" }) |kind, key| {
        if (engine.interface().get(allocator, kind, key)) |record| {
            defer record.deinit(allocator);
            if (record.payload.len != 1024 * 1024 or !std.mem.allEqual(u8, record.payload, 71)) return error.TornTransaction;
            if (generation) |expected| if (record.generation != expected) return error.TornTransaction;
            generation = record.generation;
            found += 1;
        } else |err| if (err != error.NotFound) return err;
    }
    if (found != 0 and found != 2) return error.TornTransaction;
    _ = try engine.interface().put(allocator, .object, "after-recovery", .any, "writable");
    try engine.checkpoint();
    std.debug.print("{{\"verified\":true,\"uncertain_records\":{d},\"write_after_recovery\":true}}\n", .{found});
}

fn verify(engine: *metadata.Engine) !void {
    for (1..metadata.namespace_count + 1) |namespace| {
        const kind: metadata.Type = @fromBackingInt(@intCast(namespace));
        const old = try engine.interface().get(allocator, kind, "acknowledged");
        defer old.deinit(allocator);
        const tail = try engine.interface().get(allocator, kind, "tail");
        defer tail.deinit(allocator);
        const deleted = try engine.interface().get(allocator, kind, "deleted");
        defer deleted.deinit(allocator);
        if (!std.mem.eql(u8, old.payload, "before-checkpoint") or
            !std.mem.eql(u8, tail.payload, "after-checkpoint") or
            tail.generation != metadata.namespace_count * 2 + 1 or !deleted.tombstone) return error.ValidationFailed;
    }
}
