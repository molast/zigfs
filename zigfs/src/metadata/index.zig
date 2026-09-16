const std = @import("std");
const bucket_payload = @import("bucket_payload.zig");
const credential_payload = @import("credential_payload.zig");
const metadata_record = @import("record.zig");
const multipart_domain = @import("../domain/multipart.zig");
const multipart_payload = @import("multipart_payload.zig");
const object_key = @import("object_key.zig");
const object_payload = @import("object_payload.zig");
const object_history_payload = @import("object_history_payload.zig");
const directory_payload = @import("directory_payload.zig");
const repository_port = @import("../ports/metadata_repository.zig");

pub const Error = error{
    OutOfMemory,
    CorruptRecord,
    Unavailable,
};

pub const NamedEntry = struct {
    name: []u8,
    generation: u64,
};

pub const ObjectEntry = struct {
    bucket: []u8,
    key: []u8,
    generation: u64,
};

pub const DirectoryEntry = struct {
    bucket: []u8,
    key: []u8,
    generation: u64,
    last_modified_unix_seconds: i64,
};

pub const PreparedBucket = struct {
    name: ?[]u8,

    pub fn deinit(self: *PreparedBucket, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        self.name = null;
    }
};

pub const PreparedAccessKey = struct {
    access_key: ?[]u8,

    pub fn deinit(self: *PreparedAccessKey, allocator: std.mem.Allocator) void {
        if (self.access_key) |access_key| allocator.free(access_key);
        self.access_key = null;
    }
};

pub const PreparedUpload = struct {
    upload_id: ?[]u8,

    pub fn deinit(self: *PreparedUpload, allocator: std.mem.Allocator) void {
        if (self.upload_id) |upload_id| allocator.free(upload_id);
        self.upload_id = null;
    }
};

pub const PreparedObject = struct {
    bucket: ?[]u8,
    key: ?[]u8,

    pub fn deinit(self: *PreparedObject, allocator: std.mem.Allocator) void {
        if (self.bucket) |bucket| allocator.free(bucket);
        if (self.key) |key| allocator.free(key);
        self.bucket = null;
        self.key = null;
    }
};

pub const ListOptions = struct {
    prefix: []const u8 = "",
    search: []const u8 = "",
    delimiter: ?[]const u8 = null,
    start_after: ?[]const u8 = null,
    max_keys: usize = 1000,
};

pub const ListResult = struct {
    objects: [][]u8,
    common_prefixes: [][]u8,
    next_start_after: ?[]u8,

    pub fn deinit(self: ListResult, allocator: std.mem.Allocator) void {
        for (self.objects) |key| allocator.free(key);
        allocator.free(self.objects);
        for (self.common_prefixes) |prefix| allocator.free(prefix);
        allocator.free(self.common_prefixes);
        if (self.next_start_after) |cursor| allocator.free(cursor);
    }
};

