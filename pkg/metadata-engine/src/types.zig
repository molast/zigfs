const std = @import("std");

/// Persisted namespace IDs. Append new IDs; never reorder or reuse existing IDs.
/// system is reserved for database-level records, not a catch-all for business documents.
pub const Type = enum(u8) {
    system = 1,
    bucket = 2,
    object = 3,
    multipart = 4,
    credential = 5,
    directory = 6,
    identity = 7,
    policy = 8,
    role = 9,
    bucket_policy = 10,
    object_tag = 11,
    oidc = 12,
    settings = 13,
    monitoring_settings = 14,
    log_settings = 15,
    audit_settings = 16,
    event_destination = 17,
    bucket_subscription = 18,
    kms = 19,
};

pub const namespaces = std.enums.values(Type);
pub const namespace_count = namespaces.len;

comptime {
    // Engine map offsets are persisted namespace IDs minus one.
    for (namespaces, 1..) |namespace, id| {
        if (@backingInt(namespace) != id) @compileError("namespace IDs must be contiguous");
    }
}
