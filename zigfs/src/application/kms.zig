const std = @import("std");
const box = @import("../auth/secret_box.zig");
const encryption = @import("object_encryption.zig");
const durable = @import("../metadata/durable.zig");
const id = @import("../common/id.zig");

// Configuration names intentionally match the Admin form contract.
pub const Config = struct {
    backend: []const u8 = "vault",
    defaultKey: []const u8 = "",
    staticSecretKey: []const u8 = "",
    localKeyDirectory: []const u8 = "",
    filePermissions: []const u8 = "384",
    localCacheEnabled: bool = false,
    address: []const u8 = "",
    token: []const u8 = "",
    namespace: []const u8 = "",
    mountPath: []const u8 = "transit",
    kvMount: []const u8 = "secret",
    keyPathPrefix: []const u8 = "zigfs/kms/keys",
    skipTlsVerification: bool = false,
    caCertificatePath: []const u8 = "",
    clientCertificatePath: []const u8 = "",
    clientKeyPath: []const u8 = "",
    timeoutSeconds: []const u8 = "30",
    retryCount: []const u8 = "3",
    cacheEnabled: bool = true,
    cacheTtlSeconds: []const u8 = "3600",
    cacheCapacity: []const u8 = "1000",
};
pub const Envelope = @import("../domain/kms.zig").Envelope;
pub const Status = struct { configured: bool, healthy: bool = false, healthChecked: bool = false, state: []const u8 = "unconfigured", errorMessage: []const u8 = "", config: Config, tokenConfigured: bool = false, staticSecretKeyConfigured: bool = false };
const config_dir = ".zigfs/config/kms_config.json";
pub const current_path = config_dir ++ "/xl.meta";
const config_file = @import("kms_config_file.zig");
const probe_key_id = "zigfs-internal-kms-probe";
const EncryptedConfig = struct { version: u8 = 1, nonce: box.Nonce, tag: box.Tag, ciphertext: []const u8 };
const LegacyLocalKey = struct { version: u8 = 1, key: []const u8 };
pub const LocalKeyVersion = struct { version: u64, encrypted_key_material: []const u8 };
pub const LocalKey = struct {
    name: []const u8 = "",
    previous_versions: []const LocalKeyVersion = &.{},
    format_version: u8 = 1,
    key_id: []const u8,
    version: u32 = 1,
    algorithm: []const u8 = "AES_256",
    usage: []const u8 = "EncryptDecrypt",
    status: []const u8 = "Enabled",
    description: []const u8 = "",
    metadata: struct {} = .{},
    created_at: []const u8,
    rotated_at: ?[]const u8 = null,
    created_by: []const u8 = "local-kms",
    deletion_date: ?[]const u8 = null,
    encrypted_key_material: []const u8,
    nonce: []const u16 = &.{}, // Always a JSON array; empty in plaintext development mode.
    at_rest_protection: []const u8 = "plaintext-dev-only",
};
const Profile = struct { profile: []const u8, config: Config };
const Stored = struct { enabled: bool = false, profile: []const u8, config: Config, history: []const Profile = &.{}, key_metadata: []const @import("kms_keys.zig").ManagedKey = &.{} };
const CacheEntry = struct { key: box.Key, expires: i64, version: u64 = 0 };
pub const Service = struct {
    root: std.Io.Dir,
    io: std.Io,
    master: box.Key,
    allow_insecure_dev_defaults: bool = false,
    health: ?bool = null,
    last_error: ?anyerror = null,
    mutex: std.Io.Mutex = .init,
    cache: std.StringHashMapUnmanaged(CacheEntry) = .empty,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Service) void {
        self.clearCache();
        std.crypto.secureZero(u8, &self.master);
    }
    fn clearCache(self: *Service) void {
        var entries = self.cache.iterator();
        while (entries.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            std.crypto.secureZero(u8, &entry.value_ptr.key);
        }
        self.cache.deinit(self.allocator);
        self.cache = .empty;
    }
    fn read(self: *Service, a: std.mem.Allocator, path: []const u8) ![]u8 {
        const bytes = try self.root.readFileAlloc(self.io, path, a, .limited(128 * 1024 + 44));
        defer a.free(bytes);
        if (std.mem.startsWith(u8, path, config_dir ++ "/")) {
            const payload = if (std.mem.endsWith(u8, path, "/xl.meta")) try config_file.decode(bytes) else bytes;
            if (std.mem.endsWith(u8, path, "/xl.meta") and std.mem.readInt(u16, bytes[6..8], .little) == 2) {
                if (payload.len < 28) return error.InvalidKmsStore;
                return box.open(a, self.master, path, payload[0..12].*, payload[12..28].*, payload[28..]);
            }
            const parsed = try std.json.parseFromSlice(EncryptedConfig, a, payload, .{});
            defer parsed.deinit();
            if (parsed.value.version != 1) return error.InvalidKmsStore;
            const ciphertext = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(parsed.value.ciphertext));
            defer a.free(ciphertext);
            try std.base64.standard.Decoder.decode(ciphertext, parsed.value.ciphertext);
            return box.open(a, self.master, path, parsed.value.nonce, parsed.value.tag, ciphertext);
        }
        if (bytes.len < 28) return error.InvalidKmsStore;
        return box.open(a, self.master, path, bytes[0..12].*, bytes[12..28].*, bytes[28..]);
    }
    pub fn write(self: *Service, a: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
        const sealed = try box.seal(a, self.io, self.master, path, bytes);
        defer sealed.deinit(a);
        var atomic = try self.root.createFileAtomic(self.io, path, .{ .replace = true });
        defer atomic.deinit(self.io);
        const encoded = try std.mem.concat(a, u8, &.{ &sealed.nonce, &sealed.tag, sealed.ciphertext });
        defer a.free(encoded);
        try atomic.file.writeStreamingAll(self.io, try config_file.encode(a, encoded));
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
        try durable.syncParent(self.root, self.io, path);
    }
    pub fn current(self: *Service, a: std.mem.Allocator) !Stored {
        const bytes = self.read(a, current_path) catch |err| switch (err) {
            error.FileNotFound => self.read(a, config_dir ++ "/current.json") catch |old_err| switch (old_err) {
                error.FileNotFound => try self.read(a, ".zigfs/kms/current"),
                else => return old_err,
            },
            else => return err,
        };
        return (try std.json.parseFromSlice(Stored, a, bytes, .{ .allocate = .alloc_always })).value;
    }
    fn readProfile(self: *Service, a: std.mem.Allocator, profile: [32]u8) ![]u8 {
        const stored = try self.current(a);
        if (std.mem.eql(u8, stored.profile, &profile)) return std.json.Stringify.valueAlloc(a, stored.config, .{});
        for (stored.history) |entry| {
            if (std.mem.eql(u8, entry.profile, &profile)) return std.json.Stringify.valueAlloc(a, entry.config, .{});
        }
        const path = try std.fmt.allocPrint(a, config_dir ++ "/profiles/{s}/xl.meta", .{profile});
        return self.read(a, path) catch |err| switch (err) {
            error.FileNotFound => self.read(a, try std.fmt.allocPrint(a, config_dir ++ "/profiles/{s}.json", .{profile})) catch |old_err| switch (old_err) {
                error.FileNotFound => self.read(a, try std.fmt.allocPrint(a, ".zigfs/kms/profiles/{s}", .{profile})),
                else => return old_err,
            },
            else => return err,
        };
    }
    pub fn localDirectory(self: *Service, path: []const u8, create: bool) !std.Io.Dir {
        if (try dataRelativePath(path)) |relative_path| {
            var dir = try self.root.openDir(self.io, ".", .{});
            errdefer dir.close(self.io);
            var parts = std.mem.tokenizeScalar(u8, relative_path, '/');
            while (parts.next()) |part| {
                if (create) dir.createDir(self.io, part, .fromMode(0o700)) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
                const next = try dir.openDir(self.io, part, .{ .follow_symlinks = false });
                dir.close(self.io);
                dir = next;
            }
            return dir;
        }
        if (create) try std.Io.Dir.cwd().createDirPath(self.io, path);
        return std.Io.Dir.cwd().openDir(self.io, path, .{});
    }
    pub fn localKey(self: *Service, a: std.mem.Allocator, config: Config, name: []const u8, create: bool) !box.Key {
        return self.localKeyVersion(a, config, name, create, null, null);
    }
    fn localKeyVersion(self: *Service, a: std.mem.Allocator, config: Config, name: []const u8, create: bool, requested_version: ?u64, actual_version: ?*u64) !box.Key {
        var dir = try self.localDirectory(config.localKeyDirectory, create);
        defer dir.close(self.io);
        const path = try std.fmt.allocPrint(a, "{s}.key", .{name});
        const bytes = dir.readFileAlloc(self.io, path, a, .limited(128 * 1024)) catch |err| blk: {
            if (err != error.FileNotFound) return err;
            // Preserve earlier JSON key files without generating replacement material.
            const legacy_path = try std.fmt.allocPrint(a, "{s}.json", .{name});
            if (dir.readFileAlloc(self.io, legacy_path, a, .limited(128 * 1024))) |legacy| {
                const parsed = try std.json.parseFromSlice(LegacyLocalKey, a, legacy, .{});
                defer std.crypto.secureZero(u8, legacy);
                if (parsed.value.version != 1) return error.InvalidKmsStore;
                if (actual_version) |out| out.* = 1;
                if (requested_version != null and requested_version.? != 1) return error.InvalidKmsStore;
                return decodeKey(parsed.value.key);
            } else |legacy_err| if (legacy_err != error.FileNotFound) return legacy_err;
            if (!create) return error.FileNotFound;
            var generated: box.Key = undefined;
            try self.io.randomSecure(&generated);
            defer std.crypto.secureZero(u8, &generated);
            var time_buffer: [20]u8 = undefined;
            const created_at = try @import("../common/time.zig").formatIso8601(std.Io.Clock.real.now(self.io).toSeconds(), &time_buffer);
            const encoded = try std.json.Stringify.valueAlloc(a, LocalKey{ .key_id = name, .created_at = created_at, .encrypted_key_material = try base64(a, &generated), .description = if (std.mem.eql(u8, name, probe_key_id)) "ZigFS KMS health probe key; also available for explicit SSE-KMS selection" else "" }, .{ .whitespace = .indent_2 });
            const permissions = try std.fmt.parseInt(u32, config.filePermissions, 10);
            var file = dir.createFile(self.io, path, .{ .exclusive = true, .permissions = .fromMode(@intCast(permissions)) }) catch |create_err| {
                if (create_err == error.PathAlreadyExists) break :blk try dir.readFileAlloc(self.io, path, a, .limited(128 * 1024));
                return create_err;
            };
            defer file.close(self.io);
            try file.writeStreamingAll(self.io, encoded);
            try file.sync(self.io);
            try durable.syncParent(dir, self.io, path);
            break :blk encoded;
        };
        defer std.crypto.secureZero(u8, bytes);
        if (bytes.len == 32) {
            if (requested_version != null and requested_version.? != 1) return error.InvalidKmsStore;
            if (actual_version) |out| out.* = 1;
            return bytes[0..32].*;
        } // Legacy raw .key file
        const parsed = std.json.parseFromSlice(LocalKey, a, bytes, .{}) catch return error.InvalidKmsStore;
        defer parsed.deinit();
        const record = parsed.value;
        if (record.format_version != 1 or record.version == 0 or !std.mem.eql(u8, record.key_id, name) or !std.mem.eql(u8, record.algorithm, "AES_256") or !std.mem.eql(u8, record.usage, "EncryptDecrypt") or !std.mem.eql(u8, record.at_rest_protection, "plaintext-dev-only") or record.nonce.len != 0) return error.InvalidKmsStore;
        if (!std.mem.eql(u8, record.status, "Enabled") or record.deletion_date != null) return error.KmsLocalKeyDisabled;
        const version = requested_version orelse if (create) record.version else 1;
        if (actual_version) |out| out.* = version;
        if (version == record.version) return decodeKey(record.encrypted_key_material) catch return error.InvalidKmsStore;
        for (record.previous_versions) |old| if (old.version == version) return decodeKey(old.encrypted_key_material) catch return error.InvalidKmsStore;
        return error.InvalidKmsStore;
    }
    fn localProbe(self: *Service, a: std.mem.Allocator, config: Config) !void {
        var key = try self.localKey(a, config, probe_key_id, true);
        defer std.crypto.secureZero(u8, &key);
        var challenge: [32]u8 = undefined;
        try self.io.randomSecure(&challenge);
        const sealed = try box.seal(a, self.io, key, "ZIGFS-KMS-HEALTH", &challenge);
        const opened = try box.open(a, key, "ZIGFS-KMS-HEALTH", sealed.nonce, sealed.tag, sealed.ciphertext);
        defer std.crypto.secureZero(u8, opened);
        if (!std.mem.eql(u8, &challenge, opened)) return error.KmsKeyVerificationFailed;
    }
    pub fn status(self: *Service, a: std.mem.Allocator) !Status {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stored = self.current(a) catch |err| switch (err) {
            error.FileNotFound => return .{ .configured = false, .config = .{} },
            else => return err,
        };
        const token = stored.config.token.len > 0;
        const secret = stored.config.staticSecretKey.len > 0;
        stored.config.token = "";
        stored.config.staticSecretKey = "";
        return .{ .configured = true, .state = if (self.last_error != null) "error" else if (self.health orelse false) "running" else "configured", .errorMessage = if (self.last_error) |err| try std.fmt.allocPrint(a, "Failed to start KMS backend ({s}): {s}", .{ stored.config.backend, saveErrorMessage(err) }) else "", .healthy = self.health orelse false, .healthChecked = self.health != null, .config = stored.config, .tokenConfigured = token, .staticSecretKeyConfigured = secret };
    }
    pub fn verify(self: *Service, a: std.mem.Allocator) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.setEnabled(a, true);
        try self.startLocked(a);
    }
    pub fn restore(self: *Service, a: std.mem.Allocator) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const stored = self.current(a) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        if (stored.enabled) try self.startLocked(a);
    }
    fn setEnabled(self: *Service, a: std.mem.Allocator, enabled: bool) !void {
        var stored = try self.current(a);
        if (stored.enabled == enabled) return;
        stored.enabled = enabled;
        self.root.createDirPath(self.io, config_dir) catch return error.KmsPersistenceFailed;
        self.write(a, current_path, try std.json.Stringify.valueAlloc(a, stored, .{})) catch return error.KmsPersistenceFailed;
    }
    fn startLocked(self: *Service, a: std.mem.Allocator) !void {
        self.health = false;
        self.last_error = null;
        self.clearCache();
        self.verifyCurrent(a) catch |err| {
            self.last_error = err;
            return err;
        };
        self.health = true;
    }
    fn verifyCurrent(self: *Service, a: std.mem.Allocator) !void {
        const stored = try self.current(a);
        if (std.mem.eql(u8, stored.config.backend, "local")) self.localProbe(a, stored.config) catch |err| return saveVerificationError(stored.config, err);
        try self.check(a, stored);
    }
    pub fn stop(self: *Service, a: std.mem.Allocator) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.setEnabled(a, false);
        self.clearCache();
        self.health = null;
        self.last_error = null;
    }
    pub fn flushCache(self: *Service) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!(self.health orelse false)) return error.KmsNotRunning;
        self.clearCache();
    }
    pub fn listKeys(self: *Service, a: std.mem.Allocator) !@import("kms_keys.zig").KeyList {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!(self.health orelse false)) return error.KmsNotRunning;
        return @import("kms_keys.zig").list(self, a);
    }
    pub fn createKey(self: *Service, a: std.mem.Allocator, input: @import("kms_keys.zig").CreateKey) !@import("kms_keys.zig").KeyInfo {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!(self.health orelse false)) return error.KmsNotRunning;
        const result = try @import("kms_keys.zig").create(self, a, input);
        self.clearCache();
        return result;
    }
    pub fn keyAction(self: *Service, a: std.mem.Allocator, name: []const u8, action: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!(self.health orelse false)) return error.KmsNotRunning;
        try @import("kms_keys.zig").act(self, a, name, action);
        self.clearCache();
    }
    pub fn requireRunning(self: *Service) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!(self.health orelse false)) return error.KmsNotRunning;
    }
    fn check(self: *Service, a: std.mem.Allocator, stored: Stored) !void {
        if (stored.profile.len != 32) return error.InvalidKmsStore;
        if (std.mem.eql(u8, stored.config.backend, "local")) return;
        const name = if (stored.config.defaultKey.len == 0) "zigfs" else stored.config.defaultKey;
        try @import("kms_keys.zig").ensureEnabled(self, a, stored.config, name);
        if (!std.mem.eql(u8, stored.config.backend, "vault")) {
            var key_bytes = try self.loadKey(a, stored.config, stored.profile[0..32].*, name, false, null, null);
            std.crypto.secureZero(u8, &key_bytes);
            return;
        }
        var probe: box.Key = undefined;
        try self.io.randomSecure(&probe);
        defer std.crypto.secureZero(u8, &probe);
        const envelope = try self.wrapWith(a, stored.config, stored.profile[0..32].*, name, "ZIGFS-KMS-HEALTH", probe);
        var opened = try self.unwrapWith(a, stored.config, envelope, "ZIGFS-KMS-HEALTH");
        defer std.crypto.secureZero(u8, &opened);
        if (!std.crypto.timing_safe.eql(box.Key, opened, probe)) return error.KmsUnavailable;
    }
    pub fn save(self: *Service, a: std.mem.Allocator, input: Config) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var config = input;
        var history: []const Profile = &.{};
        var key_metadata: []const @import("kms_keys.zig").ManagedKey = &.{};
        if (self.current(a)) |old| {
            key_metadata = old.key_metadata;
            const entries = try a.alloc(Profile, old.history.len + 1);
            @memcpy(entries[0..old.history.len], old.history);
            entries[old.history.len] = .{ .profile = old.profile, .config = old.config };
            history = entries;
            if (std.mem.eql(u8, old.config.backend, config.backend)) {
                if (config.token.len == 0) config.token = old.config.token;
                if (config.staticSecretKey.len == 0) config.staticSecretKey = old.config.staticSecretKey;
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return error.KmsConfigurationReadFailed,
        }
        if (!std.mem.eql(u8, config.backend, "static")) config.staticSecretKey = "";
        if (std.mem.eql(u8, config.backend, "static") or std.mem.eql(u8, config.backend, "local")) config.token = "";
        try validate(config);
        if ((std.mem.eql(u8, config.backend, "vault") or std.mem.eql(u8, config.backend, "vault-kv2")) and
            !self.allow_insecure_dev_defaults and !std.mem.startsWith(u8, config.address, "https://")) return error.KmsVaultHttpsRequired;
        const profile = std.fmt.bytesToHex(try id.randomV4(self.io), .lower);
        self.root.createDirPath(self.io, config_dir) catch return error.KmsPersistenceFailed;
        const bytes = try std.json.Stringify.valueAlloc(a, Stored{ .profile = &profile, .config = config, .history = history, .key_metadata = key_metadata }, .{});
        self.write(a, current_path, bytes) catch return error.KmsPersistenceFailed;
        self.health = null;
        self.last_error = null;
        self.clearCache();
    }
    pub fn wrap(self: *Service, a: std.mem.Allocator, requested: []const u8, ad: []const u8, dek: box.Key) !Envelope {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!(self.health orelse false)) return error.KmsNotRunning;
        const stored = try self.current(a);
        const name = if (requested.len > 0) requested else if (stored.config.defaultKey.len > 0) stored.config.defaultKey else "zigfs";
        if (!validKey(name) or stored.profile.len != 32) return error.InvalidKmsConfig;
        return self.wrapWith(a, stored.config, stored.profile[0..32].*, name, ad, dek);
    }
    pub fn select(self: *Service, a: std.mem.Allocator, requested: []const u8) !Envelope {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!(self.health orelse false)) return error.KmsNotRunning;
        const stored = try self.current(a);
        const name = if (requested.len > 0) requested else if (stored.config.defaultKey.len > 0) stored.config.defaultKey else "zigfs";
        if (!validKey(name) or stored.profile.len != 32) return error.InvalidKmsConfig;
        var selection: Envelope = .{ .profile = stored.profile[0..32].*, .key_len = @intCast(name.len) };
        @memcpy(selection.key_id[0..name.len], name);
        return selection;
    }
    pub fn wrapSelection(self: *Service, a: std.mem.Allocator, selection: Envelope, ad: []const u8, dek: box.Key) !Envelope {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!(self.health orelse false)) return error.KmsNotRunning;
        for (selection.profile) |c| if (!std.ascii.isHex(c)) return error.InvalidKmsStore;
        if (selection.key_len == 0 or selection.key_len > 256 or !validKey(selection.key())) return error.InvalidKmsStore;
        const bytes = try self.readProfile(a, selection.profile);
        const config = (try std.json.parseFromSlice(Config, a, bytes, .{ .allocate = .alloc_always })).value;
        return self.wrapWith(a, config, selection.profile, selection.key(), ad, dek);
    }
    pub fn unwrap(self: *Service, a: std.mem.Allocator, envelope: Envelope, ad: []const u8) !box.Key {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!(self.health orelse false)) return error.KmsNotRunning;
        for (envelope.profile) |c| if (!std.ascii.isHex(c)) return error.InvalidKmsStore;
        if (envelope.key_len == 0 or envelope.key_len > 256 or envelope.ciphertext_len > 512) return error.InvalidKmsStore;
        const bytes = try self.readProfile(a, envelope.profile);
        const config = (try std.json.parseFromSlice(Config, a, bytes, .{ .allocate = .alloc_always })).value;
        return self.unwrapWith(a, config, envelope, ad);
    }
    fn wrapWith(self: *Service, a: std.mem.Allocator, config: Config, profile: [32]u8, name: []const u8, object_ad: []const u8, dek: box.Key) !Envelope {
        if (!validKey(name)) return error.InvalidKmsConfig;
        try @import("kms_keys.zig").ensureEnabled(self, a, config, name);
        const ad = try std.fmt.allocPrint(a, "ZIGFS-KMS-V1:{s}:{s}:{s}", .{ profile, name, object_ad });
        var envelope: Envelope = .{ .profile = profile, .key_len = @intCast(name.len) };
        @memcpy(envelope.key_id[0..name.len], name);
        if (std.mem.eql(u8, config.backend, "vault")) {
            // Transit encrypts DEK plus an authenticated binding to object identity.
            var bound: [64]u8 = undefined;
            @memcpy(bound[0..32], &dek);
            std.crypto.hash.sha2.Sha256.hash(ad, bound[32..64], .{});
            defer std.crypto.secureZero(u8, &bound);
            const body = try std.json.Stringify.valueAlloc(a, .{ .plaintext = try base64(a, &bound) }, .{});
            const data = try self.vault(a, config, try std.fmt.allocPrint(a, "{s}/encrypt/{s}", .{ config.mountPath, name }), body);
            const ciphertext = try stringField(try field(data, "data"), "ciphertext");
            if (ciphertext.len > envelope.ciphertext.len) return error.KmsUnavailable;
            @memcpy(envelope.ciphertext[0..ciphertext.len], ciphertext);
            envelope.ciphertext_len = @intCast(ciphertext.len);
        } else {
            var version: u64 = 0;
            var key = try self.loadKey(a, config, profile, name, true, null, &version);
            defer std.crypto.secureZero(u8, &key);
            const wrapped = try encryption.wrapDataKey(a, self.io, key, ad, dek);
            @memcpy(envelope.ciphertext[0..12], &wrapped.nonce);
            @memcpy(envelope.ciphertext[12..28], &wrapped.tag);
            @memcpy(envelope.ciphertext[28..60], &wrapped.ciphertext);
            envelope.ciphertext_len = 60;
            if (std.mem.eql(u8, config.backend, "vault-kv2") or std.mem.eql(u8, config.backend, "local")) {
                std.mem.writeInt(u64, envelope.ciphertext[60..68], version, .little);
                envelope.ciphertext_len = 68;
            }
        }
        return envelope;
    }
    fn unwrapWith(self: *Service, a: std.mem.Allocator, config: Config, envelope: Envelope, object_ad: []const u8) !box.Key {
        if (!validKey(envelope.key())) return error.InvalidKmsStore;
        try @import("kms_keys.zig").ensureEnabled(self, a, config, envelope.key());
        const ad = try std.fmt.allocPrint(a, "ZIGFS-KMS-V1:{s}:{s}:{s}", .{ envelope.profile, envelope.key(), object_ad });
        if (std.mem.eql(u8, config.backend, "vault")) {
            var digest = std.crypto.hash.sha2.Sha256.init(.{});
            digest.update(&envelope.profile);
            digest.update(envelope.key());
            digest.update(envelope.ciphertext[0..envelope.ciphertext_len]);
            digest.update(ad);
            const cache_id = std.fmt.bytesToHex(digest.finalResult(), .lower);
            const now = std.Io.Clock.awake.now(self.io).toSeconds();
            if (config.cacheEnabled) if (self.cache.get(&cache_id)) |entry| {
                if (entry.expires > now) return entry.key;
            };
            const body = try std.json.Stringify.valueAlloc(a, .{ .ciphertext = envelope.ciphertext[0..envelope.ciphertext_len] }, .{});
            const data = try self.vault(a, config, try std.fmt.allocPrint(a, "{s}/decrypt/{s}", .{ config.mountPath, envelope.key() }), body);
            const encoded = try stringField(try field(data, "data"), "plaintext");
            var bound: [64]u8 = undefined;
            defer std.crypto.secureZero(u8, &bound);
            if (try std.base64.standard.Decoder.calcSizeForSlice(encoded) != 64) return error.KmsUnavailable;
            try std.base64.standard.Decoder.decode(&bound, encoded);
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(ad, &hash, .{});
            if (!std.crypto.timing_safe.eql([32]u8, hash, bound[32..64].*)) return error.AuthenticationFailed;
            if (config.cacheEnabled) {
                if (self.cache.count() >= try std.fmt.parseInt(usize, config.cacheCapacity, 10)) self.clearCache();
                const entry: CacheEntry = .{ .key = bound[0..32].*, .expires = now + try std.fmt.parseInt(i64, config.cacheTtlSeconds, 10) };
                if (self.cache.getPtr(&cache_id)) |old| {
                    std.crypto.secureZero(u8, &old.key);
                    old.* = entry;
                } else try self.cache.put(self.allocator, try self.allocator.dupe(u8, &cache_id), entry);
            }
            return bound[0..32].*;
        }
        if (envelope.ciphertext_len != 60 and envelope.ciphertext_len != 68) return error.InvalidKmsStore;
        var key_bytes = try self.loadKey(a, config, envelope.profile, envelope.key(), false, if (envelope.ciphertext_len == 68) std.mem.readInt(u64, envelope.ciphertext[60..68], .little) else if (std.mem.eql(u8, config.backend, "local")) @as(u64, 1) else null, null);
        defer std.crypto.secureZero(u8, &key_bytes);
        return encryption.unwrapDataKey(a, key_bytes, ad, .{ .nonce = envelope.ciphertext[0..12].*, .tag = envelope.ciphertext[12..28].*, .ciphertext = envelope.ciphertext[28..60].* });
    }
    fn loadKey(self: *Service, a: std.mem.Allocator, config: Config, profile: [32]u8, name: []const u8, create: bool, kv_version: ?u64, actual_version: ?*u64) !box.Key {
        if (!validKey(name)) return error.InvalidKmsConfig;
        const cache_enabled = if (std.mem.eql(u8, config.backend, "local")) config.localCacheEnabled else config.cacheEnabled;
        const cache_id = try std.fmt.allocPrint(a, "{s}/{s}/{d}", .{ profile, name, kv_version orelse 0 });
        const now = std.Io.Clock.awake.now(self.io).toSeconds();
        if (cache_enabled) if (self.cache.get(cache_id)) |entry| {
            if (entry.expires > now) {
                if (actual_version) |out| out.* = entry.version;
                return entry.key;
            }
        };
        var result: box.Key = undefined;
        var version: u64 = 0;
        if (std.mem.eql(u8, config.backend, "static")) {
            result = try decodeKey(config.staticSecretKey);
        } else if (std.mem.eql(u8, config.backend, "local")) {
            result = try self.localKeyVersion(a, config, name, create, kv_version, &version);
        } else {
            const prefix = std.mem.trim(u8, config.keyPathPrefix, "/");
            const path = try std.fmt.allocPrint(a, "{s}/data/{s}{s}{s}{s}", .{ config.kvMount, prefix, if (prefix.len > 0) "/" else "", name, if (kv_version) |v| try std.fmt.allocPrint(a, "?version={d}", .{v}) else "" });
            const response = try self.vault(a, config, path, null);
            result = try decodeKey(try stringField(try field(try field(response, "data"), "data"), "key"));
            const v = try field(try field(try field(response, "data"), "metadata"), "version");
            if (v != .integer or v.integer <= 0) return error.KmsUnavailable;
            version = @intCast(v.integer);
            if (kv_version) |expected| {
                if (version != expected) return error.KmsUnavailable;
            }
        }
        if (cache_enabled) {
            const capacity = try std.fmt.parseInt(usize, config.cacheCapacity, 10);
            if (self.cache.count() >= capacity) self.clearCache();
            if (self.cache.getPtr(cache_id)) |entry| {
                std.crypto.secureZero(u8, &entry.key);
                entry.* = .{ .key = result, .version = version, .expires = now + try std.fmt.parseInt(i64, config.cacheTtlSeconds, 10) };
            } else try self.cache.put(self.allocator, try self.allocator.dupe(u8, cache_id), .{ .key = result, .version = version, .expires = now + try std.fmt.parseInt(i64, config.cacheTtlSeconds, 10) });
        }
        if (actual_version) |out| out.* = version;
        return result;
    }
    pub fn vault(self: *Service, a: std.mem.Allocator, config: Config, path: []const u8, body: ?[]const u8) !std.json.Value {
        return self.vaultMethod(a, config, path, body, if (body != null) "POST" else "GET");
    }
    pub fn vaultMethod(self: *Service, a: std.mem.Allocator, config: Config, path: []const u8, body: ?[]const u8, method: []const u8) !std.json.Value {
        _ = self;
        const url = try dupeZ(a, try std.fmt.allocPrint(a, "{s}/v1/{s}", .{ std.mem.trimEnd(u8, config.address, "/"), path }));
        const token = try dupeZ(a, try std.fmt.allocPrint(a, "X-Vault-Token: {s}", .{config.token}));
        const ns = try dupeZ(a, if (config.namespace.len == 0) "" else try std.fmt.allocPrint(a, "X-Vault-Namespace: {s}", .{config.namespace}));
        const payload = if (body) |value| try dupeZ(a, value) else null;
        const buffer = try a.alloc(u8, 64 * 1024);
        const retries = try std.fmt.parseInt(usize, config.retryCount, 10);
        var length: usize = 0;
        var status_code: c_long = 0;
        var failure: anyerror = error.KmsUnavailable;
        for (0..retries + 1) |_| {
            const rc = zigfs_kms_http(url, try dupeZ(a, method), if (payload) |v| v.ptr else null, token, ns, try dupeZ(a, config.caCertificatePath), try dupeZ(a, config.clientCertificatePath), try dupeZ(a, config.clientKeyPath), @intFromBool(config.skipTlsVerification), try std.fmt.parseInt(c_long, config.timeoutSeconds, 10), buffer.ptr, buffer.len, &length, &status_code);
            if (rc == 0 and status_code == 204) return .null;
            if (rc == 0 and status_code == 200) return (try std.json.parseFromSlice(std.json.Value, a, buffer[0..length], .{ .allocate = .alloc_always })).value;
            failure = vaultRequestError(rc, status_code);
            if (rc == 0 and status_code != 429 and status_code < 500) return failure;
        }
        return failure;
    }
};
extern fn zigfs_kms_http([*:0]const u8, [*:0]const u8, ?[*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, c_int, c_long, [*]u8, usize, *usize, *c_long) c_int;
fn field(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.KmsUnavailable;
    return value.object.get(name) orelse error.KmsUnavailable;
}
fn stringField(value: std.json.Value, name: []const u8) ![]const u8 {
    const v = try field(value, name);
    if (v != .string) return error.KmsUnavailable;
    return v.string;
}
pub fn base64(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    const out = try a.alloc(u8, std.base64.standard.Encoder.calcSize(value.len));
    return std.base64.standard.Encoder.encode(out, value);
}
pub fn decodeKey(value: []const u8) !box.Key {
    var result: box.Key = undefined;
    if ((std.base64.standard.Decoder.calcSizeForSlice(value) catch return error.InvalidKmsConfig) != 32) return error.InvalidKmsConfig;
    std.base64.standard.Decoder.decode(&result, value) catch return error.InvalidKmsConfig;
    return result;
}
pub fn validKey(value: []const u8) bool {
    if (value.len == 0 or value.len > 256 or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    return true;
}
fn relative(value: []const u8) bool {
    var parts = std.mem.splitScalar(u8, value, '/');
    while (parts.next()) |part| if (!validKey(part)) return false;
    return true;
}
fn bounded(value: []const u8, min: usize, max: usize) !void {
    const n = std.fmt.parseInt(usize, value, 10) catch return error.InvalidKmsConfig;
    if (n < min or n > max) return error.InvalidKmsConfig;
}
pub fn validate(c: Config) !void {
    var total: usize = 0;
    inline for (@typeInfo(Config).@"struct".field_names, @typeInfo(Config).@"struct".field_types) |field_name, field_type| {
        if (field_type == []const u8) {
            const value = @field(c, field_name);
            if (value.len > 4096 or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidKmsConfig;
            total += value.len;
        }
    }
    if (total > 32 * 1024) return error.InvalidKmsConfig;
    if (c.defaultKey.len > 0 and !validKey(c.defaultKey)) return error.InvalidKmsConfig;
    if (std.mem.eql(u8, c.backend, "local")) {
        if (!std.fs.path.isAbsolute(c.localKeyDirectory) or std.mem.indexOfScalar(u8, c.localKeyDirectory, 0) != null) return error.InvalidKmsConfig;
        _ = try dataRelativePath(c.localKeyDirectory);
        try bounded(c.filePermissions, 0, 511);
    } else if (std.mem.eql(u8, c.backend, "static")) {
        var key = try decodeKey(c.staticSecretKey);
        std.crypto.secureZero(u8, &key);
    } else if (std.mem.eql(u8, c.backend, "vault") or std.mem.eql(u8, c.backend, "vault-kv2")) {
        const uri = std.Uri.parse(c.address) catch return error.InvalidKmsConfig;
        if ((!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) or uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null or c.token.len == 0) return error.InvalidKmsConfig;
        if (!relative(c.mountPath) or !relative(c.kvMount) or (c.keyPathPrefix.len > 0 and !relative(std.mem.trimEnd(u8, c.keyPathPrefix, "/")))) return error.InvalidKmsConfig;
        for ([_][]const u8{ c.token, c.namespace, c.address }) |v| if (std.mem.indexOfAny(u8, v, "\x00\r\n") != null) return error.InvalidKmsConfig;
        for ([_][]const u8{ c.caCertificatePath, c.clientCertificatePath, c.clientKeyPath }) |v| if (v.len > 0 and (!std.fs.path.isAbsolute(v) or std.mem.indexOfScalar(u8, v, 0) != null)) return error.InvalidKmsConfig;
        if ((c.clientCertificatePath.len > 0) != (c.clientKeyPath.len > 0)) return error.InvalidKmsConfig;
    } else return error.InvalidKmsConfig;
    try bounded(c.timeoutSeconds, 1, 300);
    try bounded(c.retryCount, 0, 10);
    try bounded(c.cacheCapacity, 1, 100000);
    try bounded(c.cacheTtlSeconds, 1, 86400);
}

fn dupeZ(a: std.mem.Allocator, value: []const u8) ![:0]u8 {
    return a.dupeSentinel(u8, value, 0);
}

test "KMS profiles survive configuration changes and bind envelopes to objects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service: Service = .{ .root = tmp.dir, .io = std.testing.io, .master = @splat(0x55), .allocator = std.testing.allocator };
    defer service.deinit();
    const secret = try base64(a, &@as(box.Key, @splat(0x11)));
    const config: Config = .{ .backend = "static", .staticSecretKey = secret, .defaultKey = "one" };
    try service.save(a, config);
    try service.verify(a);
    const status_value = try service.status(a);
    try std.testing.expect(status_value.configured and status_value.healthy and status_value.staticSecretKeyConfigured);
    try std.testing.expectEqualStrings("", status_value.config.staticSecretKey);
    const dek: box.Key = @splat(0x33);
    const envelope = try service.wrap(a, "", "object-a", dek);
    try std.testing.expectError(error.AuthenticationFailed, service.unwrap(a, envelope, "object-b"));
    var tampered = envelope;
    tampered.key_id[0] = 'x';
    try std.testing.expectError(error.AuthenticationFailed, service.unwrap(a, tampered, "object-a"));
    tampered = envelope;
    tampered.ciphertext[59] ^= 1;
    try std.testing.expectError(error.AuthenticationFailed, service.unwrap(a, tampered, "object-a"));
    var bad = config;
    bad.staticSecretKey = "invalid";
    try std.testing.expectError(error.InvalidKmsConfig, service.save(a, bad));
    try std.testing.expectEqual(dek, try service.unwrap(a, envelope, "object-a"));
    var next = config;
    next.staticSecretKey = try base64(a, &@as(box.Key, @splat(0x22)));
    next.defaultKey = "two";
    try service.save(a, next);
    try service.verify(a);
    const next_envelope = try service.wrap(a, "", "object-a", dek);
    try std.testing.expectEqualStrings("two", next_envelope.key());
    try std.testing.expectEqual(dek, try service.unwrap(a, envelope, "object-a"));
    var restarted: Service = .{ .root = tmp.dir, .io = std.testing.io, .master = @splat(0x55), .allocator = std.testing.allocator };
    defer restarted.deinit();
    try restarted.verify(a);
    try std.testing.expectEqual(dek, try restarted.unwrap(a, envelope, "object-a"));
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, current_path, a, .limited(65536));
    try std.testing.expect(std.mem.indexOf(u8, bytes, next.staticSecretKey) == null);
    next.staticSecretKey = "";
    try restarted.save(a, next);
    try std.testing.expect((try restarted.status(a)).staticSecretKeyConfigured);
}

test "KMS rejects unsafe endpoints, key paths, TLS pairs and invalid numeric settings" {
    const invalid = [_]Config{
        .{ .backend = "local", .localKeyDirectory = "relative" },
        .{ .backend = "vault", .address = "file:///etc/passwd", .token = "token" },
        .{ .backend = "vault", .address = "https://vault.example", .token = "bad\r\nheader" },
        .{ .backend = "vault", .address = "https://vault.example", .token = "token", .mountPath = "../secret" },
        .{ .backend = "vault", .address = "https://vault.example", .token = "token", .clientCertificatePath = "/cert.pem" },
        .{ .backend = "local", .localKeyDirectory = "/tmp/keys", .defaultKey = "../key" },
        .{ .backend = "local", .localKeyDirectory = "/tmp/keys", .retryCount = "11" },
    };
    for (invalid) |config| try std.testing.expectError(error.InvalidKmsConfig, validate(config));
}

fn saveVerificationError(config: Config, err: anyerror) anyerror {
    if (!std.mem.eql(u8, config.backend, "local")) return err;
    return switch (err) {
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => error.KmsLocalPermissionDenied,
        error.InvalidKmsStore => error.KmsLocalKeyInvalid,
        error.KmsLocalKeyDisabled => error.KmsLocalKeyDisabled,
        error.AuthenticationFailed => error.KmsKeyVerificationFailed,
        error.OutOfMemory => error.OutOfMemory,
        else => error.KmsLocalStorageFailed,
    };
}
fn vaultRequestError(rc: c_int, status_code: c_long) anyerror {
    // libcurl error numbers are stable ABI. Never forward provider bodies or credentials.
    return switch (rc) {
        0 => switch (status_code) {
            400 => error.KmsVaultRequestRejected,
            401, 403 => error.KmsVaultAccessDenied,
            404 => error.KmsVaultKeyNotFound,
            429 => error.KmsVaultRateLimited,
            else => error.KmsVaultUnavailable,
        },
        5, 6 => error.KmsVaultDnsFailed,
        7 => error.KmsVaultConnectionFailed,
        28 => error.KmsVaultTimeout,
        35, 51, 58, 60, 77, 82, 83, 90, 91, 98 => error.KmsVaultTlsFailed,
        else => error.KmsVaultUnavailable,
    };
}
pub fn saveErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.KmsKeyOperationUnsupported => "This KMS backend does not support this key management operation.",
        error.KmsKeyPendingDeletion => "The key must be enabled for this operation.",
        error.KmsLastKeyDeletionForbidden => "The last KMS key cannot be deleted. Create another key first.",
        error.KmsKeyDeletionNotScheduled => "Schedule key deletion before deleting it immediately.",
        error.InvalidKmsKeyRequest => "The KMS key request is invalid.",
        error.KmsNotRunning => "KMS is configured but not running. Start KMS before using SSE-KMS.",
        error.FileNotFound => "KMS configuration or the selected key could not be found.",
        error.InvalidKmsConfig => "KMS configuration is invalid",
        error.KmsVaultHttpsRequired => "Vault requires HTTPS outside explicit development mode; set ZIGFS_KMS_ALLOW_INSECURE_DEV_DEFAULTS=true only for development.",
        error.KmsLocalPermissionDenied => "ZigFS cannot write to the local key directory. Check directory ownership and permissions on the ZigFS server.",
        error.KmsLocalKeyDisabled => "The local key is disabled or pending deletion and cannot be used for encryption or decryption.",
        error.KmsLocalKeyInvalid => "The local key file is invalid: JSON must contain a Base64-encoded 32-byte key (legacy raw keys must contain exactly 32 bytes). Restore the original key file; do not replace keys used by existing objects.",
        error.KmsLocalStorageFailed => "ZigFS cannot create or read the local key directory or key file. Check the server path, permissions and available disk space.",
        error.KmsPersistenceFailed => "The key was verified, but ZigFS could not save its KMS configuration. Check the ZigFS data directory permissions and available disk space.",
        error.KmsConfigurationReadFailed => "ZigFS could not read its existing KMS configuration. Check the configuration files and server master key.",
        error.KmsVaultDnsFailed => "The Vault server hostname could not be resolved. Check the server address and DNS on the ZigFS server.",
        error.KmsVaultConnectionFailed => "ZigFS could not connect to Vault. Check the Vault address, port and network access.",
        error.KmsVaultTimeout => "The Vault request timed out. Check network access or increase the KMS timeout.",
        error.KmsVaultTlsFailed => "Vault TLS verification or client authentication failed. Check the server hostname, CA certificate and client certificate/key paths.",
        error.KmsVaultAccessDenied => "Vault denied access (401/403). Check the token, namespace and permissions for the selected key and backend.",
        error.KmsVaultKeyNotFound => "Vault returned 404. Check the mount path, key ID and KV2 key prefix; ensure the secret or Transit key exists.",
        error.KmsVaultRequestRejected => "Vault rejected the key operation (400). Check the key type and backend configuration.",
        error.KmsVaultRateLimited => "Vault is rate limiting requests (429). Retry later or adjust the retry settings.",
        error.KmsVaultUnavailable => "Vault is unavailable or returned an unexpected response. Check the Vault service and its logs.",
        else => "KMS key verification failed. Check the key material and backend configuration.",
    };
}
test "KMS save failures identify provider and storage causes without secrets" {
    try std.testing.expectEqual(error.KmsVaultAccessDenied, vaultRequestError(0, 403));
    try std.testing.expectEqual(error.KmsVaultKeyNotFound, vaultRequestError(0, 404));
    try std.testing.expectEqual(error.KmsVaultTlsFailed, vaultRequestError(60, 0));
    try std.testing.expectEqual(error.KmsVaultTimeout, vaultRequestError(28, 0));
    try std.testing.expectEqual(error.KmsLocalPermissionDenied, saveVerificationError(.{ .backend = "local" }, error.AccessDenied));
    try std.testing.expect(std.mem.indexOf(u8, saveErrorMessage(error.KmsPersistenceFailed), "key was verified") != null);
}

