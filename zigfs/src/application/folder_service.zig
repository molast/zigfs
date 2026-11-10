const std = @import("std");
const directory = @import("directory_service.zig");
const object = @import("object_service.zig");
const multipart = @import("multipart_service.zig");
const gc = @import("object_gc.zig");

pub const Error = directory.Error || object.Error || multipart.Error || gc.Error;

pub const FolderService = struct {
    allocator: std.mem.Allocator,
    directories: directory.DirectoryService,
    objects: object.ObjectService,
    uploads: multipart.MultipartService,
    garbage: gc.ObjectGcService,

    pub fn delete(self: FolderService, bucket: []const u8, key: []const u8, all_versions: bool, force: bool) Error!void {
        @import("../domain/directory.zig").validate(bucket, key) catch return error.InvalidDirectoryKey;
        // Never treat a root delimiter as a folder-wide deletion request.
        if (std.mem.eql(u8, key, "/")) return error.InvalidDirectoryKey;
        // Cleanup is a repair operation, never an alias for permanent deletion.
        if (force) return self.cleanup(bucket, key);
        const versions = try self.objects.listVersions(bucket, key);
        defer versions.deinit(self.allocator);
        // Fail before mutations when a permanent deletion encounters retention.
        if (all_versions) for (versions.entries) |entry| {
            if (entry.legal_hold) return error.ObjectLocked;
            if (entry.retention_until_unix_seconds) |until| {
                if (until > std.Io.Clock.real.now(self.objects.io).toSeconds()) return error.RetentionActive;
            }
        };
        for (versions.entries) |entry| {
            if (std.mem.endsWith(u8, entry.key, "/")) continue;
            if (all_versions) {
                _ = try self.objects.deleteVersion(bucket, entry.key, entry.version_id);
            } else if (entry.is_latest and !entry.is_delete_marker) {
                _ = try self.objects.delete(bucket, entry.key);
            }
        }
        try self.directories.prune(bucket, key, all_versions);
    }

    pub fn cleanup(self: FolderService, bucket: []const u8, key: []const u8) Error!void {
        @import("../domain/directory.zig").validate(bucket, key) catch return error.InvalidDirectoryKey;
        if (std.mem.eql(u8, key, "/")) return error.InvalidDirectoryKey;
        try self.directories.repair(bucket, key);
        // The complete reachability graph protects current objects, historical
        // versions, delete markers and active multipart uploads from reclamation.
        _ = try self.garbage.collect();
    }
};
