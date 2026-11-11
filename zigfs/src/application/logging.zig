const std = @import("std");
const durable = @import("../metadata/durable.zig");
pub const config_path = ".zigfs/config/log_config.json";
pub const Config = struct {
    level: []const u8 = "info",
    format: []const u8 = "json",
    output: []const u8 = "console",
    directory: []const u8 = "logs",
    retention: []const u8 = "7",
    maxSize: []const u8 = "100",
    sizeUnit: []const u8 = "MiB",
    cleanup: []const u8 = "enabled",
    downloads: []const u8 = "enabled",
    range: []const u8 = "24h",
};
fn oneOf(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.mem.eql(u8, value, choice)) return true;
    return false;
}
pub fn maxBytes(c: Config) !u64 {
    const n = std.fmt.parseFloat(f64, c.maxSize) catch return error.InvalidLogConfig;
    const unit: f64 = if (std.mem.eql(u8, c.sizeUnit, "KiB")) 1024 else if (std.mem.eql(u8, c.sizeUnit, "MiB")) 1024 * 1024 else if (std.mem.eql(u8, c.sizeUnit, "GiB")) 1024 * 1024 * 1024 else return error.InvalidLogConfig;
    const bytes = n * unit;
    if (!std.math.isFinite(bytes) or bytes < 1 or bytes > 1024 * 1024 * 1024 * 1024) return error.InvalidLogConfig;
    return @intFromFloat(bytes);
}
pub fn validate(c: Config) !void {
    if (!oneOf(c.level, &.{ "trace", "debug", "info", "warn", "error", "off" }) or !oneOf(c.format, &.{ "json", "text" }) or !oneOf(c.output, &.{ "console", "file", "both" }) or !oneOf(c.retention, &.{ "forever", "1", "3", "7", "14", "30", "90" }) or !oneOf(c.cleanup, &.{ "enabled", "disabled" }) or !oneOf(c.downloads, &.{ "enabled", "disabled" }) or !oneOf(c.range, &.{ "1h", "24h", "7d", "30d" })) return error.InvalidLogConfig;
    _ = try maxBytes(c);
    if (c.directory.len == 0 or c.directory.len > 512 or std.fs.path.isAbsolute(c.directory)) return error.InvalidLogDirectory;
    var parts = std.mem.splitScalar(u8, c.directory, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".zigfs")) return error.InvalidLogDirectory;
        for (part) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') return error.InvalidLogDirectory;
    }
}
pub const Service = struct {
    root: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    parsed: ?std.json.Parsed(Config) = null,
    active_file: ?std.Io.File = null,
    active_bytes: u64 = 0,
    last_cleanup: i64 = 0,

    fn config(self: *Service) Config {
        return if (self.parsed) |p| p.value else .{};
    }
    pub fn init(self: *Service) !void {
        const bytes = self.root.readFileAlloc(self.io, config_path, self.allocator, .limited(16384)) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer self.allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(Config, self.allocator, bytes, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        try validate(parsed.value);
        self.parsed = parsed;
    }
    pub fn deinit(self: *Service) void {
        if (self.active_file) |file| file.close(self.io);
        if (self.parsed) |p| p.deinit();
        self.active_file = null;
        self.parsed = null;
    }
    // Walk each path component with no symlink following, including ancestors.
    fn directory(self: *Service, path: []const u8, create: bool) !std.Io.Dir {
        var dir = try self.root.openDir(self.io, ".", .{});
        errdefer dir.close(self.io);
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| {
            if (create) dir.createDir(self.io, part, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
            const next = try dir.openDir(self.io, part, .{ .follow_symlinks = false, .iterate = true });
            dir.close(self.io);
            dir = next;
        }
        return dir;
    }
    pub fn snapshot(self: *Service, a: std.mem.Allocator) !std.json.Parsed(Config) {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const bytes = try std.json.Stringify.valueAlloc(a, self.config(), .{});
        defer a.free(bytes);
        return std.json.parseFromSlice(Config, a, bytes, .{ .allocate = .alloc_always });
    }
    pub fn save(self: *Service, input: Config) !void {
        var c = input;
        if (c.directory.len == 0) c.directory = "logs";
        try validate(c);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var dir = try self.directory(c.directory, true);
        defer dir.close(self.io);
        // Validate file output permissions before committing the new configuration.
        const probe = try std.fmt.allocPrint(self.allocator, ".zigfs-log-check-{x}", .{std.Io.Clock.real.now(self.io).toNanoseconds()});
        defer self.allocator.free(probe);
        const probe_file = try dir.createFile(self.io, probe, .{ .exclusive = true, .permissions = .fromMode(0o600) });
        probe_file.close(self.io);
        try dir.deleteFile(self.io, probe);
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, c, .{ .whitespace = .indent_2 });
        defer self.allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(Config, self.allocator, bytes, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        try self.root.createDirPath(self.io, ".zigfs/config");
        var atomic = try self.root.createFileAtomic(self.io, config_path, .{ .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.setPermissions(self.io, .fromMode(0o600));
        try atomic.file.writeStreamingAll(self.io, bytes);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
        try durable.syncParent(self.root, self.io, config_path);
        if (self.active_file) |file| file.close(self.io);
        self.active_file = null;
        self.active_bytes = 0;
        if (self.parsed) |p| p.deinit();
        self.parsed = parsed;
        self.last_cleanup = 0;
    }
    fn rank(level: []const u8) u8 {
        if (std.mem.eql(u8, level, "off")) return 5;
        if (std.mem.eql(u8, level, "error")) return 4;
        if (std.mem.eql(u8, level, "warn")) return 3;
        if (std.mem.eql(u8, level, "info")) return 2;
        if (std.mem.eql(u8, level, "debug")) return 1;
        return 0;
    }
    pub fn emit(self: *Service, level: []const u8, scope: []const u8, message: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const c = self.config();
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        if (now - self.last_cleanup >= 60) {
            try self.cleanupLocked(now);
            self.last_cleanup = now;
        }
        if (rank(level) < rank(c.level)) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        // Bound each record and keep text logs on a single line.
        const bounded = message[0..@min(message.len, 32 * 1024)];
        const line = if (std.mem.eql(u8, c.format, "json")) blk: {
            const json = try std.json.Stringify.valueAlloc(a, .{ .timestamp = now, .level = level, .scope = scope, .message = bounded }, .{});
            break :blk try std.fmt.allocPrint(a, "{s}\n", .{json});
        } else blk: {
            const clean = try a.dupe(u8, bounded);
            for (clean) |*ch| if (ch.* == '\n' or ch.* == '\r') {
                ch.* = ' ';
            };
            break :blk try std.fmt.allocPrint(a, "{d} {s} [{s}] {s}\n", .{ now, level, scope, clean });
        };
        if (!std.mem.eql(u8, c.output, "file")) try std.Io.File.stderr().writeStreamingAll(self.io, line);
        if (std.mem.eql(u8, c.output, "console")) return;
        const limit = try maxBytes(c);
        if (self.active_file != null and self.active_bytes > 0 and self.active_bytes + line.len > limit) {
            self.active_file.?.close(self.io);
            self.active_file = null;
            self.active_bytes = 0;
        }
        if (self.active_file == null) {
            var dir = try self.directory(c.directory, true);
            defer dir.close(self.io);
            const id = try @import("../common/id.zig").randomV4(self.io);
            const name = try std.fmt.allocPrint(a, "zigfs-{d}-{s}.log", .{ now, std.fmt.bytesToHex(id, .lower) });
            self.active_file = try dir.createFile(self.io, name, .{ .exclusive = true, .permissions = .fromMode(0o600) });
        }
        try self.active_file.?.writeStreamingAll(self.io, line);
        self.active_bytes += line.len;
    }
    fn segmentTime(name: []const u8) ?i64 {
        if (!std.mem.startsWith(u8, name, "zigfs-") or !std.mem.endsWith(u8, name, ".log")) return null;
        const end = std.mem.indexOfScalarPos(u8, name, 6, '-') orelse return null;
        if (name.len != end + 1 + 32 + 4) return null;
        for (name[end + 1 .. name.len - 4]) |ch| if (!std.ascii.isHex(ch)) return null;
        return std.fmt.parseInt(i64, name[6..end], 10) catch null;
    }
    pub fn maintain(self: *Service) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.cleanupLocked(std.Io.Clock.real.now(self.io).toSeconds());
    }
    fn cleanupLocked(self: *Service, now: i64) !void {
        const c = self.config();
        if (!std.mem.eql(u8, c.cleanup, "enabled") or std.mem.eql(u8, c.retention, "forever")) return;
        var dir = self.directory(c.directory, false) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer dir.close(self.io);
        const cutoff = now - (try std.fmt.parseInt(i64, c.retention, 10)) * 86400;
        var iter = dir.iterate();
        while (try iter.next(self.io)) |entry| {
            if (entry.kind != .file or segmentTime(entry.name) == null) continue;
            const stat = try dir.statFile(self.io, entry.name, .{ .follow_symlinks = false });
            if (stat.mtime.toSeconds() >= cutoff) continue;
            // A quiet active file may also expire; close before unlinking it.
            if (self.active_file) |current_file| {
                const active_stat = try current_file.stat(self.io);
                if (active_stat.inode == stat.inode) {
                    current_file.close(self.io);
                    self.active_file = null;
                    self.active_bytes = 0;
                }
            }
            try dir.deleteFile(self.io, entry.name);
        }
    }
    pub const Query = struct { content: []const u8, truncated: bool, range: []const u8 };
    pub fn query(self: *Service, a: std.mem.Allocator, download: bool) !Query {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const c = self.config();
        if (download and !std.mem.eql(u8, c.downloads, "enabled")) return error.LogDownloadsDisabled;
        const seconds: i64 = if (std.mem.eql(u8, c.range, "1h")) 3600 else if (std.mem.eql(u8, c.range, "24h")) 86400 else if (std.mem.eql(u8, c.range, "7d")) 7 * 86400 else 30 * 86400;
        const cutoff = std.Io.Clock.real.now(self.io).toSeconds() - seconds;
        var dir = self.directory(c.directory, false) catch |err| {
            if (err == error.FileNotFound) return .{ .content = "", .truncated = false, .range = try a.dupe(u8, c.range) };
            return err;
        };
        defer dir.close(self.io);
        var names: std.ArrayList([]const u8) = .empty;
        var iter = dir.iterate();
        var truncated = false;
        while (try iter.next(self.io)) |entry| {
            if (entry.kind != .file or segmentTime(entry.name) == null) continue;
            const stat = try dir.statFile(self.io, entry.name, .{ .follow_symlinks = false });
            if (stat.mtime.toSeconds() < cutoff) continue;
            if (names.items.len == 1024) {
                truncated = true;
                break;
            }
            try names.append(a, try a.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, l: []const u8, r: []const u8) bool {
                return std.mem.order(u8, l, r) == .gt;
            }
        }.less);
        var result: std.ArrayList(u8) = .empty;
        const budget = 1024 * 1024;
        var scanned: usize = 0;
        for (names.items) |name| {
            var file = try dir.openFile(self.io, name, .{ .follow_symlinks = false });
            defer file.close(self.io);
            const stat = try file.stat(self.io);
            if (stat.size == 0) continue;
            const n: usize = @intCast(@min(stat.size, budget - scanned));
            if (n == 0) {
                truncated = true;
                break;
            }
            const buffer = try a.alloc(u8, n);
            const offset = stat.size - n;
            const read = try file.readPositionalAll(self.io, buffer, offset);
            scanned += read;
            if (offset > 0) truncated = true;
            var lines = std.mem.splitScalar(u8, buffer[0..read], '\n');
            if (offset > 0) _ = lines.next();
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                const timestamp = if (line[0] == '{') blk: {
                    const parsed = std.json.parseFromSlice(std.json.Value, a, line, .{}) catch continue;
                    if (parsed.value != .object) continue;
                    const value = parsed.value.object.get("timestamp") orelse continue;
                    if (value != .integer) continue;
                    break :blk value.integer;
                } else std.fmt.parseInt(i64, line[0 .. std.mem.indexOfScalar(u8, line, ' ') orelse continue], 10) catch continue;
                if (timestamp < cutoff) continue;
                try result.appendSlice(a, line);
                try result.append(a, '\n');
            }
        }
        return .{ .content = try result.toOwnedSlice(a), .truncated = truncated, .range = try a.dupe(u8, c.range) };
    }
};

pub var active: ?*Service = null;
pub fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    const service = active orelse return std.log.defaultLog(level, scope, format, args);
    const message = std.fmt.allocPrint(service.allocator, format, args) catch return;
    defer service.allocator.free(message);
    service.emit(if (level == .err) "error" else @tagName(level), @tagName(scope), message) catch {
        // Avoid recursive logging and never silently lose a file-write error.
        std.log.defaultLog(.err, .default, "Configured log output failed", .{});
    };
}