fn dataRelativePath(path: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, path, "/data")) return "";
    if (!std.mem.startsWith(u8, path, "/data/")) return null;
    const relative_path = path[6..];
    var parts = std.mem.tokenizeScalar(u8, relative_path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".zigfs") or std.mem.indexOfScalar(u8, part, '\\') != null) return error.InvalidKmsConfig;
    }
    return relative_path;
}

test "logical data path stores JSON keys and encrypted configuration inside the data root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service: Service = .{ .root = tmp.dir, .io = std.testing.io, .master = @splat(0x44), .allocator = std.testing.allocator };
    defer service.deinit();
    try service.save(a, .{ .backend = "local", .localKeyDirectory = "/data/test", .defaultKey = "test-key" });
    try service.verify(a);
    try std.testing.expect((try service.status(a)).healthy);
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(std.testing.io, "test/test-key.key", a, .limited(4096)));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir(std.testing.io, config_dir ++ "/profiles", .{}));
    _ = try service.wrap(a, "", "first-object", @splat(0x12));
    const key_json = try tmp.dir.readFileAlloc(std.testing.io, "test/test-key.key", a, .limited(4096));
    const key = try std.json.parseFromSlice(LocalKey, a, key_json, .{});
    try std.testing.expectEqual(@as(u8, 1), key.value.version);
    _ = try decodeKey(key.value.encrypted_key_material);
    const probe_json = try tmp.dir.readFileAlloc(std.testing.io, "test/" ++ probe_key_id ++ ".key", a, .limited(4096));
    const probe = try std.json.parseFromSlice(LocalKey, a, probe_json, .{});
    try std.testing.expectEqualStrings(probe_key_id, probe.value.key_id);
    try std.testing.expectEqualStrings("Enabled", probe.value.status);
    try std.testing.expect(probe.value.deletion_date == null);
    var pending = key.value;
    pending.status = "PendingDeletion";
    pending.deletion_date = "2026-11-17T07:13:03Z";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "test/test-key.key", .data = try std.json.Stringify.valueAlloc(a, pending, .{}) });
    try std.testing.expectError(error.KmsLocalKeyDisabled, service.localKey(a, .{ .backend = "local", .localKeyDirectory = "/data/test" }, "test-key", false));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "test/test-key.key", .data = key_json });
    const old_json = try std.json.Stringify.valueAlloc(a, LegacyLocalKey{ .key = try base64(a, &@as(box.Key, @splat(0x24))) }, .{});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "test/old-json.json", .data = old_json });
    try std.testing.expectEqual(@as(box.Key, @splat(0x24)), try service.localKey(a, .{ .backend = "local", .localKeyDirectory = "/data/test" }, "old-json", true));
    const config_json = try tmp.dir.readFileAlloc(std.testing.io, current_path, a, .limited(65536));
    _ = try config_file.decode(config_json);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, config_json[6..8], .little));
    try std.testing.expect(std.mem.indexOf(u8, config_json, "ciphertext") == null);
    try std.testing.expect(std.mem.indexOf(u8, config_json, "localKeyDirectory") == null);
    const dek: box.Key = @splat(0x12);
    const wrapped = try service.wrap(a, "", "object", dek);
    var restarted: Service = .{ .root = tmp.dir, .io = std.testing.io, .master = @splat(0x44), .allocator = std.testing.allocator };
    defer restarted.deinit();
    try restarted.verify(a);
    try std.testing.expectEqual(dek, try restarted.unwrap(a, wrapped, "object"));
    for ([_][]const u8{ "/data/../outside", "/data/test/../../outside", "/data/.zigfs/config" }) |path| {
        try std.testing.expectError(error.InvalidKmsConfig, validate(.{ .backend = "local", .localKeyDirectory = path }));
    }
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "test/legacy.key", .data = &@as(box.Key, @splat(0x23)) });
    try std.testing.expectEqual(@as(box.Key, @splat(0x23)), try service.localKey(a, .{ .backend = "local", .localKeyDirectory = "/data/test" }, "legacy", false));
}

