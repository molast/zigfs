const std = @import("std");
const secret_box = @import("../auth/secret_box.zig");
const credential_domain = @import("../domain/credential.zig");
const index_module = @import("../metadata/index.zig");
const credential_store_port = @import("../ports/credential_store.zig");

pub const Error = error{
    OutOfMemory,
    InvalidOwner,
    InvalidAccessKey,
    CredentialNotFound,
    CredentialDisabled,
    CredentialExpired,
    InvalidTTL,
    Conflict,
    CorruptMetadata,
    SecretDecryptionFailed,
    Unavailable,
};

pub const CreateResult = struct {
    credential: credential_domain.Credential,
    secret_key: [credential_domain.secret_key_length]u8,
    session_token: ?[credential_domain.session_token_length]u8 = null,

    pub fn deinit(self: *CreateResult, allocator: std.mem.Allocator) void {
        self.credential.deinit(allocator);
        std.crypto.secureZero(u8, &self.secret_key);
        if (self.session_token) |*token| std.crypto.secureZero(u8, token);
        self.* = undefined;
    }
};

pub const AuthMaterial = struct {
    owner: []u8,
    policy: credential_domain.Policy,
    secret_key: []u8,
    session_token: ?[]u8,

    pub fn deinit(self: *AuthMaterial, allocator: std.mem.Allocator) void {
        allocator.free(self.owner);
        std.crypto.secureZero(u8, self.secret_key);
        allocator.free(self.secret_key);
        if (self.session_token) |token| {
            std.crypto.secureZero(u8, token);
            allocator.free(token);
        }
        self.* = undefined;
    }
};

pub const Update = struct {
    enabled: ?bool = null,
    policy: ?credential_domain.Policy = null,
};

pub const CredentialDetails = struct {
    credential: credential_domain.Credential,
    secret_key: []u8,
    session_token: ?[]u8,

    pub fn deinit(self: CredentialDetails, allocator: std.mem.Allocator) void {
        self.credential.deinit(allocator);
        std.crypto.secureZero(u8, self.secret_key);
        allocator.free(self.secret_key);
        if (self.session_token) |token| {
            std.crypto.secureZero(u8, token);
            allocator.free(token);
        }
    }
};

pub const ListResult = struct {
    credentials: []CredentialDetails,

    pub fn deinit(self: ListResult, allocator: std.mem.Allocator) void {
        for (self.credentials) |credential| credential.deinit(allocator);
        allocator.free(self.credentials);
    }
};