pub const MetadataIndex = struct {
    allocator: std.mem.Allocator,
    buckets: std.ArrayList(NamedEntry) = .empty,
    objects: std.ArrayList(ObjectEntry) = .empty,
    directories: std.ArrayList(DirectoryEntry) = .empty,
    uploads: std.ArrayList(NamedEntry) = .empty,
    access_keys: std.ArrayList(NamedEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator) MetadataIndex {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MetadataIndex) void {
        for (self.buckets.items) |entry| self.allocator.free(entry.name);
        self.buckets.deinit(self.allocator);
        for (self.objects.items) |entry| {
            self.allocator.free(entry.bucket);
            self.allocator.free(entry.key);
        }
        self.objects.deinit(self.allocator);
        for (self.directories.items) |entry| {
            self.allocator.free(entry.bucket);
            self.allocator.free(entry.key);
        }
        self.directories.deinit(self.allocator);
        for (self.uploads.items) |entry| self.allocator.free(entry.name);
        self.uploads.deinit(self.allocator);
        for (self.access_keys.items) |entry| self.allocator.free(entry.name);
        self.access_keys.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn rebuild(
        self: *MetadataIndex,
        repository: repository_port.MetadataRepository,
    ) Error!void {
        var rebuilt = MetadataIndex.init(self.allocator);
        errdefer rebuilt.deinit();

        const indexed_types = [_]metadata_record.Type{
            .bucket,
            .object,
            .directory,
            .multipart,
            .credential,
        };
        for (indexed_types) |record_type| {
            const records = repository.scan(self.allocator, record_type) catch |err| {
                return mapRepositoryError(err);
            };
            defer records.deinit(self.allocator);
            for (records.records) |record| {
                if (record.tombstone) continue;
                try rebuilt.appendRecord(record_type, record);
            }
        }

        std.mem.sort(NamedEntry, rebuilt.buckets.items, {}, lessThanNamed);
        std.mem.sort(ObjectEntry, rebuilt.objects.items, {}, lessThanObject);
        std.mem.sort(DirectoryEntry, rebuilt.directories.items, {}, lessThanDirectory);
        std.mem.sort(NamedEntry, rebuilt.uploads.items, {}, lessThanNamed);
        std.mem.sort(NamedEntry, rebuilt.access_keys.items, {}, lessThanNamed);
        if (hasNamedDuplicate(rebuilt.buckets.items) or
            hasObjectDuplicate(rebuilt.objects.items) or
            hasDirectoryDuplicate(rebuilt.directories.items) or
            hasNamedDuplicate(rebuilt.uploads.items) or
            hasNamedDuplicate(rebuilt.access_keys.items))
        {
            return error.CorruptRecord;
        }
        for (rebuilt.objects.items) |entry| {
            if (findNamed(rebuilt.buckets.items, entry.bucket) == null) {
                return error.CorruptRecord;
            }
        }

        self.deinit();
        self.* = rebuilt;
    }

    pub fn containsBucket(self: *const MetadataIndex, name: []const u8) bool {
        return findNamed(self.buckets.items, name) != null;
    }

    pub fn bucketGeneration(self: *const MetadataIndex, name: []const u8) ?u64 {
        const position = findNamed(self.buckets.items, name) orelse return null;
        return self.buckets.items[position].generation;
    }

    pub fn bucketEntries(self: *const MetadataIndex) []const NamedEntry {
        return self.buckets.items;
    }

    pub fn prepareBucket(
        self: *MetadataIndex,
        name: []const u8,
    ) Error!PreparedBucket {
        self.buckets.ensureUnusedCapacity(self.allocator, 1) catch {
            return error.OutOfMemory;
        };
        return .{
            .name = self.allocator.dupe(u8, name) catch return error.OutOfMemory,
        };
    }

    pub fn publishBucket(
        self: *MetadataIndex,
        prepared: *PreparedBucket,
        generation: u64,
    ) void {
        const name = prepared.name orelse unreachable;
        const position = lowerBoundNamed(self.buckets.items, name);
        if (position < self.buckets.items.len and
            std.mem.eql(u8, self.buckets.items[position].name, name))
        {
            self.buckets.items[position].generation = generation;
            self.allocator.free(name);
        } else {
            self.buckets.insertAssumeCapacity(position, .{
                .name = name,
                .generation = generation,
            });
        }
        prepared.name = null;
    }

    pub fn removeBucket(self: *MetadataIndex, name: []const u8) bool {
        const position = findNamed(self.buckets.items, name) orelse return false;
        const removed = self.buckets.orderedRemove(position);
        self.allocator.free(removed.name);
        return true;
    }

    pub fn hasObjectsInBucket(self: *const MetadataIndex, bucket: []const u8) bool {
        const position = lowerBoundObject(self.objects.items, bucket, "");
        return position < self.objects.items.len and
            std.mem.eql(u8, self.objects.items[position].bucket, bucket);
    }

    pub fn containsUpload(self: *const MetadataIndex, upload_id: []const u8) bool {
        return findNamed(self.uploads.items, upload_id) != null;
    }

    pub fn uploadGeneration(self: *const MetadataIndex, upload_id: []const u8) ?u64 {
        const position = findNamed(self.uploads.items, upload_id) orelse return null;
        return self.uploads.items[position].generation;
    }

    pub fn uploadEntries(self: *const MetadataIndex) []const NamedEntry {
        return self.uploads.items;
    }

    pub fn prepareUpload(self: *MetadataIndex, upload_id: []const u8) Error!PreparedUpload {
        self.uploads.ensureUnusedCapacity(self.allocator, 1) catch return error.OutOfMemory;
        return .{ .upload_id = self.allocator.dupe(u8, upload_id) catch return error.OutOfMemory };
    }

    pub fn publishUpload(self: *MetadataIndex, prepared: *PreparedUpload, generation: u64) void {
        const upload_id = prepared.upload_id orelse unreachable;
        const position = lowerBoundNamed(self.uploads.items, upload_id);
        if (position < self.uploads.items.len and
            std.mem.eql(u8, self.uploads.items[position].name, upload_id))
        {
            self.uploads.items[position].generation = generation;
            self.allocator.free(upload_id);
        } else {
            self.uploads.insertAssumeCapacity(position, .{ .name = upload_id, .generation = generation });
        }
        prepared.upload_id = null;
    }

    pub fn removeUpload(self: *MetadataIndex, upload_id: []const u8) bool {
        const position = findNamed(self.uploads.items, upload_id) orelse return false;
        const removed = self.uploads.orderedRemove(position);
        self.allocator.free(removed.name);
        return true;
    }

    pub fn containsAccessKey(self: *const MetadataIndex, access_key: []const u8) bool {
        return findNamed(self.access_keys.items, access_key) != null;
    }

    pub fn accessKeyGeneration(self: *const MetadataIndex, access_key: []const u8) ?u64 {
        const position = findNamed(self.access_keys.items, access_key) orelse return null;
        return self.access_keys.items[position].generation;
    }

    pub fn accessKeyEntries(self: *const MetadataIndex) []const NamedEntry {
        return self.access_keys.items;
    }

    pub fn prepareAccessKey(
        self: *MetadataIndex,
        access_key: []const u8,
    ) Error!PreparedAccessKey {
        self.access_keys.ensureUnusedCapacity(self.allocator, 1) catch {
            return error.OutOfMemory;
        };
        return .{
            .access_key = self.allocator.dupe(u8, access_key) catch return error.OutOfMemory,
        };
    }

    pub fn publishAccessKey(
        self: *MetadataIndex,
        prepared: *PreparedAccessKey,
        generation: u64,
    ) void {
        const access_key = prepared.access_key orelse unreachable;
        const position = lowerBoundNamed(self.access_keys.items, access_key);
        if (position < self.access_keys.items.len and
            std.mem.eql(u8, self.access_keys.items[position].name, access_key))
        {
            self.access_keys.items[position].generation = generation;
            self.allocator.free(access_key);
        } else {
            self.access_keys.insertAssumeCapacity(position, .{
                .name = access_key,
                .generation = generation,
            });
        }
        prepared.access_key = null;
    }

    pub fn removeAccessKey(self: *MetadataIndex, access_key: []const u8) bool {
        const position = findNamed(self.access_keys.items, access_key) orelse return false;
        const removed = self.access_keys.orderedRemove(position);
        self.allocator.free(removed.name);
        return true;
    }

    pub fn containsObject(
        self: *const MetadataIndex,
        bucket: []const u8,
        key: []const u8,
    ) bool {
        const position = lowerBoundObject(self.objects.items, bucket, key);
        if (position >= self.objects.items.len) return false;
        const entry = self.objects.items[position];
        return std.mem.eql(u8, entry.bucket, bucket) and std.mem.eql(u8, entry.key, key);
    }

    pub fn objectGeneration(
        self: *const MetadataIndex,
        bucket: []const u8,
        key: []const u8,
    ) ?u64 {
        const position = lowerBoundObject(self.objects.items, bucket, key);
        if (position >= self.objects.items.len) return null;
        const entry = self.objects.items[position];
        if (!std.mem.eql(u8, entry.bucket, bucket) or
            !std.mem.eql(u8, entry.key, key))
        {
            return null;
        }
        return entry.generation;
    }

    pub fn objectEntries(self: *const MetadataIndex) []const ObjectEntry {
        return self.objects.items;
    }

    pub fn directoryEntries(self: *const MetadataIndex) []const DirectoryEntry {
        return self.directories.items;
    }

    pub fn directoryGeneration(self: *const MetadataIndex, bucket: []const u8, key: []const u8) ?u64 {
        const position = lowerBoundDirectory(self.directories.items, bucket, key);
        if (position >= self.directories.items.len) return null;
        const entry = self.directories.items[position];
        if (!std.mem.eql(u8, entry.bucket, bucket) or !std.mem.eql(u8, entry.key, key)) return null;
        return entry.generation;
    }

    pub fn directoryEntry(self: *const MetadataIndex, bucket: []const u8, key: []const u8) ?DirectoryEntry {
        const position = lowerBoundDirectory(self.directories.items, bucket, key);
        if (position >= self.directories.items.len) return null;
        const entry = self.directories.items[position];
        if (!std.mem.eql(u8, entry.bucket, bucket) or !std.mem.eql(u8, entry.key, key)) return null;
        return entry;
    }

    pub fn prepareDirectory(self: *MetadataIndex, bucket: []const u8, key: []const u8) Error!PreparedObject {
        self.directories.ensureUnusedCapacity(self.allocator, 1) catch return error.OutOfMemory;
        const owned_bucket = self.allocator.dupe(u8, bucket) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_bucket);
        return .{
            .bucket = owned_bucket,
            .key = self.allocator.dupe(u8, key) catch return error.OutOfMemory,
        };
    }

    pub fn publishDirectory(self: *MetadataIndex, prepared: *PreparedObject, generation: u64, last_modified_unix_seconds: i64) void {
        const bucket = prepared.bucket orelse unreachable;
        const key = prepared.key orelse unreachable;
        const position = lowerBoundDirectory(self.directories.items, bucket, key);
        if (position < self.directories.items.len and
            std.mem.eql(u8, self.directories.items[position].bucket, bucket) and
            std.mem.eql(u8, self.directories.items[position].key, key))
        {
            self.directories.items[position].generation = generation;
            self.directories.items[position].last_modified_unix_seconds = last_modified_unix_seconds;
            self.allocator.free(bucket);
            self.allocator.free(key);
        } else {
            self.directories.insertAssumeCapacity(position, .{
                .bucket = bucket,
                .key = key,
                .generation = generation,
                .last_modified_unix_seconds = last_modified_unix_seconds,
            });
        }
        prepared.bucket = null;
        prepared.key = null;
    }

    pub fn removeDirectory(self: *MetadataIndex, bucket: []const u8, key: []const u8) bool {
        const position = lowerBoundDirectory(self.directories.items, bucket, key);
        if (position >= self.directories.items.len) return false;
        const entry = self.directories.items[position];
        if (!std.mem.eql(u8, entry.bucket, bucket) or !std.mem.eql(u8, entry.key, key)) return false;
        const removed = self.directories.orderedRemove(position);
        self.allocator.free(removed.bucket);
        self.allocator.free(removed.key);
        return true;
    }

    pub fn prepareObject(
        self: *MetadataIndex,
        bucket: []const u8,
        key: []const u8,
    ) Error!PreparedObject {
        self.objects.ensureUnusedCapacity(self.allocator, 1) catch {
            return error.OutOfMemory;
        };
        const owned_bucket = self.allocator.dupe(u8, bucket) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_bucket);
        return .{
            .bucket = owned_bucket,
            .key = self.allocator.dupe(u8, key) catch return error.OutOfMemory,
        };
    }

    pub fn publishObject(
        self: *MetadataIndex,
        prepared: *PreparedObject,
        generation: u64,
    ) void {
        const bucket = prepared.bucket orelse unreachable;
        const key = prepared.key orelse unreachable;
        const position = lowerBoundObject(self.objects.items, bucket, key);
        if (position < self.objects.items.len and
            std.mem.eql(u8, self.objects.items[position].bucket, bucket) and
            std.mem.eql(u8, self.objects.items[position].key, key))
        {
            self.objects.items[position].generation = generation;
            self.allocator.free(bucket);
            self.allocator.free(key);
        } else {
            self.objects.insertAssumeCapacity(position, .{
                .bucket = bucket,
                .key = key,
                .generation = generation,
            });
        }
        prepared.bucket = null;
        prepared.key = null;
    }

    pub fn removeObject(
        self: *MetadataIndex,
        bucket: []const u8,
        key: []const u8,
    ) bool {
        const position = lowerBoundObject(self.objects.items, bucket, key);
        if (position >= self.objects.items.len) return false;
        const entry = self.objects.items[position];
        if (!std.mem.eql(u8, entry.bucket, bucket) or
            !std.mem.eql(u8, entry.key, key))
        {
            return false;
        }
        const removed = self.objects.orderedRemove(position);
        self.allocator.free(removed.bucket);
        self.allocator.free(removed.key);
        return true;
    }

    pub fn listObjects(
        self: *const MetadataIndex,
        allocator: std.mem.Allocator,
        bucket: []const u8,
        options: ListOptions,
    ) Error!ListResult {
        var objects: std.ArrayList([]u8) = .empty;
        errdefer {
            for (objects.items) |key| allocator.free(key);
            objects.deinit(allocator);
        }
        var common_prefixes: std.ArrayList([]u8) = .empty;
        errdefer {
            for (common_prefixes.items) |prefix| allocator.free(prefix);
            common_prefixes.deinit(allocator);
        }
        var next_start_after: ?[]u8 = null;
        errdefer if (next_start_after) |cursor| allocator.free(cursor);

        if (options.max_keys == 0) {
            return finishList(allocator, &objects, &common_prefixes, null);
        }

        const delimiter = if (options.delimiter) |value| if (value.len == 0) null else value else null;
        const Candidate = struct { key: []const u8, directory: bool };
        var candidates: std.ArrayList(Candidate) = .empty;
        defer candidates.deinit(allocator);

        if (delimiter) |separator| {
            var directory_position = lowerBoundDirectory(self.directories.items, bucket, options.prefix);
            while (directory_position < self.directories.items.len) : (directory_position += 1) {
                const entry = self.directories.items[directory_position];
                if (!std.mem.eql(u8, entry.bucket, bucket) or !std.mem.startsWith(u8, entry.key, options.prefix)) break;
                if (!containsSearch(entry.key, options.search)) continue;
                const remainder = entry.key[options.prefix.len..];
                const separator_index = std.mem.indexOf(u8, remainder, separator) orelse continue;
                if (separator_index + separator.len != remainder.len) continue;
                candidates.append(allocator, .{ .key = entry.key, .directory = true }) catch return error.OutOfMemory;
            }
        }

        var object_position = lowerBoundObject(self.objects.items, bucket, options.prefix);
        while (object_position < self.objects.items.len) {
            const entry = self.objects.items[object_position];
            if (!std.mem.eql(u8, entry.bucket, bucket) or !std.mem.startsWith(u8, entry.key, options.prefix)) break;
            object_position += 1;
            if (!containsSearch(entry.key, options.search)) continue;
            if (delimiter) |separator| {
                const remainder = entry.key[options.prefix.len..];
                if (std.mem.indexOf(u8, remainder, separator)) |separator_index| {
                    const child_prefix = entry.key[0 .. options.prefix.len + separator_index + separator.len];
                    object_position = firstAfterObjectPrefix(self.objects.items, object_position, bucket, child_prefix);
                    continue;
                }
            }
            candidates.append(allocator, .{ .key = entry.key, .directory = false }) catch return error.OutOfMemory;
        }

        std.mem.sort(Candidate, candidates.items, {}, struct {
            fn lessThan(_: void, left: Candidate, right: Candidate) bool {
                return std.mem.order(u8, left.key, right.key) == .lt;
            }
        }.lessThan);

        var cursor: usize = 0;
        if (options.start_after) |start_after| {
            while (cursor < candidates.items.len and std.mem.order(u8, candidates.items[cursor].key, start_after) != .gt) : (cursor += 1) {}
        }
        const end = @min(candidates.items.len, cursor + options.max_keys);
        for (candidates.items[cursor..end]) |candidate| {
            if (candidate.directory) {
                const owned = allocator.dupe(u8, candidate.key) catch return error.OutOfMemory;
                common_prefixes.append(allocator, owned) catch {
                    allocator.free(owned);
                    return error.OutOfMemory;
                };
            } else {
                try appendObjectKey(allocator, &objects, candidate.key);
            }
        }
        if (end < candidates.items.len and end > cursor) {
            next_start_after = allocator.dupe(u8, candidates.items[end - 1].key) catch return error.OutOfMemory;
        }

        return finishList(
            allocator,
            &objects,
            &common_prefixes,
            next_start_after,
        );
    }

    fn appendRecord(
        self: *MetadataIndex,
        record_type: metadata_record.Type,
        record: repository_port.Record,
    ) Error!void {
        switch (record_type) {
            .system => {},
            .bucket => {
                const decoded = bucket_payload.decode(record.payload) catch {
                    return error.CorruptRecord;
                };
                if (!std.mem.eql(u8, decoded.name, record.key)) {
                    return error.CorruptRecord;
                }
                try appendNamed(self.allocator, &self.buckets, record.key, record.generation);
            },
            .object => {
                const parsed = object_key.parse(record.key) orelse return error.CorruptRecord;
                if (object_history_payload.isHistory(record.payload)) {
                    const history = object_history_payload.decode(
                        self.allocator,
                        record.payload,
                        record.generation,
                    ) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.CorruptRecord,
                    };
                    defer history.deinit(self.allocator);
                    if (!std.mem.eql(u8, history.bucket_name, parsed.bucket) or
                        !std.mem.eql(u8, history.key, parsed.key)) return error.CorruptRecord;
                } else {
                    const decoded = object_payload.decode(self.allocator, record.payload) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.CorruptRecord,
                    };
                    defer decoded.deinit(self.allocator);
                    if (!std.mem.eql(u8, decoded.value.bucket_name, parsed.bucket) or
                        !std.mem.eql(u8, decoded.value.key, parsed.key))
                    {
                        return error.CorruptRecord;
                    }
                }
                const bucket = self.allocator.dupe(u8, parsed.bucket) catch return error.OutOfMemory;
                errdefer self.allocator.free(bucket);
                const key = self.allocator.dupe(u8, parsed.key) catch return error.OutOfMemory;
                self.objects.append(self.allocator, .{
                    .bucket = bucket,
                    .key = key,
                    .generation = record.generation,
                }) catch {
                    self.allocator.free(key);
                    return error.OutOfMemory;
                };
            },
            .directory => {
                const parsed = object_key.parse(record.key) orelse return error.CorruptRecord;
                const decoded = directory_payload.decode(record.payload) catch return error.CorruptRecord;
                if (!std.mem.eql(u8, decoded.bucket_name, parsed.bucket) or
                    !std.mem.eql(u8, decoded.key, parsed.key)) return error.CorruptRecord;
                const bucket = self.allocator.dupe(u8, parsed.bucket) catch return error.OutOfMemory;
                errdefer self.allocator.free(bucket);
                const key = self.allocator.dupe(u8, parsed.key) catch return error.OutOfMemory;
                self.directories.append(self.allocator, .{
                    .bucket = bucket,
                    .key = key,
                    .generation = record.generation,
                    .last_modified_unix_seconds = decoded.last_modified_unix_seconds,
                }) catch {
                    self.allocator.free(key);
                    return error.OutOfMemory;
                };
            },
            .multipart => {
                const decoded = multipart_payload.decode(self.allocator, record.payload) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.CorruptRecord,
                };
                defer decoded.deinit(self.allocator);
                var encoded: [32]u8 = undefined;
                if (!std.mem.eql(u8, multipart_domain.formatUploadId(decoded.value.id, &encoded), record.key)) {
                    return error.CorruptRecord;
                }
                try appendNamed(self.allocator, &self.uploads, record.key, record.generation);
            },
            .credential => {
                const decoded = credential_payload.decode(record.payload) catch {
                    return error.CorruptRecord;
                };
                if (!std.mem.eql(u8, decoded.access_key, record.key)) {
                    return error.CorruptRecord;
                }
                try appendNamed(self.allocator, &self.access_keys, record.key, record.generation);
            },
        }
    }
};

