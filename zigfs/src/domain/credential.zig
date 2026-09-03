const std = @import("std");

pub const min_access_key_length: usize = 16;
pub const max_access_key_length: usize = 128;
pub const min_secret_key_length: usize = 32;
pub const max_secret_key_length: usize = 64;
pub const max_owner_length: usize = 256;

pub const Status = enum(u8) {
    active = 1,
    disabled = 2,
};

pub const Action = enum {
    list_buckets,
    create_bucket,
    head_bucket,
    delete_bucket,
    list_objects,
    put_object,
    get_object,
    head_object,
    delete_object,
};

pub const Policy = struct {
    bucket_read: bool = true,
    bucket_write: bool = true,
    object_read: bool = true,
    object_write: bool = true,

    pub const all: Policy = .{};
    pub const read_only: Policy = .{
        .bucket_write = false,
        .object_write = false,
    };

    pub fn allows(self: Policy, action: Action) bool {
        return switch (action) {
            .list_buckets, .head_bucket => self.bucket_read,
            .create_bucket, .delete_bucket => self.bucket_write,
            .list_objects, .get_object, .head_object => self.object_read,
            .put_object, .delete_object => self.object_write,
        };
    }

    pub fn toBits(self: Policy) u16 {
        return @as(u16, @intFromBool(self.bucket_read)) |
            (@as(u16, @intFromBool(self.bucket_write)) << 1) |
            (@as(u16, @intFromBool(self.object_read)) << 2) |
            (@as(u16, @intFromBool(self.object_write)) << 3);
    }

    pub fn fromBits(bits: u16) error{InvalidPolicy}!Policy {
        if (bits & ~@as(u16, 0x0f) != 0) return error.InvalidPolicy;
        return .{
            .bucket_read = bits & 0x01 != 0,
            .bucket_write = bits & 0x02 != 0,
            .object_read = bits & 0x04 != 0,
            .object_write = bits & 0x08 != 0,
        };
    }
};

pub const View = struct {
    access_key: []const u8,
    owner: []const u8,
    status: Status,
    policy: Policy,
    created_at_unix_seconds: i64,
    secret_nonce: [12]u8,
    secret_tag: [16]u8,
    encrypted_secret: []const u8,
};

pub const Credential = struct {
    access_key: []u8,
    owner: []u8,
    status: Status,
    policy: Policy,
    created_at_unix_seconds: i64,
    secret_nonce: [12]u8,
    secret_tag: [16]u8,
    encrypted_secret: []u8,
    metadata_generation: u64,

    pub fn deinit(self: Credential, allocator: std.mem.Allocator) void {
        allocator.free(self.access_key);
        allocator.free(self.owner);
        allocator.free(self.encrypted_secret);
    }

    pub fn view(self: *const Credential) View {
        return .{
            .access_key = self.access_key,
            .owner = self.owner,
            .status = self.status,
            .policy = self.policy,
            .created_at_unix_seconds = self.created_at_unix_seconds,
            .secret_nonce = self.secret_nonce,
            .secret_tag = self.secret_tag,
            .encrypted_secret = self.encrypted_secret,
        };
    }
};

pub const ValidationError = error{
    InvalidAccessKey,
    InvalidOwner,
    InvalidEncryptedSecret,
    InvalidCreatedAt,
};

pub fn validateAccessKey(value: []const u8) ValidationError!void {
    if (value.len < min_access_key_length or value.len > max_access_key_length) {
        return error.InvalidAccessKey;
    }
    for (value) |character| {
        if (!std.ascii.isUpper(character) and !std.ascii.isDigit(character)) {
            return error.InvalidAccessKey;
        }
    }
}

pub fn validateOwner(value: []const u8) ValidationError!void {
    if (value.len == 0 or value.len > max_owner_length) return error.InvalidOwner;
    if (std.mem.indexOfAny(u8, value, "\x00\r\n") != null) return error.InvalidOwner;
}

pub fn validateView(value: View) ValidationError!void {
    try validateAccessKey(value.access_key);
    try validateOwner(value.owner);
    if (value.encrypted_secret.len < min_secret_key_length or
        value.encrypted_secret.len > max_secret_key_length)
    {
        return error.InvalidEncryptedSecret;
    }
    if (value.created_at_unix_seconds <= 0) return error.InvalidCreatedAt;
}

pub fn cloneFromView(
    allocator: std.mem.Allocator,
    value: View,
    metadata_generation: u64,
) std.mem.Allocator.Error!Credential {
    const access_key = try allocator.dupe(u8, value.access_key);
    errdefer allocator.free(access_key);
    const owner = try allocator.dupe(u8, value.owner);
    errdefer allocator.free(owner);
    const encrypted_secret = try allocator.dupe(u8, value.encrypted_secret);
    return .{
        .access_key = access_key,
        .owner = owner,
        .status = value.status,
        .policy = value.policy,
        .created_at_unix_seconds = value.created_at_unix_seconds,
        .secret_nonce = value.secret_nonce,
        .secret_tag = value.secret_tag,
        .encrypted_secret = encrypted_secret,
        .metadata_generation = metadata_generation,
    };
}

test "credential policy maps bucket and object permissions" {
    try std.testing.expect(Policy.all.allows(.put_object));
    try std.testing.expect(Policy.read_only.allows(.get_object));
    try std.testing.expect(!Policy.read_only.allows(.delete_object));
    try std.testing.expectEqual(Policy.all, try Policy.fromBits(Policy.all.toBits()));
    try std.testing.expectError(error.InvalidPolicy, Policy.fromBits(0x10));
}

test "credential validation rejects unsafe identifiers" {
    try validateAccessKey("ZF0123456789ABCDEF");
    try validateOwner("tenant-a");
    try std.testing.expectError(error.InvalidAccessKey, validateAccessKey("lowercase-access-key"));
    try std.testing.expectError(error.InvalidOwner, validateOwner("owner\nforged"));
}