pub const CredentialService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: credential_store_port.CredentialStore,
    index: *index_module.MetadataIndex,
    mutex: *std.Io.Mutex,
    master_key: *const secret_box.Key,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        store: credential_store_port.CredentialStore,
        index: *index_module.MetadataIndex,
        mutex: *std.Io.Mutex,
        master_key: *const secret_box.Key,
    ) CredentialService {
        return .{
            .allocator = allocator,
            .io = io,
            .store = store,
            .index = index,
            .mutex = mutex,
            .master_key = master_key,
        };
    }

    pub fn create(
        self: CredentialService,
        owner: []const u8,
        policy: credential_domain.Policy,
    ) Error!CreateResult {
        return self.createWithTTL(owner, policy, null);
    }

    pub fn createWithTTL(
        self: CredentialService,
        owner: []const u8,
        policy: credential_domain.Policy,
        ttl_seconds: ?u64,
    ) Error!CreateResult {
        credential_domain.validateOwner(owner) catch return error.InvalidOwner;
        _ = credential_domain.Policy.fromBits(policy.toBits()) catch return error.CorruptMetadata;
        if (ttl_seconds) |ttl| {
            if (ttl < credential_domain.min_temporary_ttl_seconds or
                ttl > credential_domain.max_temporary_ttl_seconds)
            {
                return error.InvalidTTL;
            }
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var attempts: usize = 0;
        while (attempts < 16) : (attempts += 1) {
            const access_key = generateAccessKey(self.io) catch return error.Unavailable;
            var expected_generation: credential_store_port.ExpectedGeneration = .missing;
            const current = self.store.get(self.allocator, &access_key) catch |err| switch (err) {
                error.NotFound => null,
                else => return mapStoreError(err),
            };
            if (current) |record| switch (record) {
                .active => |credential| {
                    credential.deinit(self.allocator);
                    continue;
                },
                .tombstone => |generation| {
                    if (self.index.containsAccessKey(&access_key)) return error.CorruptMetadata;
                    expected_generation = .{ .exact = generation };
                },
            } else if (self.index.containsAccessKey(&access_key)) {
                return error.CorruptMetadata;
            }

            var secret_key = generateSecretKey(self.io) catch return error.Unavailable;
            errdefer std.crypto.secureZero(u8, &secret_key);
            var session_token: ?[credential_domain.session_token_length]u8 = if (ttl_seconds != null)
                generateSessionToken(self.io) catch return error.Unavailable
            else
                null;
            errdefer if (session_token) |*token| std.crypto.secureZero(u8, token);
            var secret_material: [credential_domain.temporary_secret_material_length]u8 = undefined;
            defer std.crypto.secureZero(u8, &secret_material);
            @memcpy(secret_material[0..secret_key.len], &secret_key);
            const secret_material_length = if (session_token) |token| material: {
                @memcpy(secret_material[secret_key.len..], &token);
                break :material secret_material.len;
            } else secret_key.len;
            const sealed = secret_box.seal(
                self.allocator,
                self.io,
                self.master_key.*,
                &access_key,
                secret_material[0..secret_material_length],
            ) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Unavailable,
            };
            defer sealed.deinit(self.allocator);
            const created_at = std.Io.Clock.real.now(self.io).toSeconds();
            const expires_at: ?i64 = if (ttl_seconds) |ttl|
                std.math.add(i64, created_at, @intCast(ttl)) catch return error.InvalidTTL
            else
                null;
            const value: credential_domain.View = .{
                .access_key = &access_key,
                .owner = owner,
                .status = .active,
                .policy = policy,
                .created_at_unix_seconds = created_at,
                .secret_nonce = sealed.nonce,
                .secret_tag = sealed.tag,
                .encrypted_secret = sealed.ciphertext,
                .kind = if (ttl_seconds == null) .permanent else .temporary,
                .expires_at_unix_seconds = expires_at,
            };
            var prepared = self.index.prepareAccessKey(&access_key) catch |err| {
                return mapIndexError(err);
            };
            defer prepared.deinit(self.index.allocator);
            var owned = credential_domain.cloneFromView(
                self.allocator,
                value,
                0,
            ) catch return error.OutOfMemory;
            errdefer owned.deinit(self.allocator);
            const generation = self.store.put(
                self.allocator,
                value,
                expected_generation,
            ) catch |err| return mapStoreError(err);
            self.index.publishAccessKey(&prepared, generation);
            owned.metadata_generation = generation;
            return .{
                .credential = owned,
                .secret_key = secret_key,
                .session_token = session_token,
            };
        }
        return error.Conflict;
    }

    pub fn resolveForAuth(
        self: CredentialService,
        access_key: []const u8,
    ) Error!AuthMaterial {
        credential_domain.validateAccessKey(access_key) catch return error.InvalidAccessKey;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const credential = try self.loadActiveLocked(access_key);
        defer credential.deinit(self.allocator);
        if (credential.status == .disabled) return error.CredentialDisabled;
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        if (credential.isExpired(now)) return error.CredentialExpired;
        const owner = self.allocator.dupe(u8, credential.owner) catch return error.OutOfMemory;
        errdefer self.allocator.free(owner);
        const material = try self.decryptCredential(&credential);
        defer {
            std.crypto.secureZero(u8, material);
            self.allocator.free(material);
        }
        const secret_length = if (credential.kind == .temporary)
            credential_domain.secret_key_length
        else
            material.len;
        const secret_key = self.allocator.dupe(u8, material[0..secret_length]) catch return error.OutOfMemory;
        errdefer {
            std.crypto.secureZero(u8, secret_key);
            self.allocator.free(secret_key);
        }
        const session_token = if (credential.kind == .temporary)
            self.allocator.dupe(u8, material[credential_domain.secret_key_length..]) catch return error.OutOfMemory
        else
            null;
        return .{
            .owner = owner,
            .policy = credential.policy,
            .secret_key = secret_key,
            .session_token = session_token,
        };
    }

    pub fn get(
        self: CredentialService,
        access_key: []const u8,
    ) Error!credential_domain.Credential {
        credential_domain.validateAccessKey(access_key) catch return error.InvalidAccessKey;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.loadActiveLocked(access_key);
    }

    pub fn list(self: CredentialService) Error!ListResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entries = self.index.accessKeyEntries();
        const credentials = self.allocator.alloc(CredentialDetails, entries.len) catch {
            return error.OutOfMemory;
        };
        var initialized: usize = 0;
        errdefer {
            for (credentials[0..initialized]) |credential| credential.deinit(self.allocator);
            self.allocator.free(credentials);
        }
        for (entries, 0..) |entry, position| {
            const credential = try self.loadActiveLocked(entry.name);
            errdefer credential.deinit(self.allocator);
            const material = try self.decryptCredential(&credential);
            defer {
                std.crypto.secureZero(u8, material);
                self.allocator.free(material);
            }
            const secret_length = if (credential.kind == .temporary)
                credential_domain.secret_key_length
            else
                material.len;
            const secret_key = self.allocator.dupe(u8, material[0..secret_length]) catch return error.OutOfMemory;
            errdefer {
                std.crypto.secureZero(u8, secret_key);
                self.allocator.free(secret_key);
            }
            const session_token = if (credential.kind == .temporary)
                self.allocator.dupe(u8, material[credential_domain.secret_key_length..]) catch return error.OutOfMemory
            else
                null;
            credentials[position] = .{
                .credential = credential,
                .secret_key = secret_key,
                .session_token = session_token,
            };
            initialized += 1;
        }
        return .{ .credentials = credentials };
    }

    pub fn update(
        self: CredentialService,
        access_key: []const u8,
        update_value: Update,
    ) Error!credential_domain.Credential {
        credential_domain.validateAccessKey(access_key) catch return error.InvalidAccessKey;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const current = try self.loadActiveLocked(access_key);
        defer current.deinit(self.allocator);
        var value = current.view();
        if (update_value.enabled) |enabled| {
            value.status = if (enabled) .active else .disabled;
        }
        if (update_value.policy) |policy| value.policy = policy;
        var prepared = self.index.prepareAccessKey(access_key) catch |err| {
            return mapIndexError(err);
        };
        defer prepared.deinit(self.index.allocator);
        var owned = credential_domain.cloneFromView(
            self.allocator,
            value,
            0,
        ) catch return error.OutOfMemory;
        errdefer owned.deinit(self.allocator);
        const generation = self.store.put(
            self.allocator,
            value,
            .{ .exact = current.metadata_generation },
        ) catch |err| return mapStoreError(err);
        self.index.publishAccessKey(&prepared, generation);
        owned.metadata_generation = generation;
        return owned;
    }

    pub fn delete(
        self: CredentialService,
        access_key: []const u8,
    ) Error!bool {
        credential_domain.validateAccessKey(access_key) catch return error.InvalidAccessKey;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const record = self.store.get(self.allocator, access_key) catch |err| switch (err) {
            error.NotFound => {
                if (self.index.containsAccessKey(access_key)) return error.CorruptMetadata;
                return false;
            },
            else => return mapStoreError(err),
        };
        defer record.deinit(self.allocator);
        const credential = switch (record) {
            .active => |value| value,
            .tombstone => {
                if (self.index.containsAccessKey(access_key)) return error.CorruptMetadata;
                return false;
            },
        };
        if (self.index.accessKeyGeneration(access_key) != credential.metadata_generation) {
            return error.CorruptMetadata;
        }
        _ = self.store.tombstone(
            self.allocator,
            access_key,
            credential.metadata_generation,
        ) catch |err| return mapStoreError(err);
        if (!self.index.removeAccessKey(access_key)) return error.CorruptMetadata;
        return true;
    }

    fn loadActiveLocked(
        self: CredentialService,
        access_key: []const u8,
    ) Error!credential_domain.Credential {
        const indexed_generation = self.index.accessKeyGeneration(access_key) orelse {
            return error.CredentialNotFound;
        };
        const record = self.store.get(self.allocator, access_key) catch |err| {
            return switch (err) {
                error.NotFound => error.CorruptMetadata,
                else => mapStoreError(err),
            };
        };
        return switch (record) {
            .active => |credential| {
                if (credential.metadata_generation != indexed_generation) {
                    credential.deinit(self.allocator);
                    return error.CorruptMetadata;
                }
                return credential;
            },
            .tombstone => error.CorruptMetadata,
        };
    }

    fn decryptCredential(
        self: CredentialService,
        credential: *const credential_domain.Credential,
    ) Error![]u8 {
        const material = secret_box.open(
            self.allocator,
            self.master_key.*,
            credential.access_key,
            credential.secret_nonce,
            credential.secret_tag,
            credential.encrypted_secret,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.AuthenticationFailed => error.SecretDecryptionFailed,
            else => error.Unavailable,
        };
        const valid_length = if (credential.kind == .temporary)
            material.len == credential_domain.temporary_secret_material_length
        else
            material.len >= credential_domain.min_secret_key_length and
                material.len <= credential_domain.max_secret_key_length;
        if (!valid_length) {
            std.crypto.secureZero(u8, material);
            self.allocator.free(material);
            return error.SecretDecryptionFailed;
        }
        return material;
    }
};