test "legacy encrypted profiles remain usable after saving to the new config directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service: Service = .{ .root = tmp.dir, .io = std.testing.io, .master = @splat(0x44), .allocator = std.testing.allocator };
    defer service.deinit();
    const profile = "0123456789abcdef0123456789abcdef";
    const config: Config = .{ .backend = "static", .staticSecretKey = try base64(a, &@as(box.Key, @splat(0x11))) };
    try tmp.dir.createDirPath(std.testing.io, ".zigfs/kms/profiles");
    const paths = [_][]const u8{ ".zigfs/kms/current", ".zigfs/kms/profiles/" ++ profile };
    for (paths, 0..) |path, index| {
        const plaintext = if (index == 0) try std.json.Stringify.valueAlloc(a, Stored{ .profile = profile, .config = config }, .{}) else try std.json.Stringify.valueAlloc(a, config, .{});
        const sealed = try box.seal(a, std.testing.io, service.master, path, plaintext);
        const bytes = try std.mem.concat(a, u8, &.{ &sealed.nonce, &sealed.tag, sealed.ciphertext });
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
    }
    const dek: box.Key = @splat(0x33);
    try service.verify(a);
    const envelope = try service.wrap(a, "", "old-object", dek);
    try service.save(a, config);
    try service.verify(a);
    try std.testing.expectEqual(dek, try service.unwrap(a, envelope, "old-object"));
    try service.verify(a);
    try std.testing.expect((try service.status(a)).healthy);
}

