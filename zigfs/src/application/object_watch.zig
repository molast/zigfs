//! Single-process, bounded replay of actual object events. A restart changes the epoch.
//! This is not a durable delivery queue: expired cursors fail explicitly, never skip silently.
const std = @import("std");
const Event = @import("../ports/bucket_events.zig").Event;
const A = std.mem.Allocator;
const Io = std.Io;
const max_items = 4096;
const max_bytes = 8 * 1024 * 1024;
const Record = struct {
    sequence: u64,
    bucket_id: [16]u8,
    category: []const u8,
    key: []const u8,
    body: []const u8,
};
pub const Page = struct { items: [][]const u8, cursor: []const u8, initialized: bool };
pub const Feed = struct {
    mutex: Io.Mutex = .init,
    epoch: ?[16]u8 = null,
    sequence: u64 = 0,
    records: std.ArrayList(Record) = .empty,
    bytes: usize = 0,

    fn freeRecord(a: A, record: Record) void {
        a.free(record.key);
        a.free(record.body);
    }
    pub fn deinit(self: *Feed, a: A) void {
        for (self.records.items) |record| freeRecord(a, record);
        self.records.deinit(a);
    }
    fn invalidate(self: *Feed, a: A) void {
        for (self.records.items) |record| freeRecord(a, record);
        self.records.clearRetainingCapacity();
        self.bytes = 0;
        self.sequence = 0;
        self.epoch = null;
    }
    fn ensureEpoch(self: *Feed, io: Io) !void {
        if (self.epoch == null) self.epoch = try @import("../common/id.zig").randomV4(io);
    }
    /// Called at the existing post-success notification sink, before subscription filtering.
    pub fn append(self: *Feed, a: A, io: Io, event: Event) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        errdefer self.invalidate(a);
        try self.ensureEpoch(io);
        const sequence = try std.math.add(u64, self.sequence, 1);
        const body = try std.json.Stringify.valueAlloc(a, .{
            .sequence = sequence,
            .time = Io.Clock.real.now(io).toSeconds(),
            .category = @tagName(event.category),
            .event = event.name,
            .bucket = event.bucket,
            .key = event.key,
            .size = event.size,
            .etag = event.etag,
            .version_id = event.version_id,
            .generation = event.generation,
        }, .{});
        errdefer a.free(body);
        const key = try a.dupe(u8, event.key);
        errdefer a.free(key);
        const size = body.len + key.len;
        if (size > max_bytes or body.len > 1024 * 1024) return error.EventTooLarge;
        while (self.records.items.len > 0 and (self.records.items.len >= max_items or self.bytes + size > max_bytes)) {
            const oldest = self.records.orderedRemove(0);
            self.bytes -= oldest.key.len + oldest.body.len;
            freeRecord(a, oldest);
        }
        try self.records.append(a, .{ .sequence = sequence, .bucket_id = event.bucket_id, .category = @tagName(event.category), .key = key, .body = body });
        self.bytes += size;
        self.sequence = sequence;
    }
    /// Copies a page into the caller arena while holding the feed lock briefly.
    pub fn read(self: *Feed, a: A, io: Io, bucket_id: [16]u8, cursor: ?[]const u8, prefix: []const u8, suffix: []const u8, categories: []const u8, limit: usize) !Page {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.ensureEpoch(io);
        const epoch = std.fmt.bytesToHex(self.epoch.?, .lower);
        var after = self.sequence;
        if (cursor) |value| {
            if (value.len < 34 or value[32] != ':' or !std.mem.eql(u8, value[0..32], &epoch)) return error.CursorExpired;
            after = std.fmt.parseInt(u64, value[33..], 10) catch return error.InvalidCursor;
            const floor = if (self.records.items.len > 0) self.records.items[0].sequence - 1 else self.sequence;
            if (after < floor) return error.CursorExpired;
            if (after > self.sequence) return error.InvalidCursor;
        }
        var items: std.ArrayList([]const u8) = .empty;
        var next = after;
        var used: usize = 0;
        if (cursor != null) for (self.records.items) |record| {
            if (record.sequence <= after) continue;
            var matches = std.mem.eql(u8, &record.bucket_id, &bucket_id) and std.mem.startsWith(u8, record.key, prefix) and std.mem.endsWith(u8, record.key, suffix);
            if (matches and categories.len > 0) {
                var tokens = std.mem.splitScalar(u8, categories, ',');
                matches = false;
                while (tokens.next()) |category| if (std.mem.eql(u8, category, record.category)) {
                    matches = true;
                    break;
                };
            }
            if (matches) {
                if (items.items.len >= limit or used + record.body.len > 1024 * 1024) break;
                try items.append(a, try a.dupe(u8, record.body));
                used += record.body.len;
            }
            next = record.sequence;
        };
        return .{ .items = try items.toOwnedSlice(a), .cursor = try std.fmt.allocPrint(a, "{s}:{d}", .{ epoch, next }), .initialized = cursor == null };
    }
};
