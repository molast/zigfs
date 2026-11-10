const std = @import("std");
const kms = @import("kms.zig");
const durable = @import("../metadata/durable.zig");
const box = @import("../auth/secret_box.zig");
pub const CreateKey = struct { name: []const u8 = "", description: []const u8 = "", setAsDefault: bool = false };
pub const KeyInfo = struct {
    id: []const u8,
    name: []const u8 = "",
    description: []const u8 = "",
    status: []const u8 = "Enabled",
    algorithm: []const u8 = "AES_256",
    usage: []const u8 = "EncryptDecrypt",
    version: u64 = 1,
    createdAt: ?[]const u8 = null,
    rotatedAt: ?[]const u8 = null,
    deletionDate: ?[]const u8 = null,
    manageable: bool = true,
};
pub const KeyList = struct { items: []const KeyInfo, canCreate: bool, canRekey: bool = false };
fn info(record: kms.LocalKey) KeyInfo {
    return .{ .id = record.key_id, .name = record.name, .description = record.description, .status = record.status, .version = record.version, .createdAt = record.created_at, .rotatedAt = record.rotated_at, .deletionDate = record.deletion_date };
}
fn now(service: *kms.Service, a: std.mem.Allocator, offset: i64) ![]const u8 {
    var buffer: [20]u8 = undefined;
    return a.dupe(u8, try @import("../common/time.zig").formatIso8601(std.Io.Clock.real.now(service.io).toSeconds() + offset, &buffer));
}
fn recordRead(service: *kms.Service, a: std.mem.Allocator, dir: std.Io.Dir, name: []const u8) !kms.LocalKey {
    const bytes = try dir.readFileAlloc(service.io, try std.fmt.allocPrint(a, "{s}.key", .{name}), a, .limited(128 * 1024));
    if (bytes.len == 32) return .{ .key_id = name, .created_at = "", .encrypted_key_material = try kms.base64(a, bytes) };
    const parsed = try std.json.parseFromSlice(kms.LocalKey, a, bytes, .{ .allocate = .alloc_always });
    if (!std.mem.eql(u8, parsed.value.key_id, name)) return error.InvalidKmsStore;
    return parsed.value;
}
fn recordWrite(service: *kms.Service, a: std.mem.Allocator, dir: std.Io.Dir, config: kms.Config, record: kms.LocalKey, replace: bool) !void {
    const path = try std.fmt.allocPrint(a, "{s}.key", .{record.key_id});
    const encoded = try std.json.Stringify.valueAlloc(a, record, .{ .whitespace = .indent_2 });
    if (encoded.len > 128 * 1024) return error.InvalidKmsStore;
    var atomic = try dir.createFileAtomic(service.io, path, .{ .replace = replace });
    defer atomic.deinit(service.io);
    try atomic.file.setPermissions(service.io, .fromMode(@intCast(try std.fmt.parseInt(u32, config.filePermissions, 10))));
    try atomic.file.writeStreamingAll(service.io, encoded);
    try atomic.file.sync(service.io);
    try atomic.replace(service.io);
    try durable.syncParent(dir, service.io, path);
}
pub fn list(service: *kms.Service, a: std.mem.Allocator) !KeyList {
    const stored = try service.current(a);
    if (std.mem.eql(u8, stored.config.backend, "static")) {
        const items = try a.alloc(KeyInfo, 1);
        items[0] = .{ .id = if (stored.config.defaultKey.len > 0) stored.config.defaultKey else "zigfs", .manageable = false };
        return .{ .items = items, .canCreate = false };
    }
    if (!std.mem.eql(u8, stored.config.backend, "local")) return remoteList(service, a, stored.config);
    var dir = try service.localDirectory(stored.config.localKeyDirectory, false);
    defer dir.close(service.io);
    var iterable = try dir.openDir(service.io, ".", .{ .iterate = true, .follow_symlinks = false });
    defer iterable.close(service.io);
    var iter = iterable.iterate();
    var items: std.ArrayList(KeyInfo) = .empty;
    while (try iter.next(service.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".key")) continue;
        const name = try a.dupe(u8, entry.name[0 .. entry.name.len - 4]);
        if (!kms.validKey(name)) continue;
        try items.append(a, info(try recordRead(service, a, dir, name)));
    }
    std.mem.sort(KeyInfo, items.items, {}, struct {
        fn less(_: void, left: KeyInfo, right: KeyInfo) bool {
            return std.mem.lessThan(u8, left.id, right.id);
        }
    }.less);
    return .{ .items = try items.toOwnedSlice(a), .canCreate = true };
}
pub fn create(service: *kms.Service, a: std.mem.Allocator, input: CreateKey) !KeyInfo {
    if (input.name.len > 256 or input.description.len > 4096 or std.mem.indexOfScalar(u8, input.name, 0) != null or std.mem.indexOfScalar(u8, input.description, 0) != null) return error.InvalidKmsKeyRequest;
    var stored = try service.current(a);
    const name = try a.dupe(u8, &std.fmt.bytesToHex(try @import("../common/id.zig").randomV4(service.io), .lower));
    var result: KeyInfo = undefined;
    if (std.mem.eql(u8, stored.config.backend, "local")) {
        var dir = try service.localDirectory(stored.config.localKeyDirectory, true);
        defer dir.close(service.io);
        var material: box.Key = undefined;
        try service.io.randomSecure(&material);
        defer std.crypto.secureZero(u8, &material);
        const record: kms.LocalKey = .{ .key_id = name, .name = input.name, .description = input.description, .created_at = try now(service, a, 0), .encrypted_key_material = try kms.base64(a, &material) };
        try recordWrite(service, a, dir, stored.config, record, false);
        result = info(record);
    } else result = try remoteCreate(service, a, stored.config, name, input);
    if (input.setAsDefault) {
        stored = try service.current(a);
        stored.config.defaultKey = name;
        try service.write(a, kms.current_path, try std.json.Stringify.valueAlloc(a, stored, .{}));
    }
    return result;
}
pub fn act(service: *kms.Service, a: std.mem.Allocator, name: []const u8, action: []const u8) !void {
    if (!kms.validKey(name)) return error.InvalidKmsKeyRequest;
    const stored = try service.current(a);
    if (!std.mem.eql(u8, stored.config.backend, "local")) return remoteAct(service, a, stored.config, name, action);
    var dir = try service.localDirectory(stored.config.localKeyDirectory, false);
    defer dir.close(service.io);
    var record = try recordRead(service, a, dir, name);
    if (std.mem.eql(u8, action, "schedule-deletion")) {
        if (!std.mem.eql(u8, record.status, "Enabled")) return error.KmsKeyPendingDeletion;
        record.status = "PendingDeletion";
        record.deletion_date = try now(service, a, 7 * 24 * 3600);
    } else if (std.mem.eql(u8, action, "cancel-deletion")) {
        if (!std.mem.eql(u8, record.status, "PendingDeletion")) return error.KmsKeyDeletionNotScheduled;
        record.status = "Enabled";
        record.deletion_date = null;
    } else if (std.mem.eql(u8, action, "delete")) {
        if (!std.mem.eql(u8, record.status, "PendingDeletion")) return error.KmsKeyDeletionNotScheduled;
        var deleted = info(record);
        deleted.status = "Deleted";
        try putMetadata(service, a, stored.config, deleted, false);
        try dir.deleteFile(service.io, try std.fmt.allocPrint(a, "{s}.key", .{name}));
        try durable.syncParent(dir, service.io, try std.fmt.allocPrint(a, "{s}.key", .{name}));
        return;
    } else if (std.mem.eql(u8, action, "rotate")) {
        if (!std.mem.eql(u8, record.status, "Enabled")) return error.KmsKeyPendingDeletion;
        const versions = try a.alloc(kms.LocalKeyVersion, record.previous_versions.len + 1);
        @memcpy(versions[0..record.previous_versions.len], record.previous_versions);
        versions[versions.len - 1] = .{ .version = record.version, .encrypted_key_material = record.encrypted_key_material };
        record.previous_versions = versions;
        if (record.version == std.math.maxInt(u32)) return error.InvalidKmsStore;
        record.version += 1;
        record.rotated_at = try now(service, a, 0);
        var material: box.Key = undefined;
        try service.io.randomSecure(&material);
        defer std.crypto.secureZero(u8, &material);
        record.encrypted_key_material = try kms.base64(a, &material);
    } else return error.InvalidKmsKeyRequest;
    try recordWrite(service, a, dir, stored.config, record, true);
}
pub const ManagedKey = struct { scope: []const u8, key: KeyInfo };
fn scope(a: std.mem.Allocator, config: kms.Config) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, .{ config.backend, config.address, config.namespace, config.mountPath, config.kvMount, config.keyPathPrefix, config.localKeyDirectory }, .{});
}
fn metadata(service: *kms.Service, a: std.mem.Allocator, config: kms.Config, name: []const u8) !?KeyInfo {
    const stored = try service.current(a);
    const current_scope = try scope(a, config);
    for (stored.key_metadata) |entry| if (std.mem.eql(u8, entry.scope, current_scope) and std.mem.eql(u8, entry.key.id, name)) return entry.key;
    return null;
}
fn putMetadata(service: *kms.Service, a: std.mem.Allocator, config: kms.Config, key: KeyInfo, remove: bool) !void {
    var stored = try service.current(a);
    const current_scope = try scope(a, config);
    var entries: std.ArrayList(ManagedKey) = .empty;
    for (stored.key_metadata) |entry| {
        if (std.mem.eql(u8, entry.scope, current_scope) and std.mem.eql(u8, entry.key.id, key.id)) continue;
        try entries.append(a, entry);
    }
    if (!remove) try entries.append(a, .{ .scope = current_scope, .key = key });
    stored.key_metadata = try entries.toOwnedSlice(a);
    try service.write(a, kms.current_path, try std.json.Stringify.valueAlloc(a, stored, .{}));
}
pub fn ensureEnabled(service: *kms.Service, a: std.mem.Allocator, config: kms.Config, name: []const u8) !void {
    if (std.mem.eql(u8, config.backend, "static")) return;
    if (try metadata(service, a, config, name)) |key| if (!std.mem.eql(u8, key.status, "Enabled")) return error.KmsKeyPendingDeletion;
}
fn field(v: std.json.Value, name: []const u8) !std.json.Value {
    if (v != .object) return error.KmsUnavailable;
    return v.object.get(name) orelse error.KmsUnavailable;
}
fn number(v: std.json.Value, name: []const u8) !u64 {
    const value = try field(v, name);
    if (value != .integer or value.integer < 1) return error.KmsUnavailable;
    return @intCast(value.integer);
}
fn kvPath(a: std.mem.Allocator, config: kms.Config, kind: []const u8, name: []const u8) ![]const u8 {
    const prefix = std.mem.trim(u8, config.keyPathPrefix, "/");
    return std.fmt.allocPrint(a, "{s}/{s}/{s}{s}{s}", .{ config.kvMount, kind, prefix, if (prefix.len > 0) "/" else "", name });
}
fn remoteInfo(service: *kms.Service, a: std.mem.Allocator, config: kms.Config, name: []const u8) !KeyInfo {
    const transit = std.mem.eql(u8, config.backend, "vault");
    const response = try service.vault(a, config, if (transit) try std.fmt.allocPrint(a, "{s}/keys/{s}", .{ config.mountPath, name }) else try kvPath(a, config, "metadata", name), null);
    const data = try field(response, "data");
    var key: KeyInfo = (try metadata(service, a, config, name)) orelse .{ .id = name };
    key.version = try number(data, if (transit) "latest_version" else "current_version");
    if (!transit) {
        if (data.object.get("created_time")) |created| if (created == .string) {
            key.createdAt = created.string;
        };
    }
    return key;
}
fn remoteList(service: *kms.Service, a: std.mem.Allocator, config: kms.Config) !KeyList {
    const transit = std.mem.eql(u8, config.backend, "vault");
    const path = if (transit) try std.fmt.allocPrint(a, "{s}/keys?list=true", .{config.mountPath}) else try std.fmt.allocPrint(a, "{s}?list=true", .{try kvPath(a, config, "metadata", "")});
    const response = service.vault(a, config, path, null) catch |err| switch (err) {
        error.KmsVaultKeyNotFound => return .{ .items = &.{}, .canCreate = true },
        else => return err,
    };
    const keys = try field(try field(response, "data"), "keys");
    if (keys != .array) return error.KmsUnavailable;
    var items: std.ArrayList(KeyInfo) = .empty;
    for (keys.array.items) |item| {
        if (item != .string or !kms.validKey(item.string)) continue;
        try items.append(a, try remoteInfo(service, a, config, item.string));
    }
    return .{ .items = try items.toOwnedSlice(a), .canCreate = true };
}
fn remoteCreate(service: *kms.Service, a: std.mem.Allocator, config: kms.Config, name: []const u8, input: CreateKey) !KeyInfo {
    if (std.mem.eql(u8, config.backend, "vault")) {
        _ = try service.vault(a, config, try std.fmt.allocPrint(a, "{s}/keys/{s}", .{ config.mountPath, name }), try std.json.Stringify.valueAlloc(a, .{ .type = "aes256-gcm96" }, .{}));
    } else if (std.mem.eql(u8, config.backend, "vault-kv2")) {
        var material: box.Key = undefined;
        try service.io.randomSecure(&material);
        defer std.crypto.secureZero(u8, &material);
        _ = try service.vault(a, config, try kvPath(a, config, "data", name), try std.json.Stringify.valueAlloc(a, .{ .options = .{ .cas = @as(u64, 0) }, .data = .{ .key = try kms.base64(a, &material) } }, .{}));
    } else return error.KmsKeyOperationUnsupported;
    const result: KeyInfo = .{ .id = name, .name = input.name, .description = input.description, .createdAt = try now(service, a, 0) };
    try putMetadata(service, a, config, result, false);
    return result;
}
fn remoteAct(service: *kms.Service, a: std.mem.Allocator, config: kms.Config, name: []const u8, action: []const u8) !void {
    if (std.mem.eql(u8, config.backend, "static")) return error.KmsKeyOperationUnsupported;
    var key = try remoteInfo(service, a, config, name);
    const transit = std.mem.eql(u8, config.backend, "vault");
    if (std.mem.eql(u8, action, "schedule-deletion")) {
        if (!std.mem.eql(u8, key.status, "Enabled")) return error.KmsKeyPendingDeletion;
        key.status = "PendingDeletion";
        key.deletionDate = try now(service, a, 7 * 24 * 3600);
    } else if (std.mem.eql(u8, action, "cancel-deletion")) {
        if (!std.mem.eql(u8, key.status, "PendingDeletion")) return error.KmsKeyDeletionNotScheduled;
        key.status = "Enabled";
        key.deletionDate = null;
    } else if (std.mem.eql(u8, action, "rotate")) {
        if (!std.mem.eql(u8, key.status, "Enabled")) return error.KmsKeyPendingDeletion;
        if (transit) {
            _ = try service.vault(a, config, try std.fmt.allocPrint(a, "{s}/keys/{s}/rotate", .{ config.mountPath, name }), "{}");
        } else {
            var material: box.Key = undefined;
            try service.io.randomSecure(&material);
            defer std.crypto.secureZero(u8, &material);
            _ = try service.vault(a, config, try kvPath(a, config, "data", name), try std.json.Stringify.valueAlloc(a, .{ .options = .{ .cas = key.version }, .data = .{ .key = try kms.base64(a, &material) } }, .{}));
        }
        key.version += 1;
        key.rotatedAt = try now(service, a, 0);
    } else if (std.mem.eql(u8, action, "delete")) {
        if (!std.mem.eql(u8, key.status, "PendingDeletion")) return error.KmsKeyDeletionNotScheduled;
        if (transit) _ = try service.vault(a, config, try std.fmt.allocPrint(a, "{s}/keys/{s}/config", .{ config.mountPath, name }), try std.json.Stringify.valueAlloc(a, .{ .deletion_allowed = true }, .{}));
        _ = try service.vaultMethod(a, config, if (transit) try std.fmt.allocPrint(a, "{s}/keys/{s}", .{ config.mountPath, name }) else try kvPath(a, config, "metadata", name), null, "DELETE");
        key.status = "Deleted";
        return putMetadata(service, a, config, key, false);
    } else return error.InvalidKmsKeyRequest;
    try putMetadata(service, a, config, key, false);
}
