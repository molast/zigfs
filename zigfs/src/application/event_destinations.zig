const std = @import("std");
const box = @import("../auth/secret_box.zig");
const durable = @import("../metadata/durable.zig");

pub const Destination = struct {
    name: []const u8,
    generation_id: []const u8 = "",
    type: []const u8 = "webhook",
    endpoint: []const u8 = "",
    auth_token: []const u8 = "",
    has_auth_token: bool = false,
    queue_limit: u32 = 100000,
    queue_directory: []const u8 = "",
    client_certificate: []const u8 = "",
    client_key: []const u8 = "",
    client_ca: []const u8 = "",
    skip_tls_verify: bool = false,
    comment: []const u8 = "",
    broker: []const u8 = "",
    topic: []const u8 = "",
    qos: u8 = 0,
    username: []const u8 = "",
    password: []const u8 = "",
    has_password: bool = false,
    reconnect_interval: []const u8 = "5s",
    keep_alive_interval: []const u8 = "15s",
    tls_policy: []const u8 = "",
    tls_ca: []const u8 = "",
    tls_client_certificate: []const u8 = "",
    tls_client_key: []const u8 = "",
    trust_leaf_as_ca: bool = false,
    websocket_path_allowlist: []const u8 = "",

    pub fn redacted(self: Destination) Destination {
        var result = self;
        result.has_auth_token = self.auth_token.len > 0;
        result.auth_token = "";
        result.has_password = self.password.len > 0;
        result.password = "";
        return result;
    }
};
pub const Snapshot = struct { version: u32 = 1, items: []const Destination = &.{} };
pub const path = ".zigfs/config/event-destinations.enc";

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name) |c| if (!std.ascii.isUpper(c) and !std.ascii.isDigit(c) and c != '_') return false;
    return true;
}
fn validText(value: []const u8, max: usize) bool {
    if (value.len > max or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |c| if (c < 32 or c == 127) return false;
    return true;
}
fn validPath(value: []const u8) bool {
    if (!validText(value, 1024) or std.mem.startsWith(u8, value, "/") or std.mem.indexOfScalar(u8, value, '\\') != null or std.mem.indexOfScalar(u8, value, ':') != null) return false;
    var segments = std.mem.splitScalar(u8, value, '/');
    while (segments.next()) |part| if (std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return false;
    return true;
}
fn validDuration(value: []const u8, allow_zero: bool) bool {
    if (value.len < 2 or value.len > 32) return false;
    var digits: usize = 0;
    while (digits < value.len and std.ascii.isDigit(value[digits])) : (digits += 1) {}
    if (digits == 0) return false;
    const number = std.fmt.parseInt(u32, value[0..digits], 10) catch return false;
    if (!allow_zero and number == 0) return false;
    const unit = value[digits..];
    return std.mem.eql(u8, unit, "ms") or std.mem.eql(u8, unit, "s") or std.mem.eql(u8, unit, "m") or std.mem.eql(u8, unit, "h");
}
pub fn validate(value: Destination) !void {
    if (!validName(value.name)) return error.InvalidDestinationName;
    if (std.mem.eql(u8, value.type, "webhook")) {
        if (!validText(value.endpoint, 4096) or std.mem.indexOfAny(u8, value.endpoint, " \\") != null) return error.InvalidWebhookEndpoint;
        const uri = std.Uri.parse(value.endpoint) catch return error.InvalidWebhookEndpoint;
        if ((!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) or uri.host == null or uri.host.?.isEmpty() or uri.user != null or uri.password != null or uri.fragment != null) return error.InvalidWebhookEndpoint;
        if (!validText(value.auth_token, 4096)) return error.InvalidWebhookAuthToken;
        for ([_][]const u8{ value.client_certificate, value.client_key, value.client_ca }) |p| if (!validPath(p)) return error.InvalidWebhookPath;
        if ((value.client_certificate.len == 0) != (value.client_key.len == 0)) return error.InvalidWebhookClientCertificate;
    } else if (std.mem.eql(u8, value.type, "mqtt")) {
        if (!validText(value.broker, 4096) or std.mem.indexOfAny(u8, value.broker, " \\") != null) return error.InvalidMqttBroker;
        const uri = std.Uri.parse(value.broker) catch return error.InvalidMqttBroker;
        var scheme_ok = false;
        for ([_][]const u8{ "tcp", "tls", "ssl", "mqtt", "mqtts", "ws", "wss" }) |scheme| if (std.mem.eql(u8, uri.scheme, scheme)) {
            scheme_ok = true;
        };
        if (!scheme_ok or uri.host == null or uri.host.?.isEmpty() or uri.user != null or uri.password != null or uri.fragment != null) return error.InvalidMqttBroker;
        if (value.topic.len == 0 or !validText(value.topic, 1024) or std.mem.indexOfAny(u8, value.topic, "+#") != null) return error.InvalidMqttTopic;
        if (value.qos > 2) return error.InvalidMqttQos;
        if (!validText(value.username, 1024) or !validText(value.password, 4096)) return error.InvalidMqttCredentials;
        if (!validDuration(value.reconnect_interval, false) or !validDuration(value.keep_alive_interval, true)) return error.InvalidMqttInterval;
        if (!validText(value.tls_policy, 64)) return error.InvalidMqttTlsPolicy;
        for ([_][]const u8{ value.tls_ca, value.tls_client_certificate, value.tls_client_key }) |p| if (!validPath(p)) return error.InvalidMqttPath;
        if ((value.tls_client_certificate.len == 0) != (value.tls_client_key.len == 0)) return error.InvalidMqttClientCertificate;
        if (!validText(value.websocket_path_allowlist, 4096)) return error.InvalidMqttWebSocketPaths;
        if (value.websocket_path_allowlist.len > 0) {
            var paths = std.mem.splitScalar(u8, value.websocket_path_allowlist, ',');
            while (paths.next()) |entry| {
                const entry_path = std.mem.trim(u8, entry, " ");
                if (!std.mem.startsWith(u8, entry_path, "/") or std.mem.indexOfAny(u8, entry_path, " ?#\\") != null) return error.InvalidMqttWebSocketPaths;
            }
        }
    } else return error.InvalidDestinationType;
    if (value.queue_limit == 0) return error.InvalidWebhookQueueLimit;
    if (!validPath(value.queue_directory)) return error.InvalidWebhookPath;
    if (!validText(value.comment, 1024)) return error.InvalidDestinationComment;
}
fn validateSnapshot(snapshot: Snapshot) !void {
    if (snapshot.version != 1 or snapshot.items.len > 100) return error.DestinationLimit;
    for (snapshot.items, 0..) |item, i| {
        try validate(item);
        for (snapshot.items[0..i]) |previous| if (std.mem.eql(u8, item.name, previous.name)) return error.DestinationExists;
    }
}
// Caller serializes configuration mutations with policy_mutex.
pub fn load(root: std.Io.Dir, io: std.Io, a: std.mem.Allocator, key: box.Key) !std.json.Parsed(Snapshot) {
    const data = root.readFileAlloc(io, path, a, .limited(2 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return std.json.parseFromSlice(Snapshot, a, "{}", .{}),
        else => return err,
    };
    defer a.free(data);
    if (data.len < 28) return error.InvalidDestinationStorage;
    const plain = try box.open(a, key, path, data[0..12].*, data[12..28].*, data[28..]);
    defer {
        std.crypto.secureZero(u8, plain);
        a.free(plain);
    }
    const parsed = try std.json.parseFromSlice(Snapshot, a, plain, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try validateSnapshot(parsed.value);
    return parsed;
}
pub fn save(root: std.Io.Dir, io: std.Io, a: std.mem.Allocator, key: box.Key, snapshot: Snapshot) !void {
    try validateSnapshot(snapshot);
    const plain = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer {
        std.crypto.secureZero(u8, plain);
        a.free(plain);
    }
    if (plain.len > 2 * 1024 * 1024 - 28) return error.DestinationLimit;
    const sealed = try box.seal(a, io, key, path, plain);
    defer sealed.deinit(a);
    try root.createDirPath(io, ".zigfs/config");
    var atomic = try root.createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, &sealed.nonce);
    try atomic.file.writeStreamingAll(io, &sealed.tag);
    try atomic.file.writeStreamingAll(io, sealed.ciphertext);
    try atomic.file.sync(io);
    try atomic.replace(io);
    try durable.syncParent(root, io, path);
}

test "webhook configuration survives reload with encrypted token and rejects invalid replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const key: box.Key = @splat(42);
    const item: Destination = .{ .name = "WEBHOOK_1", .endpoint = "https://example.test/events", .auth_token = "test-token-never-return" };
    try save(tmp.dir, io, a, key, .{ .items = &.{item} });
    const bytes = try tmp.dir.readFileAlloc(io, path, a, .limited(4096));
    defer a.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, item.auth_token) == null);
    const loaded = try load(tmp.dir, io, a, key);
    defer loaded.deinit();
    try std.testing.expectEqualStrings(item.auth_token, loaded.value.items[0].auth_token);
    try std.testing.expectEqualStrings("", loaded.value.items[0].redacted().auth_token);
    try std.testing.expect(loaded.value.items[0].redacted().has_auth_token);
    var invalid = item;
    invalid.endpoint = "ws://example.test/events";
    try std.testing.expectError(error.InvalidWebhookEndpoint, save(tmp.dir, io, a, key, .{ .items = &.{invalid} }));
    const preserved = try load(tmp.dir, io, a, key);
    defer preserved.deinit();
    try std.testing.expectEqualStrings(item.endpoint, preserved.value.items[0].endpoint);
    try save(tmp.dir, io, a, key, .{});
    const empty = try load(tmp.dir, io, a, key);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.value.items.len);
}
test "webhook configuration rejects traversal, credentials in URL and partial TLS configuration" {
    var item: Destination = .{ .name = "TEST", .endpoint = "https://example.test" };
    item.queue_directory = "../outside";
    try std.testing.expectError(error.InvalidWebhookPath, validate(item));
    item.queue_directory = "events/TEST";
    item.client_certificate = "certs/client.pem";
    try std.testing.expectError(error.InvalidWebhookClientCertificate, validate(item));
    item.client_key = "certs/client.key";
    try validate(item);
    item.endpoint = "https://user:password@example.test";
    try std.testing.expectError(error.InvalidWebhookEndpoint, validate(item));
}