fn generateAccessKey(io: std.Io) std.Io.RandomSecureError![20]u8 {
    var random: [9]u8 = undefined;
    try io.randomSecure(&random);
    const encoded = std.fmt.bytesToHex(random, .upper);
    var access_key: [20]u8 = undefined;
    @memcpy(access_key[0..2], "ZF");
    @memcpy(access_key[2..], &encoded);
    return access_key;
}

fn generateSecretKey(io: std.Io) std.Io.RandomSecureError![credential_domain.secret_key_length]u8 {
    var random: [20]u8 = undefined;
    try io.randomSecure(&random);
    return std.fmt.bytesToHex(random, .lower);
}

fn generateSessionToken(io: std.Io) std.Io.RandomSecureError![credential_domain.session_token_length]u8 {
    var random: [credential_domain.session_token_length / 2]u8 = undefined;
    try io.randomSecure(&random);
    return std.fmt.bytesToHex(random, .lower);
}

fn mapStoreError(err: credential_store_port.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotFound => error.CredentialNotFound,
        error.Conflict => error.Conflict,
        error.InvalidValue => error.CorruptMetadata,
        error.CorruptMetadata => error.CorruptMetadata,
        error.Unavailable => error.Unavailable,
    };
}

fn mapIndexError(err: index_module.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CorruptRecord => error.CorruptMetadata,
        error.Unavailable => error.Unavailable,
    };
}