pub const ParsedObjectRecordKey = object_key.Parsed;
pub const encodeObjectRecordKey = object_key.encode;
pub const parseObjectRecordKey = object_key.parse;

fn appendNamed(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(NamedEntry),
    name: []const u8,
    generation: u64,
) Error!void {
    const owned_name = allocator.dupe(u8, name) catch return error.OutOfMemory;
    entries.append(allocator, .{ .name = owned_name, .generation = generation }) catch {
        allocator.free(owned_name);
        return error.OutOfMemory;
    };
}

fn finishList(
    allocator: std.mem.Allocator,
    objects: *std.ArrayList([]u8),
    common_prefixes: *std.ArrayList([]u8),
    next_start_after: ?[]u8,
) Error!ListResult {
    const owned_objects = objects.toOwnedSlice(allocator) catch return error.OutOfMemory;
    errdefer {
        for (owned_objects) |key| allocator.free(key);
        allocator.free(owned_objects);
    }
    const owned_prefixes = common_prefixes.toOwnedSlice(allocator) catch {
        return error.OutOfMemory;
    };
    return .{
        .objects = owned_objects,
        .common_prefixes = owned_prefixes,
        .next_start_after = next_start_after,
    };
}

fn appendObjectKey(
    allocator: std.mem.Allocator,
    objects: *std.ArrayList([]u8),
    key: []const u8,
) Error!void {
    const owned_key = allocator.dupe(u8, key) catch return error.OutOfMemory;
    objects.append(allocator, owned_key) catch {
        allocator.free(owned_key);
        return error.OutOfMemory;
    };
}

