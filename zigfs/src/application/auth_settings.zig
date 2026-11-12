const std = @import("std");
const Config = @import("../config.zig").Config;

pub const Settings = struct {
    admin_session_ttl_seconds: u64,
    request_time_skew_seconds: u64,

    pub fn fromConfig(config: Config) Settings {
        return .{ .admin_session_ttl_seconds = config.admin_session_ttl_seconds, .request_time_skew_seconds = config.s3_request_time_skew_seconds };
    }
    pub fn validate(self: Settings) !void {
        if (self.admin_session_ttl_seconds < 60 or self.admin_session_ttl_seconds > 86400) return error.InvalidSessionLifetime;
        if (self.request_time_skew_seconds < 60 or self.request_time_skew_seconds > 3600) return error.InvalidSignatureClockSkew;
    }
    pub fn eql(self: Settings, other: Settings) bool {
        return self.admin_session_ttl_seconds == other.admin_session_ttl_seconds and self.request_time_skew_seconds == other.request_time_skew_seconds;
    }
    pub fn apply(self: Settings, config: *Config) void {
        config.admin_session_ttl_seconds = self.admin_session_ttl_seconds;
        config.s3_request_time_skew_seconds = self.request_time_skew_seconds;
    }
};
const path = ".zigfs/config/authentication.json";

// Caller owns an arena. Management writes are serialized by policy_mutex.
pub fn load(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, fallback: Settings) !Settings {
    const bytes = root.readFileAlloc(io, path, a, .limited(1024)) catch |err| switch (err) {
        error.FileNotFound => return fallback,
        else => return err,
    };
    const parsed = try std.json.parseFromSlice(Settings, a, bytes, .{});
    try parsed.value.validate();
    return parsed.value;
}
pub fn save(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, value: Settings) !void {
    try value.validate();
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    try root.createDirPath(io, ".zigfs/config");
    var file = try root.createFileAtomic(io, path, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, bytes);
    try file.file.sync(io);
    try file.replace(io);
    try @import("../metadata/durable.zig").syncParent(root, io, path);
}
test "authentication settings validate bounds and persist atomically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const defaults = Settings.fromConfig(.{});
    try std.testing.expect(defaults.eql(try load(a, tmp.dir, std.testing.io, defaults)));
    const value: Settings = .{ .admin_session_ttl_seconds = 3600, .request_time_skew_seconds = 60 };
    try save(a, tmp.dir, std.testing.io, value);
    for ([_]u64{ 0, 59, 86401, std.math.maxInt(u64) }) |bad| {
        try std.testing.expectError(error.InvalidSessionLifetime, save(a, tmp.dir, std.testing.io, .{ .admin_session_ttl_seconds = bad, .request_time_skew_seconds = 60 }));
    }
    for ([_]u64{ 0, 59, 3601, std.math.maxInt(u64) }) |bad| {
        try std.testing.expectError(error.InvalidSignatureClockSkew, save(a, tmp.dir, std.testing.io, .{ .admin_session_ttl_seconds = 60, .request_time_skew_seconds = bad }));
    }
    try std.testing.expect(value.eql(try load(a, tmp.dir, std.testing.io, defaults)));
    try (Settings{ .admin_session_ttl_seconds = 60, .request_time_skew_seconds = 60 }).validate();
    try (Settings{ .admin_session_ttl_seconds = 86400, .request_time_skew_seconds = 3600 }).validate();
    var config: Config = .{};
    value.apply(&config);
    try std.testing.expect(value.eql(Settings.fromConfig(config)));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = "{}" });
    try std.testing.expectError(error.MissingField, load(a, tmp.dir, std.testing.io, defaults));
}