test "credential service encrypts persists disables and deletes access keys" {
    const MemoryMetadataRepository = @import("../testing/memory_metadata_repository.zig").MemoryMetadataRepository;
    const MetadataCredentialStore = @import("../metadata/credential_store.zig").MetadataCredentialStore;
    var memory = MemoryMetadataRepository.init(std.testing.allocator);
    defer memory.deinit();
    var adapter = MetadataCredentialStore.init(memory.interface());
    var index = index_module.MetadataIndex.init(std.testing.allocator);
    defer index.deinit();
    try index.rebuild(memory.interface());
    var mutex: std.Io.Mutex = .init;
    const master_key = [_]u8{0x42} ** @sizeOf(secret_box.Key);
    const service = CredentialService.init(
        std.testing.allocator,
        std.testing.io,
        adapter.interface(),
        &index,
        &mutex,
        &master_key,
    );

    var created = try service.create("tenant-a", .read_only);
    defer created.deinit(std.testing.allocator);
    try std.testing.expect(created.credential.policy.allows(.get_object));
    try std.testing.expect(!created.credential.policy.allows(.put_object));
    try std.testing.expect(!std.mem.eql(
        u8,
        &created.secret_key,
        created.credential.encrypted_secret,
    ));

    var auth = try service.resolveForAuth(created.credential.access_key);
    defer auth.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(&created.secret_key, auth.secret_key);
    const disabled = try service.update(created.credential.access_key, .{ .enabled = false });
    defer disabled.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.CredentialDisabled,
        service.resolveForAuth(created.credential.access_key),
    );
    try std.testing.expect(try service.delete(created.credential.access_key));
    try std.testing.expect(!(try service.delete(created.credential.access_key)));
}

