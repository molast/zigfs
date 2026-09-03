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
    Conflict,
    CorruptMetadata,
    SecretDecryptionFailed,
    Unavailable,
};

pub const CreateResult = struct {
    credential: credential_domain.Credential,
    secret_key: [40]u8,

    pub fn deinit(self: *CreateResult, allocator: std.mem.Allocator) void {
        self.credential.deinit(allocator);
        std.crypto.secureZero(u8, &self.secret_key);
        self.* = undefined;
    }
};

pub const AuthMaterial = struct {
    owner: []u8,
    policy: credential_domain.Policy,
    secret_key: []u8,

    pub fn deinit(self: *AuthMaterial, allocator: std.mem.Allocator) void {
        allocator.free(self.owner);
        std.crypto.secureZero(u8, self.secret_key);
        allocator.free(self.secret_key);
        self.* = undefined;
    }
};

pub const Update = struct {
    enabled: ?bool = null,
    policy: ?credential_domain.Policy = null,
};

pub const ListResult = struct {
    credentials: []credential_domain.Credential,

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
        credential_domain.validateOwner(owner) catch return error.InvalidOwner;
        _ = credential_domain.Policy.fromBits(policy.toBits()) catch return error.CorruptMetadata;

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
            const sealed = secret_box.seal(
                self.allocator,
                self.io,
                self.master_key.*,
                &access_key,
                &secret_key,
            ) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Unavailable,
            };
            defer sealed.deinit(self.allocator);
            const created_at = std.Io.Clock.real.now(self.io).toSeconds();
            const value: credential_domain.View = .{
                .access_key = &access_key,
                .owner = owner,
                .status = .active,
                .policy = policy,
                .created_at_unix_seconds = created_at,
                .secret_nonce = sealed.nonce,
                .secret_tag = sealed.tag,
                .encrypted_secret = sealed.ciphertext,
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
            return .{ .credential = owned, .secret_key = secret_key };
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
        const owner = self.allocator.dupe(u8, credential.owner) catch return error.OutOfMemory;
        errdefer self.allocator.free(owner);
        const secret_key = secret_box.open(
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
        return .{
            .owner = owner,
            .policy = credential.policy,
            .secret_key = secret_key,
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
        const credentials = self.allocator.alloc(credential_domain.Credential, entries.len) catch {
            return error.OutOfMemory;
        };
        var initialized: usize = 0;
        errdefer {
            for (credentials[0..initialized]) |credential| credential.deinit(self.allocator);
            self.allocator.free(credentials);
        }
        for (entries, 0..) |entry, position| {
            credentials[position] = try self.loadActiveLocked(entry.name);
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

fn generateSecretKey(io: std.Io) std.Io.RandomSecureError![40]u8 {
    var random: [20]u8 = undefined;
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