fn lessThanNamed(_: void, left: NamedEntry, right: NamedEntry) bool {
    return std.mem.order(u8, left.name, right.name) == .lt;
}

fn lessThanObject(_: void, left: ObjectEntry, right: ObjectEntry) bool {
    const bucket_order = std.mem.order(u8, left.bucket, right.bucket);
    if (bucket_order != .eq) return bucket_order == .lt;
    return std.mem.order(u8, left.key, right.key) == .lt;
}

fn hasNamedDuplicate(entries: []const NamedEntry) bool {
    if (entries.len < 2) return false;
    for (entries[1..], 1..) |entry, index| {
        if (std.mem.eql(u8, entries[index - 1].name, entry.name)) return true;
    }
    return false;
}

fn hasObjectDuplicate(entries: []const ObjectEntry) bool {
    if (entries.len < 2) return false;
    for (entries[1..], 1..) |entry, index| {
        const previous = entries[index - 1];
        if (std.mem.eql(u8, previous.bucket, entry.bucket) and
            std.mem.eql(u8, previous.key, entry.key))
        {
            return true;
        }
    }
    return false;
}

fn hasDirectoryDuplicate(entries: []const DirectoryEntry) bool {
    if (entries.len < 2) return false;
    for (entries[1..], 1..) |entry, index| {
        const previous = entries[index - 1];
        if (std.mem.eql(u8, previous.bucket, entry.bucket) and
            std.mem.eql(u8, previous.key, entry.key)) return true;
    }
    return false;
}

