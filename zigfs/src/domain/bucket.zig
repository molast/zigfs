const std = @import("std");
const id = @import("../common/id.zig");

pub const min_name_length: usize = 3;
pub const max_name_length: usize = 63;
pub const max_owner_length: usize = 256;

pub const Status = enum(u8) {
    active = 1,
};

pub const Versioning = enum(u8) {
    unversioned = 0,
    enabled = 1,
    suspended = 2,
};

pub const AccessPolicy = enum(u8) {
    private = 0,
    readonly = 1,
    public = 2,
};

pub const Encryption = enum(u8) {
    disabled = 0,
    enabled = 1,
};

pub const Quota = struct {
    max_bytes: ?u64 = null,
    max_objects: ?u64 = null,
};

pub const RetentionMode = enum(u8) { governance = 1, compliance = 2 };
pub const Retention = struct {
    enabled: bool = false,
    default_duration_seconds: ?u64 = null,
    mode: ?RetentionMode = null,
};

pub const Bucket = struct {
    id: id.Uuid,
    name: []u8,
    owner: []u8,
    status: Status,
    versioning: Versioning = .unversioned,
    access_policy: AccessPolicy = .private,
    tags_json: ?[]u8 = null,
    encryption: Encryption = .disabled,
    quota: Quota = .{},
    retention: Retention = .{},
    object_locking: bool = false,
    lifecycle_configuration: ?[]u8 = null,
    created_at_unix_seconds: i64,
    generation: u64,

    pub fn deinit(self: Bucket, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.owner);
        if (self.lifecycle_configuration) |configuration| allocator.free(configuration);
        if (self.tags_json) |tags| allocator.free(tags);
    }
};

pub const ValidationError = error{
    InvalidLength,
    InvalidCharacter,
    InvalidBoundary,
    AdjacentPeriods,
    IpAddress,
    ReservedPrefix,
    ReservedSuffix,
};

pub const OwnerValidationError = error{
    InvalidOwner,
};

pub fn validateName(name: []const u8) ValidationError!void {
    if (name.len < min_name_length or name.len > max_name_length) {
        return error.InvalidLength;
    }
    for (name) |character| {
        if (!isAlphaNumeric(character) and character != '-' and character != '.') {
            return error.InvalidCharacter;
        }
    }
    if (!isAlphaNumeric(name[0]) or !isAlphaNumeric(name[name.len - 1])) {
        return error.InvalidBoundary;
    }
    if (std.mem.indexOf(u8, name, "..") != null) return error.AdjacentPeriods;
    if (isIpv4Address(name)) return error.IpAddress;

    const reserved_prefixes = [_][]const u8{
        "xn--",
        "sthree-",
        "amzn-s3-demo-",
    };
    for (reserved_prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return error.ReservedPrefix;
    }
    const reserved_suffixes = [_][]const u8{
        "-s3alias",
        "--ol-s3",
        ".mrap",
        "--x-s3",
        "--table-s3",
    };
    for (reserved_suffixes) |suffix| {
        if (std.mem.endsWith(u8, name, suffix)) return error.ReservedSuffix;
    }
}

pub fn validateOwner(owner: []const u8) OwnerValidationError!void {
    if (owner.len == 0 or
        owner.len > max_owner_length or
        std.mem.indexOfScalar(u8, owner, 0) != null)
    {
        return error.InvalidOwner;
    }
}

fn isAlphaNumeric(character: u8) bool {
    return (character >= 'a' and character <= 'z') or
        (character >= '0' and character <= '9');
}

fn isIpv4Address(name: []const u8) bool {
    _ = std.Io.net.Ip4Address.parse(name, 0) catch return false;
    return true;
}

test "accept S3 compatible bucket names" {
    const valid_names = [_][]const u8{
        "project-assets-01",
        "logs.example.internal",
        "123-bucket",
    };
    for (valid_names) |name| try validateName(name);
}

test "reject invalid bucket syntax" {
    try std.testing.expectError(error.InvalidLength, validateName("ab"));
    try std.testing.expectError(error.InvalidLength, validateName(&([_]u8{'a'} ** 64)));
    try std.testing.expectError(error.InvalidCharacter, validateName("project-Assets"));
    try std.testing.expectError(error.InvalidCharacter, validateName("project_assets"));
    try std.testing.expectError(error.InvalidBoundary, validateName("-project"));
    try std.testing.expectError(error.InvalidBoundary, validateName("project-"));
    try std.testing.expectError(error.AdjacentPeriods, validateName("project..assets"));
    try std.testing.expectError(error.IpAddress, validateName("192.168.10.2"));
}

test "reject S3 reserved bucket aliases and invalid owners" {
    try std.testing.expectError(error.ReservedPrefix, validateName("xn--project"));
    try std.testing.expectError(error.ReservedPrefix, validateName("sthree-project"));
    try std.testing.expectError(error.ReservedSuffix, validateName("project-s3alias"));
    try std.testing.expectError(error.ReservedSuffix, validateName("project--x-s3"));
    try std.testing.expectError(error.InvalidOwner, validateOwner(""));
    try std.testing.expectError(error.InvalidOwner, validateOwner("owner\x00id"));
    try validateOwner("root");
}