test "MQTT configuration encrypts and redacts password while preserving webhook settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const key: box.Key = @splat(9);
    const mqtt: Destination = .{ .name = "MQTT_1", .type = "mqtt", .broker = "tcp://localhost:1883", .topic = "bucket/events", .qos = 2, .username = "test", .password = "mqtt-secret-test", .websocket_path_allowlist = "/mqtt,/ws" };
    const webhook: Destination = .{ .name = "WEBHOOK_1", .endpoint = "https://example.test/events" };
    try save(tmp.dir, io, a, key, .{ .items = &.{ mqtt, webhook } });
    const loaded = try load(tmp.dir, io, a, key);
    defer loaded.deinit();
    try std.testing.expectEqualStrings(mqtt.password, loaded.value.items[0].password);
    try std.testing.expectEqualStrings("", loaded.value.items[0].redacted().password);
    try std.testing.expect(loaded.value.items[0].redacted().has_password);
    try std.testing.expectEqualStrings(webhook.endpoint, loaded.value.items[1].endpoint);
    const bytes = try tmp.dir.readFileAlloc(io, path, a, .limited(16384));
    defer a.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, mqtt.password) == null);
    var invalid = mqtt;
    invalid.qos = 3;
    try std.testing.expectError(error.InvalidMqttQos, validate(invalid));
    invalid = mqtt;
    invalid.topic = "bucket/#";
    try std.testing.expectError(error.InvalidMqttTopic, validate(invalid));
    invalid = mqtt;
    invalid.tls_ca = "../ca.pem";
    try std.testing.expectError(error.InvalidMqttPath, validate(invalid));
    invalid = mqtt;
    invalid.reconnect_interval = "0s";
    try std.testing.expectError(error.InvalidMqttInterval, validate(invalid));
    invalid = mqtt;
    invalid.websocket_path_allowlist = "/mqtt,https://example.test";
    try std.testing.expectError(error.InvalidMqttWebSocketPaths, validate(invalid));
}