fn lessThanDirectory(_: void, left: DirectoryEntry, right: DirectoryEntry) bool {
    const bucket_order = std.mem.order(u8, left.bucket, right.bucket);
    if (bucket_order != .eq) return bucket_order == .lt;
    return std.mem.order(u8, left.key, right.key) == .lt;
}

fn findNamed(entries: []const NamedEntry, name: []const u8) ?usize {
    const position = lowerBoundNamed(entries, name);
    if (position < entries.len and std.mem.eql(u8, entries[position].name, name)) {
        return position;
    }
    return null;
}

fn lowerBoundNamed(entries: []const NamedEntry, name: []const u8) usize {
    var low: usize = 0;
    var high = entries.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, entries[middle].name, name)) {
            .lt => low = middle + 1,
            .eq => high = middle,
            .gt => high = middle,
        }
    }
    return low;
}

fn lowerBoundObject(
    entries: []const ObjectEntry,
    bucket: []const u8,
    key: []const u8,
) usize {
    var low: usize = 0;
    var high = entries.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = entries[middle];
        const bucket_order = std.mem.order(u8, entry.bucket, bucket);
        if (bucket_order == .lt or
            (bucket_order == .eq and std.mem.order(u8, entry.key, key) == .lt))
        {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return low;
}

fn lowerBoundDirectory(
    entries: []const DirectoryEntry,
    bucket: []const u8,
    key: []const u8,
) usize {
    var low: usize = 0;
    var high = entries.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = entries[middle];
        const bucket_order = std.mem.order(u8, entry.bucket, bucket);
        if (bucket_order == .lt or
            (bucket_order == .eq and std.mem.order(u8, entry.key, key) == .lt))
        {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return low;
}

fn hasMatchingObject(
    entries: []const ObjectEntry,
    start: usize,
    bucket: []const u8,
    prefix: []const u8,
    search: []const u8,
) bool {
    for (entries[start..]) |entry| {
        const bucket_order = std.mem.order(u8, entry.bucket, bucket);
        if (bucket_order == .gt) return false;
        if (bucket_order == .eq and std.mem.startsWith(u8, entry.key, prefix) and
            containsSearch(entry.key, search)) return true;
    }
    return false;
}

fn firstAfterObjectPrefix(entries: []const ObjectEntry, start: usize, bucket: []const u8, prefix: []const u8) usize {
    var low = start;
    var high = entries.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = entries[middle];
        const bucket_order = std.mem.order(u8, entry.bucket, bucket);
        if (bucket_order == .lt or (bucket_order == .eq and (std.mem.order(u8, entry.key, prefix) == .lt or std.mem.startsWith(u8, entry.key, prefix)))) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return low;
}

fn containsSearch(key: []const u8, search: []const u8) bool {
    if (search.len == 0) return true;
    if (search.len > key.len) return false;
    var offset: usize = 0;
    while (offset + search.len <= key.len) : (offset += 1) {
        if (std.ascii.eqlIgnoreCase(key[offset .. offset + search.len], search)) return true;
    }
    return false;
}

fn mapRepositoryError(err: repository_port.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CorruptRecord, error.CorruptJournal => error.CorruptRecord,
        error.NotFound,
        error.Conflict,
        error.InvalidKey,
        error.PayloadTooLarge,
        error.GenerationExhausted,
        error.Unavailable,
        => error.Unavailable,
    };
}

test "object record keys preserve nested object keys" {
    const encoded = try encodeObjectRecordKey(std.testing.allocator, "photos", "/2026/a.jpg");
    defer std.testing.allocator.free(encoded);
    const parsed = parseObjectRecordKey(encoded).?;
    try std.testing.expectEqualStrings("photos", parsed.bucket);
    try std.testing.expectEqualStrings("/2026/a.jpg", parsed.key);
}

const LocalTransactionJournal = @import("local_journal.zig").LocalTransactionJournal;
const LocalMetadataRepository = @import("local_repository.zig").LocalMetadataRepository;

fn createTestLayout(root: std.Io.Dir) !void {
    try root.createDirPath(std.testing.io, ".zigfs/system/configuration/records");
    try root.createDirPath(std.testing.io, ".zigfs/system/credentials");
    try root.createDirPath(std.testing.io, ".zigfs/journal");
    try root.createDirPath(std.testing.io, ".zigfs/indexes");
    try root.createDirPath(std.testing.io, ".zigfs/tmp");
    try root.createDirPath(std.testing.io, "metadata/buckets");
    try root.createDirPath(std.testing.io, "metadata/objects");
    try root.createDirPath(std.testing.io, "metadata/directories");
    try root.createDirPath(std.testing.io, "metadata/multipart");
}

fn putTestBucket(
    repository: repository_port.MetadataRepository,
    name: []const u8,
    discriminator: u8,
) !u64 {
    const payload = try bucket_payload.encode(std.testing.allocator, .{
        .id = .{
            discriminator, 1, 2,  3,  4,  5,  0x46, 7,
            0x88,          9, 10, 11, 12, 13, 14,   15,
        },
        .name = name,
        .owner = "test-owner",
        .status = .active,
        .created_at_unix_seconds = 1_800_000_000,
    });
    defer std.testing.allocator.free(payload);
    return repository.put(std.testing.allocator, .bucket, name, .missing, payload);
}

fn putTestObject(
    repository: repository_port.MetadataRepository,
    repository_key: []const u8,
    discriminator: u8,
) !u64 {
    const parsed = object_key.parse(repository_key) orelse return error.InvalidKey;
    const payload = try object_payload.encode(std.testing.allocator, .{
        .id = .{
            discriminator, 1, 2,  3,  4,  5,  0x46, 7,
            0x88,          9, 10, 11, 12, 13, 14,   15,
        },
        .bucket_id = .{ 40, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
        .bucket_name = parsed.bucket,
        .key = parsed.key,
        .size = 6,
        .etag_md5 = .{1} ** 16,
        .checksum_sha256 = .{2} ** 32,
        .content_type = "application/octet-stream",
        .last_modified_unix_seconds = 1_800_000_000,
        .user_metadata = &.{},
        .data_generation = .{
            discriminator +% 80, 1, 2,  3,  4,  5,  0x46, 7,
            0x88,                9, 10, 11, 12, 13, 14,   15,
        },
        .status = .active,
    });
    defer std.testing.allocator.free(payload);
    return repository.put(
        std.testing.allocator,
        .object,
        repository_key,
        .missing,
        payload,
    );
}

fn putTestMultipart(repository: repository_port.MetadataRepository) ![]const u8 {
    const upload_id = [_]u8{ 50, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 };
    var upload_id_buffer: [32]u8 = undefined;
    const upload_id_text = multipart_domain.formatUploadId(upload_id, &upload_id_buffer);
    const payload = try multipart_payload.encode(std.testing.allocator, .{
        .id = upload_id,
        .bucket_id = .{ 40, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
        .bucket_name = "photos",
        .key = "large.bin",
        .content_type = "application/octet-stream",
        .user_metadata = &.{},
        .initiated_at_unix_seconds = 1_800_000_000,
        .parts = &.{},
    });
    defer std.testing.allocator.free(payload);
    _ = try repository.put(std.testing.allocator, .multipart, upload_id_text, .missing, payload);
    return "320102030405460788090a0b0c0d0e0f";
}

test "index rebuild skips tombstones and list objects is stable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createTestLayout(tmp.dir);

    var journal = LocalTransactionJournal.init(tmp.dir, std.testing.io);
    var local = LocalMetadataRepository.init(tmp.dir, std.testing.io, journal.interface());
    const repository = local.interface();
    _ = try putTestBucket(repository, "photos", 1);
    _ = try putTestBucket(repository, "videos", 3);
    const removed_bucket_generation = try putTestBucket(repository, "removed", 2);
    _ = try repository.tombstone(
        std.testing.allocator,
        .bucket,
        "removed",
        .{ .exact = removed_bucket_generation },
    );

    const object_keys = [_][]const u8{
        "photos/a.txt",
        "photos/dir/a.jpg",
        "photos/dir/b.jpg",
        "photos/z.txt",
        "videos/a.mp4",
    };
    for (object_keys, 0..) |key, index| {
        _ = try putTestObject(repository, key, @intCast(index + 10));
    }
    const removed_object_generation = try putTestObject(repository, "photos/deleted.txt", 30);
    _ = try repository.tombstone(
        std.testing.allocator,
        .object,
        "photos/deleted.txt",
        .{ .exact = removed_object_generation },
    );
    const multipart_upload_id = try putTestMultipart(repository);
    const test_credential_payload = try credential_payload.encode(std.testing.allocator, .{
        .access_key = "ZF0123456789ABCDEF",
        .owner = "owner-a",
        .status = .active,
        .policy = .all,
        .created_at_unix_seconds = 1_800_000_000,
        .secret_nonce = .{1} ** 12,
        .secret_tag = .{2} ** 16,
        .encrypted_secret = "0123456789abcdef0123456789abcdef01234567",
    });
    defer std.testing.allocator.free(test_credential_payload);
    _ = try repository.put(
        std.testing.allocator,
        .credential,
        "ZF0123456789ABCDEF",
        .missing,
        test_credential_payload,
    );

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".zigfs/indexes/snapshot.index",
        .data = "an index is never a fact source",
    });
    var index = MetadataIndex.init(std.testing.allocator);
    defer index.deinit();
    try index.rebuild(repository);
    try std.testing.expectEqual(@as(usize, 2), index.buckets.items.len);
    try std.testing.expectEqual(@as(usize, 5), index.objects.items.len);
    try std.testing.expect(index.containsBucket("photos"));
    try std.testing.expect(!index.containsBucket("removed"));
    try std.testing.expect(index.containsObject("photos", "dir/a.jpg"));
    try std.testing.expect(!index.containsObject("photos", "deleted.txt"));
    try std.testing.expect(index.containsUpload(multipart_upload_id));
    try std.testing.expect(index.containsAccessKey("ZF0123456789ABCDEF"));

    const first_page = try index.listObjects(std.testing.allocator, "photos", .{
        .delimiter = "/",
        .max_keys = 2,
    });
    defer first_page.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), first_page.objects.len);
    try std.testing.expectEqualStrings("a.txt", first_page.objects[0]);
    try std.testing.expectEqual(@as(usize, 1), first_page.common_prefixes.len);
    try std.testing.expectEqualStrings("dir/", first_page.common_prefixes[0]);
    try std.testing.expectEqualStrings("dir/b.jpg", first_page.next_start_after.?);

    const second_page = try index.listObjects(std.testing.allocator, "photos", .{
        .delimiter = "/",
        .start_after = first_page.next_start_after,
        .max_keys = 2,
    });
    defer second_page.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), second_page.objects.len);
    try std.testing.expectEqualStrings("z.txt", second_page.objects[0]);
    try std.testing.expectEqual(@as(usize, 0), second_page.common_prefixes.len);
    try std.testing.expect(second_page.next_start_after == null);

    const prefixed_page = try index.listObjects(std.testing.allocator, "photos", .{
        .prefix = "dir/",
        .max_keys = 1,
    });
    defer prefixed_page.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("dir/a.jpg", prefixed_page.objects[0]);
    try std.testing.expectEqualStrings("dir/a.jpg", prefixed_page.next_start_after.?);

    const search_page = try index.listObjects(std.testing.allocator, "photos", .{
        .search = "DIR/",
        .max_keys = 1,
    });
    defer search_page.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), search_page.objects.len);
    try std.testing.expectEqualStrings("dir/a.jpg", search_page.objects[0]);
    try std.testing.expectEqualStrings("dir/a.jpg", search_page.next_start_after.?);

    const search_page_two = try index.listObjects(std.testing.allocator, "photos", .{
        .search = "DIR/",
        .start_after = search_page.next_start_after,
        .max_keys = 1,
    });
    defer search_page_two.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), search_page_two.objects.len);
    try std.testing.expectEqualStrings("dir/b.jpg", search_page_two.objects[0]);
    try std.testing.expect(search_page_two.next_start_after == null);

    try tmp.dir.deleteFile(std.testing.io, ".zigfs/indexes/snapshot.index");
    try index.rebuild(repository);
    try std.testing.expect(index.containsObject("photos", "z.txt"));
}