test "legacy JSON xl.meta envelope remains readable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service: Service = .{ .root = tmp.dir, .io = std.testing.io, .master = @splat(0x44), .allocator = std.testing.allocator };
    defer service.deinit();
    const sealed = try box.seal(a, std.testing.io, service.master, current_path, "legacy-config");
    const payload = try std.json.Stringify.valueAlloc(a, EncryptedConfig{ .nonce = sealed.nonce, .tag = sealed.tag, .ciphertext = try base64(a, sealed.ciphertext) }, .{});
    const bytes = try config_file.encode(a, payload);
    std.mem.writeInt(u16, bytes[6..8], 1, .little);
    try tmp.dir.createDirPath(std.testing.io, config_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = current_path, .data = bytes });
    try std.testing.expectEqualStrings("legacy-config", try service.read(a, current_path));
}

test "saving offline Vault configuration only validates configuration and HTTPS policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service: Service = .{ .root = tmp.dir, .io = std.testing.io, .master = @splat(0x44), .allocator = std.testing.allocator };
    defer service.deinit();
    for ([_][]const u8{ "vault", "vault-kv2" }) |backend| {
        var config: Config = .{ .backend = backend, .address = "https://vault.invalid:8200", .token = "offline-token" };
        try service.save(a, config);
        const status_value = try service.status(a);
        try std.testing.expect(status_value.configured and !status_value.healthChecked);
        config.address = "http://vault.invalid:8200";
        try std.testing.expectError(error.KmsVaultHttpsRequired, service.save(a, config));
        try std.testing.expectEqualStrings("https://vault.invalid:8200", (try service.status(a)).config.address);
        service.allow_insecure_dev_defaults = true;
        try service.save(a, config);
        service.allow_insecure_dev_defaults = false;
    }
}