test "log configuration validates confinement and file sizes" {
    try validate(.{});
    try std.testing.expectEqual(@as(u64, 1280), try maxBytes(.{ .maxSize = "1.25", .sizeUnit = "KiB" }));
    for ([_][]const u8{ "../logs", "/tmp/logs", "a/../b", ".zigfs/logs", "a//b" }) |path| try std.testing.expectError(error.InvalidLogDirectory, validate(.{ .directory = path }));
    try std.testing.expectError(error.InvalidLogConfig, validate(.{ .maxSize = "nan" }));
}

test "log settings persist, filter, rotate and gate downloads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service: Service = .{ .root = tmp.dir, .io = std.testing.io, .allocator = std.testing.allocator };
    defer service.deinit();
    try service.init();
    try service.save(.{ .output = "file", .maxSize = "0.1", .sizeUnit = "KiB", .directory = "nested/logs" });
    try service.emit("debug", "test", "filtered");
    try service.emit("info", "test", "first");
    try service.emit("error", "test", "second");
    // An empty segment must not stop scanning older, populated segments.
    const empty = try tmp.dir.createFile(std.testing.io, "nested/logs/zigfs-9999999999-ffffffffffffffffffffffffffffffff.log", .{});
    empty.close(std.testing.io);
    const query = try service.query(a, false);
    try std.testing.expect(!query.truncated);
    try std.testing.expect(std.mem.indexOf(u8, query.content, "filtered") == null);
    try std.testing.expect(std.mem.indexOf(u8, query.content, "first") != null);
    try std.testing.expect(std.mem.indexOf(u8, query.content, "second") != null);
    var dir = try tmp.dir.openDir(std.testing.io, "nested/logs", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(std.testing.io)) |_| {
        count += 1;
    }
    try std.testing.expect(count >= 2);
    try service.save(.{ .output = "file", .level = "off", .downloads = "disabled", .retention = "forever" });
    try service.emit("error", "test", "suppressed");
    try std.testing.expectError(error.LogDownloadsDisabled, service.query(a, true));
    var restored: Service = .{ .root = tmp.dir, .io = std.testing.io, .allocator = std.testing.allocator };
    defer restored.deinit();
    try restored.init();
    const saved = try restored.snapshot(a);
    defer saved.deinit();
    try std.testing.expectEqualStrings("off", saved.value.level);
    try std.testing.expectEqualStrings("forever", saved.value.retention);
    try std.testing.expectEqualStrings("disabled", saved.value.downloads);
}
