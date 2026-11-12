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
    InvalidSecretKey,
    InvalidPolicy,
    InvalidMetadata,
    InvalidExpiration,
    Conflict,
    CorruptMetadata,
    SecretDecryptionFailed,
    Unavailable,
};

pub const CreateResult = struct {
    credential: credential_domain.Credential,
    secret_key: []u8,
    session_token: ?[credential_domain.session_token_length]u8 = null,

    pub fn deinit(self: *CreateResult, allocator: std.mem.Allocator) void {
        self.credential.deinit(allocator);
        std.crypto.secureZero(u8, self.secret_key);
        allocator.free(self.secret_key);
        if (self.session_token) |*token| std.crypto.secureZero(u8, token);
        self.* = undefined;
    }
};

pub const AuthMaterial = struct {
    inherited_documents: ?[][]u8 = null,
    boundary_documents: ?[][]u8 = null,
    key_document: ?[]u8 = null,
    subject_id: ?[]u8 = null,
    token_issue_time: ?i64 = null,
    principal_tags: ?[]u8 = null,

    owner: []u8,
    policy: credential_domain.Policy,
    secret_key: []u8,
    session_token: ?[]u8,

    pub fn allowsInherited(self: AuthMaterial, allocator: std.mem.Allocator, action: []const u8, bucket: ?[]const u8, key: ?[]const u8) bool {
        return self.allowsWithContext(allocator, action, bucket, key, .{});
    }
    // URL creation is not authorization. Client IP/time/header conditions are
    // checked when the signed S3 request is actually consumed.
    pub fn allowsPresign(self: AuthMaterial, allocator: std.mem.Allocator, action: []const u8, bucket: ?[]const u8, key: ?[]const u8) bool {
        const entries = [_]@import("../auth/iam_policy.zig").Entry{
            .{ .key = "aws:username", .value = if (std.mem.startsWith(u8, self.owner, "user:")) self.owner[5..] else self.owner },
            .{ .key = "aws:userid", .value = self.owner },
        };
        return self.allowsWithContext(allocator, action, bucket, key, .{ .entries = &entries, .defer_conditions = true });
    }
    pub fn allowsWithContext(self: AuthMaterial, allocator: std.mem.Allocator, action: []const u8, bucket: ?[]const u8, key: ?[]const u8, context: @import("../auth/iam_policy.zig").Context) bool {
        const resource = if (bucket) |name| if (key) |object| std.fmt.allocPrint(allocator, "arn:aws:s3:::{s}/{s}", .{ name, object }) catch return false else std.fmt.allocPrint(allocator, "arn:aws:s3:::{s}", .{name}) catch return false else allocator.dupe(u8, "arn:aws:s3:::*") catch return false;
        defer allocator.free(resource);
        const evaluator = @import("../auth/iam_policy.zig");
        if (self.key_document) |document| {
            var key_context = context;
            key_context.kind = .key_restriction;
            if (!evaluator.allowsWithContext(allocator, &[_][]const u8{document}, action, resource, key_context)) return false;
        }
        const identity_decision = if (self.inherited_documents) |documents| evaluator.decisionWithContext(allocator, documents, action, resource, context) else evaluator.Decision.allow;
        var boundary_context = context;
        boundary_context.kind = .permission_boundary;
        const boundary_decision = if (self.boundary_documents) |documents| evaluator.decisionWithContext(allocator, documents, action, resource, boundary_context) else evaluator.Decision.allow;
        var resource_context = context;
        resource_context.kind = .resource;
        const resource_decision = if (context.resource_document) |document| evaluator.decisionWithContext(allocator, &[_][]const u8{document}, action, resource, resource_context) else evaluator.Decision.none;
        if (identity_decision == .deny or boundary_decision != .allow or resource_decision == .deny) return false;
        return identity_decision == .allow or resource_decision == .allow;
    }
    pub fn allowsKms(self: AuthMaterial, allocator: std.mem.Allocator, action: []const u8, key: []const u8, context: @import("../auth/iam_policy.zig").Context) bool {
        const evaluator = @import("../auth/iam_policy.zig");
        const resource = std.fmt.allocPrint(allocator, "arn:aws:kms:::key/{s}", .{key}) catch return false;
        defer allocator.free(resource);
        var ctx = context;
        ctx.resource_document = null;
        if (self.inherited_documents) |documents| if (!evaluator.allowsWithContext(allocator, documents, action, resource, ctx)) return false;
        if (self.key_document) |document| {
            ctx.kind = .key_restriction;
            if (!evaluator.allowsWithContext(allocator, &[_][]const u8{document}, action, resource, ctx)) return false;
        }
        if (self.boundary_documents) |documents| {
            ctx.kind = .permission_boundary;
            if (!evaluator.allowsWithContext(allocator, documents, action, resource, ctx)) return false;
        }
        return true;
    }
    pub fn deinit(self: *AuthMaterial, allocator: std.mem.Allocator) void {
        if (self.subject_id) |subject| allocator.free(subject);
        if (self.principal_tags) |tags| allocator.free(tags);
        if (self.key_document) |document| allocator.free(document);
        if (self.inherited_documents) |documents| {
            for (documents) |document| allocator.free(document);
            allocator.free(documents);
        }
        if (self.boundary_documents) |documents| {
            for (documents) |document| allocator.free(document);
            allocator.free(documents);
        }

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
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    inherit_policy: ?bool = null,
    expires_at: ?i64 = null,
    clear_expiry: bool = false,
    policy_document: ?[]const u8 = null,

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

pub const CreateOptions = struct {
    access_key: ?[]const u8 = null,
    secret_key: ?[]const u8 = null,
    ttl_seconds: ?u64 = null,
    expires_at: ?i64 = null,
    name: []const u8 = "",
    description: []const u8 = "",
    inherit_policy: bool = false,
    policy_document: []const u8 = "",
};

pub const CredentialService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: credential_store_port.CredentialStore,
    index: *index_module.MetadataIndex,
    mutex: *std.Io.Mutex,
    master_key: *const secret_box.Key,
    root_access_key: []const u8 = "",
    root_secret_key: []const u8 = "",
    root_username: []const u8 = "admin",
    identity_root: ?std.Io.Dir = null,
    identity_mutex: ?*std.Io.Mutex = null,

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
        return self.createWithOptions(owner, policy, .{ .ttl_seconds = ttl_seconds });
    }

    pub fn createWithOptions(self: CredentialService, owner: []const u8, policy: credential_domain.Policy, options: CreateOptions) Error!CreateResult {
        const ttl_seconds = options.ttl_seconds;
        try validateKeyDocument(self.allocator, options.policy_document);
        if (options.access_key) |key| credential_domain.validateAccessKey(key) catch return error.InvalidAccessKey;
        if (options.secret_key) |key| {
            if (key.len < 32 or key.len > 64 or (ttl_seconds != null and key.len != 40)) return error.InvalidSecretKey;
            for (key) |c| if (c < 33 or c > 126) return error.InvalidSecretKey;
        }
        if (options.name.len > 128 or options.description.len > 1024 or !std.unicode.utf8ValidateSlice(options.name) or !std.unicode.utf8ValidateSlice(options.description)) return error.InvalidMetadata;
        if (options.expires_at) |expiry| if (ttl_seconds != null or expiry <= std.Io.Clock.real.now(self.io).toSeconds()) return error.InvalidExpiration;
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
            const generated_access_key = generateAccessKey(self.io) catch return error.Unavailable;
            const access_key = options.access_key orelse &generated_access_key;
            if (std.mem.eql(u8, access_key, self.root_access_key)) {
                if (options.access_key != null) return error.Conflict;
                continue;
            }
            var expected_generation: credential_store_port.ExpectedGeneration = .missing;
            const current = self.store.get(self.allocator, access_key) catch |err| switch (err) {
                error.NotFound => null,
                else => return mapStoreError(err),
            };
            if (current) |record| switch (record) {
                .active => |credential| {
                    credential.deinit(self.allocator);
                    if (options.access_key != null) return error.Conflict;
                    continue;
                },
                .tombstone => |generation| {
                    if (self.index.containsAccessKey(access_key)) return error.CorruptMetadata;
                    expected_generation = .{ .exact = generation };
                },
            } else if (self.index.containsAccessKey(access_key)) {
                return error.CorruptMetadata;
            }

            const generated_secret = generateSecretKey(self.io) catch return error.Unavailable;
            const secret_key = self.allocator.dupe(u8, options.secret_key orelse &generated_secret) catch return error.OutOfMemory;
            errdefer {
                std.crypto.secureZero(u8, secret_key);
                self.allocator.free(secret_key);
            }
            var session_token: ?[credential_domain.session_token_length]u8 = if (ttl_seconds != null)
                generateSessionToken(self.io) catch return error.Unavailable
            else
                null;
            errdefer if (session_token) |*token| std.crypto.secureZero(u8, token);
            var secret_material: [credential_domain.max_secret_key_length + credential_domain.session_token_length]u8 = undefined;
            defer std.crypto.secureZero(u8, &secret_material);
            @memcpy(secret_material[0..secret_key.len], secret_key);
            const secret_material_length = if (session_token) |token| material: {
                @memcpy(secret_material[secret_key.len..][0..token.len], &token);
                break :material secret_key.len + token.len;
            } else secret_key.len;
            const sealed = secret_box.seal(
                self.allocator,
                self.io,
                self.master_key.*,
                access_key,
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
                options.expires_at;
            const value: credential_domain.View = .{
                .access_key = access_key,
                .owner = owner,
                .status = .active,
                .policy = policy,
                .created_at_unix_seconds = created_at,
                .secret_nonce = sealed.nonce,
                .secret_tag = sealed.tag,
                .encrypted_secret = sealed.ciphertext,
                .kind = if (ttl_seconds == null) .permanent else .temporary,
                .expires_at_unix_seconds = expires_at,
                .name = options.name,
                .description = options.description,
                .inherit_policy = options.inherit_policy,
                .policy_document = options.policy_document,
            };
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
        if (self.root_access_key.len > 0 and std.mem.eql(u8, access_key, self.root_access_key)) {
            var material: AuthMaterial = .{ .owner = try std.fmt.allocPrint(self.allocator, "user:{s}", .{self.root_username}), .policy = .all, .secret_key = &.{}, .session_token = null };
            errdefer material.deinit(self.allocator);
            material.secret_key = try self.allocator.dupe(u8, self.root_secret_key);
            material.subject_id = try self.allocator.dupe(u8, "deployment-root");
            material.key_document = try self.allocator.dupe(u8, "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"*\",\"Resource\":\"*\"}]}");
            return material;
        }
        if (self.identity_mutex) |mutex| mutex.lockUncancelable(self.io);
        defer if (self.identity_mutex) |mutex| mutex.unlock(self.io);
        credential_domain.validateAccessKey(access_key) catch return error.InvalidAccessKey;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const credential = try self.loadActiveLocked(access_key);
        defer credential.deinit(self.allocator);
        if (credential.status == .disabled) return error.CredentialDisabled;
        var subject_id: ?[]u8 = null;
        var principal_tags: ?[]u8 = null;
        errdefer if (subject_id) |subject| self.allocator.free(subject);
        errdefer if (principal_tags) |tags| self.allocator.free(tags);
        var inherited_documents: ?[][]u8 = null;
        errdefer if (inherited_documents) |documents| {
            for (documents) |document| self.allocator.free(document);
            self.allocator.free(documents);
        };
        var boundary_documents: ?[][]u8 = null;
        errdefer if (boundary_documents) |documents| {
            for (documents) |document| self.allocator.free(document);
            self.allocator.free(documents);
        };
        if (std.mem.startsWith(u8, credential.owner, "user:")) {
            const identities = @import("identity_store.zig");
            const root = self.identity_root orelse return error.Unavailable;
            const snapshot = identities.load(root, self.io, self.allocator) catch return error.Unavailable;
            defer snapshot.deinit();
            const index = identities.find(snapshot.value.users, credential.owner["user:".len..]) orelse return error.CredentialDisabled;
            if (!snapshot.value.users[index].enabled) return error.CredentialDisabled;
            subject_id = self.allocator.dupe(u8, snapshot.value.users[index].id) catch return error.OutOfMemory;
            if (snapshot.value.users[index].tags_json) |tags| principal_tags = self.allocator.dupe(u8, tags) catch return error.OutOfMemory;
            if (credential.inherit_policy) { // An inherited key is bounded by its parent authorization.
                const policy_store = @import("policy_store.zig");
                const policies = policy_store.load(root, self.io, self.allocator) catch return error.Unavailable;
                defer policies.deinit();
                const documents = identities.documentsForUser(self.allocator, snapshot.value.users[index], snapshot.value, policies.value) catch return error.Unavailable;
                // An identity with no attached policies has no additional IAM
                // restriction. Keep the optional unset so the coarse access-key
                // policy remains effective; an empty document set would be
                // evaluated as an implicit deny.
                if (documents.len == 0 and !credential.inherit_policy) {
                    self.allocator.free(documents);
                } else {
                    inherited_documents = documents;
                }
            }
        } else if (std.mem.startsWith(u8, credential.owner, "oidc:")) {
            const oidc = @import("oidc_auth.zig");
            const root = self.identity_root orelse return error.Unavailable;
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const session = (oidc.resolve(a, root, self.io, self.master_key.*, credential.owner["oidc:".len..], std.Io.Clock.real.now(self.io).toSeconds()) catch return error.Unavailable) orelse return error.CredentialDisabled;
            subject_id = try self.allocator.dupe(u8, session.subject_id);
            inherited_documents = oidc.documents(self.allocator, root, self.io, session) catch return error.Unavailable;
        } else if (std.mem.startsWith(u8, credential.owner, "role:")) {
            const role_store = @import("role_store.zig");
            const root = self.identity_root orelse return error.Unavailable;
            const snapshot = role_store.load(root, self.io, self.allocator) catch return error.Unavailable;
            defer snapshot.deinit();
            const suffix = credential.owner["role:".len..];
            const split = std.mem.indexOfScalar(u8, suffix, ':') orelse return error.CredentialDisabled;
            const role_id = suffix[0..split];
            const session = role_store.findSession(snapshot.value, access_key) orelse return error.CredentialDisabled;
            if (!std.mem.eql(u8, session.role_id, role_id) or session.revoked or session.expires_at <= std.Io.Clock.real.now(self.io).toSeconds()) return error.CredentialExpired;
            const role = role_store.findRole(snapshot.value, role_id) orelse return error.CredentialDisabled;
            if (!role.enabled) return error.CredentialDisabled;
            subject_id = self.allocator.dupe(u8, session.subject_id) catch return error.OutOfMemory;
            if (session.session_tags_json) |tags| principal_tags = self.allocator.dupe(u8, tags) catch return error.OutOfMemory else if (role.tags_json) |tags| principal_tags = self.allocator.dupe(u8, tags) catch return error.OutOfMemory;
            const policy_store = @import("policy_store.zig");
            const policies = policy_store.load(root, self.io, self.allocator) catch return error.Unavailable;
            defer policies.deinit();
            var documents: std.ArrayList([]u8) = .empty;
            for (role.policies) |name| for (policies.value) |policy| if (std.mem.eql(u8, policy.name, name)) try documents.append(self.allocator, try self.allocator.dupe(u8, policy.document));
            if (role.permissions_boundary) |name| {
                for (policies.value) |policy| {
                    if (std.mem.eql(u8, policy.name, name)) {
                        var boundaries: std.ArrayList([]u8) = .empty;
                        try boundaries.append(self.allocator, try self.allocator.dupe(u8, policy.document));
                        boundary_documents = try boundaries.toOwnedSlice(self.allocator);
                    }
                }
            }
            const owned_documents = try documents.toOwnedSlice(self.allocator);
            if (owned_documents.len == 0 and !credential.inherit_policy) {
                self.allocator.free(owned_documents);
            } else {
                inherited_documents = owned_documents;
            }
        }

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
        const key_document = if (credential.policy_document.len > 0) self.allocator.dupe(u8, credential.policy_document) catch {
            if (session_token) |token| {
                std.crypto.secureZero(u8, token);
                self.allocator.free(token);
            }
            return error.OutOfMemory;
        } else null;
        return .{
            .owner = owner,
            .policy = if (credential.inherit_policy) .{ .bypass_governance_retention = true } else credential.policy,
            .inherited_documents = inherited_documents,
            .boundary_documents = boundary_documents,
            .subject_id = subject_id,
            .token_issue_time = if (credential.kind == .temporary) credential.created_at_unix_seconds else null,
            .principal_tags = principal_tags,
            .key_document = key_document,
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
        if (update_value.name) |name| value.name = name;
        if (update_value.description) |description| value.description = description;
        if (update_value.inherit_policy) |inherit| value.inherit_policy = inherit;
        if (update_value.policy_document) |document| {
            try validateKeyDocument(self.allocator, document);
            value.policy_document = document;
        }
        if (update_value.clear_expiry) {
            if (update_value.expires_at != null or current.kind == .temporary) return error.InvalidExpiration;
            value.expires_at_unix_seconds = null;
        }
        if (update_value.expires_at) |expiry| {
            if (expiry <= std.Io.Clock.real.now(self.io).toSeconds()) return error.InvalidExpiration;
            value.expires_at_unix_seconds = expiry;
        }
        credential_domain.validateView(value) catch |err| return if (err == error.InvalidExpiration) error.InvalidExpiration else error.InvalidMetadata;

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
    const master_key = @as([@sizeOf(secret_box.Key)]u8, @splat(0x42));
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
        created.secret_key,
        created.credential.encrypted_secret,
    ));

    var auth = try service.resolveForAuth(created.credential.access_key);
    defer auth.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(created.secret_key, auth.secret_key);
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
    const master_key = @as([@sizeOf(secret_box.Key)]u8, @splat(0x24));
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
    try std.testing.expectEqualStrings(created.secret_key, auth.secret_key);
    try std.testing.expectEqualStrings(&created.session_token.?, auth.session_token.?);

    const listed = try service.list();
    defer listed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), listed.credentials.len);
    try std.testing.expectEqualStrings(created.secret_key, listed.credentials[0].secret_key);
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