test "managed local keys rotate without losing old objects and support deletion recovery" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service: Service = .{ .root = tmp.dir, .io = std.testing.io, .master = @splat(0x66), .allocator = std.testing.allocator };
    defer service.deinit();
    try service.save(a, .{ .backend = "local", .localKeyDirectory = "/data/keys", .localCacheEnabled = true });
    try std.testing.expectError(error.KmsNotRunning, service.listKeys(a));
    try service.verify(a);
    try std.testing.expectError(error.KmsLastKeyDeletionForbidden, service.keyAction(a, probe_key_id, "delete"));
    try std.testing.expectError(error.KmsLastKeyDeletionForbidden, service.keyAction(a, probe_key_id, "schedule-deletion"));
    try std.testing.expectEqual(@as(usize, 1), (try service.listKeys(a)).items.len);
    const created = try service.createKey(a, .{ .name = "Reports", .description = "Report encryption", .setAsDefault = true });
    try std.testing.expectEqualStrings(created.id, (try service.status(a)).config.defaultKey);
    const dek: box.Key = @splat(0x77);
    const first = try service.wrap(a, "", "object", dek);
    var legacy = first;
    legacy.ciphertext_len = 60;
    try service.keyAction(a, created.id, "rotate");
    const second = try service.wrap(a, "", "object", dek);
    try std.testing.expectEqual(@as(u64, 2), std.mem.readInt(u64, second.ciphertext[60..68], .little));
    try std.testing.expectEqual(dek, try service.unwrap(a, first, "object"));
    try std.testing.expectEqual(dek, try service.unwrap(a, legacy, "object"));
    try std.testing.expectEqual(dek, try service.unwrap(a, second, "object"));
    try service.keyAction(a, created.id, "schedule-deletion");
    try std.testing.expectError(error.KmsLocalKeyDisabled, service.unwrap(a, first, "object"));
    try std.testing.expectError(error.KmsKeyPendingDeletion, service.keyAction(a, created.id, "rotate"));
    try service.keyAction(a, created.id, "cancel-deletion");
    try std.testing.expectEqual(dek, try service.unwrap(a, first, "object"));
    try service.stop(a);
    try std.testing.expectError(error.KmsNotRunning, service.wrap(a, "", "object", dek));
    try service.verify(a);
    try service.keyAction(a, created.id, "schedule-deletion");
    try service.keyAction(a, created.id, "delete");
    try std.testing.expectError(error.KmsKeyPendingDeletion, service.wrap(a, "", "new-object", dek));
    const keys = try service.listKeys(a);
    for (keys.items) |key| try std.testing.expect(!std.mem.eql(u8, key.id, created.id));
}