test "index rejects invalid or mismatched bucket payloads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createTestLayout(tmp.dir);
    var journal = LocalTransactionJournal.init(tmp.dir, std.testing.io);
    var local = LocalMetadataRepository.init(tmp.dir, std.testing.io, journal.interface());
    const repository = local.interface();
    _ = try repository.put(
        std.testing.allocator,
        .bucket,
        "invalid-payload",
        .missing,
        "not-a-bucket-payload",
    );
    var index = MetadataIndex.init(std.testing.allocator);
    defer index.deinit();
    try std.testing.expectError(error.CorruptRecord, index.rebuild(repository));

    const invalid_record = try repository.get(
        std.testing.allocator,
        .bucket,
        "invalid-payload",
    );
    defer invalid_record.deinit(std.testing.allocator);
    const generation = invalid_record.generation;
    const replacement = try bucket_payload.encode(std.testing.allocator, .{
        .id = .{ 3, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
        .name = "different-name",
        .owner = "test-owner",
        .status = .active,
        .created_at_unix_seconds = 1_800_000_000,
    });
    defer std.testing.allocator.free(replacement);
    _ = try repository.put(
        std.testing.allocator,
        .bucket,
        "invalid-payload",
        .{ .exact = generation },
        replacement,
    );
    try std.testing.expectError(error.CorruptRecord, index.rebuild(repository));
}