test "managed user credentials require an enabled existing identity and fail closed" {
    const identities = @import("identity_store.zig");
    const MemoryMetadataRepository = @import("../testing/memory_metadata_repository.zig").MemoryMetadataRepository;
    const MetadataCredentialStore = @import("../metadata/credential_store.zig").MetadataCredentialStore;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var memory = MemoryMetadataRepository.init(a);
    defer memory.deinit();
    var adapter = MetadataCredentialStore.init(memory.interface());
    var index = index_module.MetadataIndex.init(a);
    defer index.deinit();
    try index.rebuild(memory.interface());
    var mutex: std.Io.Mutex = .init;
    var identity_mutex: std.Io.Mutex = .init;
    const master_key = @as([@sizeOf(secret_box.Key)]u8, @splat(0x42));
    var service = CredentialService.init(a, io, adapter.interface(), &index, &mutex, &master_key);
    service.identity_root = tmp.dir;
    service.identity_mutex = &identity_mutex;
    var created = try service.create("user:alice", .read_only);
    defer created.deinit(a);
    try std.testing.expectError(error.CredentialDisabled, service.resolveForAuth(created.credential.access_key));
    try identities.save(tmp.dir, io, a, .{ .users = &.{.{ .name = "alice" }} });
    {
        var auth = try service.resolveForAuth(created.credential.access_key);
        defer auth.deinit(a);
        try std.testing.expectEqualStrings("user:alice", auth.owner);
        try std.testing.expect(!auth.policy.allows(.put_object));
    }
    try identities.save(tmp.dir, io, a, .{ .users = &.{.{ .name = "alice", .enabled = false }} });
    try std.testing.expectError(error.CredentialDisabled, service.resolveForAuth(created.credential.access_key));
    try identities.save(tmp.dir, io, a, .{});
    try std.testing.expectError(error.CredentialDisabled, service.resolveForAuth(created.credential.access_key));
    try tmp.dir.writeFile(io, .{ .sub_path = identities.path, .data = "invalid json" });
    try std.testing.expectError(error.Unavailable, service.resolveForAuth(created.credential.access_key));
    // Legacy admin credentials remain independent of the identity store.
    var admin = try service.create("alice", .all);
    defer admin.deinit(a);
    var auth = try service.resolveForAuth(admin.credential.access_key);
    defer auth.deinit(a);
    try std.testing.expectEqualStrings("alice", auth.owner);
}