test "KMS restores persisted startup intent and reports failed automatic startup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var service: Service = .{ .root = tmp.dir, .io = std.testing.io, .master = @splat(0x42), .allocator = std.testing.allocator };
    defer service.deinit();
    try service.restore(a);
    try std.testing.expect(!(try service.status(a)).configured);
    const config: Config = .{ .backend = "local", .localKeyDirectory = "/data/restore" };
    try service.save(a, config);
    try service.restore(a);
    try std.testing.expectEqualStrings("configured", (try service.status(a)).state);
    try service.verify(a);
    var restarted: Service = .{ .root = tmp.dir, .io = std.testing.io, .master = @splat(0x42), .allocator = std.testing.allocator };
    defer restarted.deinit();
    try restarted.restore(a);
    try std.testing.expectEqualStrings("running", (try restarted.status(a)).state);
    const probe_path = "restore/" ++ probe_key_id ++ ".key";
    const probe_bytes = try tmp.dir.readFileAlloc(std.testing.io, probe_path, a, .limited(4096));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = probe_path, .data = "invalid" });
    try std.testing.expectError(error.KmsLocalKeyInvalid, restarted.restore(a));
    try std.testing.expectEqualStrings("error", (try restarted.status(a)).state);
    try std.testing.expect((try restarted.current(a)).enabled);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = probe_path, .data = probe_bytes });
    try restarted.restore(a);
    try std.testing.expectEqualStrings("running", (try restarted.status(a)).state);
    try restarted.stop(a);
    var stopped: Service = .{ .root = tmp.dir, .io = std.testing.io, .master = @splat(0x42), .allocator = std.testing.allocator };
    defer stopped.deinit();
    try stopped.restore(a);
    try std.testing.expectEqualStrings("configured", (try stopped.status(a)).state);
    try std.testing.expectError(error.KmsNotRunning, stopped.requireRunning());
    try stopped.verify(a);
    try stopped.save(a, config);
    var reconfigured: Service = .{ .root = tmp.dir, .io = std.testing.io, .master = @splat(0x42), .allocator = std.testing.allocator };
    defer reconfigured.deinit();
    try reconfigured.restore(a);
    try std.testing.expectEqualStrings("configured", (try reconfigured.status(a)).state);
}