test "index rejects an object record without a bucket component" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createTestLayout(tmp.dir);
    var journal = LocalTransactionJournal.init(tmp.dir, std.testing.io);
    var local = LocalMetadataRepository.init(tmp.dir, std.testing.io, journal.interface());
    _ = try local.interface().put(
        std.testing.allocator,
        .object,
        "missing-bucket-separator",
        .missing,
        "object",
    );
    var index = MetadataIndex.init(std.testing.allocator);
    defer index.deinit();
    try std.testing.expectError(error.CorruptRecord, index.rebuild(local.interface()));
}

test "index rejects invalid object payload and object without a bucket" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createTestLayout(tmp.dir);
    var journal = LocalTransactionJournal.init(tmp.dir, std.testing.io);
    var local = LocalMetadataRepository.init(tmp.dir, std.testing.io, journal.interface());
    const repository = local.interface();
    _ = try putTestBucket(repository, "project-assets", 1);
    _ = try repository.put(
        std.testing.allocator,
        .object,
        "project-assets/corrupt.txt",
        .missing,
        "not-an-object-payload",
    );
    var index = MetadataIndex.init(std.testing.allocator);
    defer index.deinit();
    try std.testing.expectError(error.CorruptRecord, index.rebuild(repository));

    const corrupt_record = try repository.get(
        std.testing.allocator,
        .object,
        "project-assets/corrupt.txt",
    );
    defer corrupt_record.deinit(std.testing.allocator);
    _ = try repository.tombstone(
        std.testing.allocator,
        .object,
        "project-assets/corrupt.txt",
        .{ .exact = corrupt_record.generation },
    );
    _ = try putTestObject(repository, "missing-bucket/object.txt", 50);
    try std.testing.expectError(error.CorruptRecord, index.rebuild(repository));
}