test "credential service persists temporary token lists secrets and rejects expiry" {
    const MemoryMetadataRepository = @import("../testing/memory_metadata_repository.zig").MemoryMetadataRepository;
    const MetadataCredentialStore = @import("../metadata/credential_store.zig").MetadataCredentialStore;
    var memory = MemoryMetadataRepository.init(std.testing.allocator);
    defer memory.deinit();
    var adapter = MetadataCredentialStore.init(memory.interface());
    var index = index_module.MetadataIndex.init(std.testing.allocator);
    defer index.deinit();
    try index.rebuild(memory.interface());
    var mutex: std.Io.Mutex = .init;
    const master_key = [_]u8{0x24} ** @sizeOf(secret_box.Key);
    const service = CredentialService.init(
        std.testing.allocator,
        std.testing.io,
        adapter.interface(),
        &index,
        &mutex,
        &master_key,
    );

    try std.testing.expectError(error.InvalidTTL, service.createWithTTL("tenant-a", .all, 59));
    var created = try service.createWithTTL("tenant-a", .all, 3600);
    defer created.deinit(std.testing.allocator);
    try std.testing.expectEqual(credential_domain.Kind.temporary, created.credential.kind);
    try std.testing.expect(created.session_token != null);

    var auth = try service.resolveForAuth(created.credential.access_key);
    defer auth.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(&created.secret_key, auth.secret_key);
    try std.testing.expectEqualStrings(&created.session_token.?, auth.session_token.?);

    const listed = try service.list();
    defer listed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), listed.credentials.len);
    try std.testing.expectEqualStrings(&created.secret_key, listed.credentials[0].secret_key);
    try std.testing.expectEqualStrings(&created.session_token.?, listed.credentials[0].session_token.?);

    const current = try service.get(created.credential.access_key);
    defer current.deinit(std.testing.allocator);
    var expired_view = current.view();
    expired_view.created_at_unix_seconds -= 2;
    expired_view.expires_at_unix_seconds = current.created_at_unix_seconds - 1;
    var prepared = try index.prepareAccessKey(current.access_key);
    defer prepared.deinit(index.allocator);
    const expired_generation = try adapter.interface().put(
        std.testing.allocator,
        expired_view,
        .{ .exact = current.metadata_generation },
    );
    index.publishAccessKey(&prepared, expired_generation);
    try std.testing.expectError(
        error.CredentialExpired,
        service.resolveForAuth(created.credential.access_key),
    );
}