test "custom access keys persist metadata reject duplicates and validate absolute expiry" {
    const MemoryMetadataRepository = @import("../testing/memory_metadata_repository.zig").MemoryMetadataRepository;
    const MetadataCredentialStore = @import("../metadata/credential_store.zig").MetadataCredentialStore;
    const a = std.testing.allocator;
    var memory = MemoryMetadataRepository.init(a);
    defer memory.deinit();
    var adapter = MetadataCredentialStore.init(memory.interface());
    var index = index_module.MetadataIndex.init(a);
    defer index.deinit();
    try index.rebuild(memory.interface());
    var mutex: std.Io.Mutex = .init;
    const master_key = @as([@sizeOf(secret_box.Key)]u8, @splat(0x42));
    const service = CredentialService.init(a, std.testing.io, adapter.interface(), &index, &mutex, &master_key);
    const expiry = std.Io.Clock.real.now(std.testing.io).toSeconds() + 86400 * 30;
    const options: CreateOptions = .{ .access_key = "CustomMixedKey1234567", .secret_key = "custom-secret-with-32-characters!", .name = "backup", .description = "nightly job", .expires_at = expiry, .inherit_policy = true };
    // 32 is the minimum, not a fixed generated-secret length.
    var valid = options;
    valid.secret_key = "0123456789abcdef0123456789abcdef";
    var created = try service.createWithOptions("admin", .read_only, valid);
    defer created.deinit(a);
    try std.testing.expectEqualStrings(valid.access_key.?, created.credential.access_key);
    try std.testing.expectEqualStrings(valid.secret_key.?, created.secret_key);
    try std.testing.expectEqualStrings("backup", created.credential.name);
    try std.testing.expectEqualStrings("nightly job", created.credential.description);
    try std.testing.expectEqual(expiry, created.credential.expires_at_unix_seconds.?);
    try std.testing.expectError(error.Conflict, service.createWithOptions("admin", .all, valid));
    var auth = try service.resolveForAuth(created.credential.access_key);
    defer auth.deinit(a);
    try std.testing.expect(auth.policy.allows(.put_object));
    try std.testing.expectEqualStrings(valid.secret_key.?, auth.secret_key);
    try std.testing.expectError(error.InvalidExpiration, service.createWithOptions("admin", .all, .{ .expires_at = 1 }));
    try std.testing.expectError(error.InvalidSecretKey, service.createWithOptions("admin", .all, .{ .secret_key = "short" }));
}

fn validateKeyDocument(allocator: std.mem.Allocator, document: []const u8) Error!void {
    if (document.len == 0) return;
    @import("policy_store.zig").validate(allocator, .{ .name = "credential", .document = document }) catch return error.InvalidPolicy;
}
