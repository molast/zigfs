const std = @import("std");
const bucket_domain = @import("../domain/bucket.zig");
const object_domain = @import("../domain/object.zig");
const index_module = @import("../metadata/index.zig");
const bucket_store_port = @import("../ports/bucket_store.zig");
const object_store_port = @import("../ports/object_store.zig");
const token_codec = @import("continuation_token.zig");

pub const max_keys: usize = 1000;

pub const Error = error{
    OutOfMemory,
    InvalidBucketName,
    InvalidListOptions,
    InvalidContinuationToken,
    BucketNotFound,
    CorruptMetadata,
    Unavailable,
};

pub const Options = struct {
    prefix: []const u8 = "",
    delimiter: ?[]const u8 = null,
    max_keys: usize = max_keys,
    start_after: ?[]const u8 = null,
    continuation_token: ?[]const u8 = null,
};

pub const Entry = struct {
    key: []u8,
    size: u64,
    etag_md5: [16]u8,
    etag_part_count: u16,
    last_modified_unix_seconds: i64,

    pub fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
    }
};

pub const Result = struct {
    objects: []Entry,
    common_prefixes: [][]u8,
    key_count: usize,
    is_truncated: bool,
    next_continuation_token: ?[]u8,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        for (self.objects) |entry| entry.deinit(allocator);
        allocator.free(self.objects);
        for (self.common_prefixes) |prefix| allocator.free(prefix);
        allocator.free(self.common_prefixes);
        if (self.next_continuation_token) |token| allocator.free(token);
    }
};

pub const ObjectListingService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    bucket_store: bucket_store_port.BucketStore,
    object_store: object_store_port.ObjectStore,
    index: *index_module.MetadataIndex,
    state_mutex: *std.Io.Mutex,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        bucket_store: bucket_store_port.BucketStore,
        object_store: object_store_port.ObjectStore,
        index: *index_module.MetadataIndex,
        state_mutex: *std.Io.Mutex,
    ) ObjectListingService {
        return .{
            .allocator = allocator,
            .io = io,
            .bucket_store = bucket_store,
            .object_store = object_store,
            .index = index,
            .state_mutex = state_mutex,
        };
    }

    pub fn list(
        self: ObjectListingService,
        bucket_name: []const u8,
        options: Options,
    ) Error!Result {
        bucket_domain.validateName(bucket_name) catch return error.InvalidBucketName;
        const delimiter = normalizedDelimiter(options.delimiter);
        try validateOptions(options, delimiter);
        const token_context: token_codec.Context = .{
            .bucket = bucket_name,
            .prefix = options.prefix,
            .delimiter = delimiter,
        };
        const decoded_token: ?token_codec.Decoded = if (options.continuation_token) |token|
            token_codec.decode(self.allocator, token_context, token) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidContinuationToken,
            }
        else
            null;
        defer if (decoded_token) |decoded| decoded.deinit(self.allocator);
        const cursor = if (decoded_token) |decoded|
            decoded.cursor
        else
            options.start_after;

        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        try self.verifyBucketLocked(bucket_name);
        const indexed = self.index.listObjects(self.allocator, bucket_name, .{
            .prefix = options.prefix,
            .delimiter = delimiter,
            .start_after = cursor,
            .max_keys = options.max_keys,
        }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.CorruptRecord => error.CorruptMetadata,
            error.Unavailable => error.Unavailable,
        };
        defer indexed.deinit(self.allocator);

        var objects = self.allocator.alloc(Entry, indexed.objects.len) catch {
            return error.OutOfMemory;
        };
        var initialized_objects: usize = 0;
        errdefer {
            for (objects[0..initialized_objects]) |entry| entry.deinit(self.allocator);
            self.allocator.free(objects);
        }
        for (indexed.objects) |key| {
            const record = self.object_store.get(self.allocator, bucket_name, key) catch |err| {
                return mapObjectStoreError(err);
            };
            defer record.deinit(self.allocator);
            const object = switch (record) {
                .active => |value| value,
                .delete_marker => continue,
                .tombstone => return error.CorruptMetadata,
            };
            const indexed_generation = self.index.objectGeneration(bucket_name, key) orelse {
                return error.CorruptMetadata;
            };
            if (object.metadata_generation != indexed_generation) {
                return error.CorruptMetadata;
            }
            objects[initialized_objects] = .{
                .key = self.allocator.dupe(u8, object.key) catch return error.OutOfMemory,
                .size = object.size,
                .etag_md5 = object.etag_md5,
                .etag_part_count = object.etag_part_count,
                .last_modified_unix_seconds = object.last_modified_unix_seconds,
            };
            initialized_objects += 1;
        }
        objects = self.allocator.realloc(objects, initialized_objects) catch {
            return error.OutOfMemory;
        };

        const common_prefixes = self.allocator.alloc([]u8, indexed.common_prefixes.len) catch {
            return error.OutOfMemory;
        };
        var initialized_prefixes: usize = 0;
        errdefer {
            for (common_prefixes[0..initialized_prefixes]) |prefix| self.allocator.free(prefix);
            self.allocator.free(common_prefixes);
        }
        for (indexed.common_prefixes, 0..) |prefix, prefix_index| {
            common_prefixes[prefix_index] = self.allocator.dupe(u8, prefix) catch {
                return error.OutOfMemory;
            };
            initialized_prefixes += 1;
        }

        const next_token = if (indexed.next_start_after) |next_cursor|
            token_codec.encode(self.allocator, token_context, next_cursor) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.CorruptMetadata,
            }
        else
            null;
        return .{
            .objects = objects,
            .common_prefixes = common_prefixes,
            .key_count = objects.len + common_prefixes.len,
            .is_truncated = next_token != null,
            .next_continuation_token = next_token,
        };
    }

    fn verifyBucketLocked(
        self: ObjectListingService,
        bucket_name: []const u8,
    ) Error!void {
        const indexed_generation = self.index.bucketGeneration(bucket_name) orelse {
            return error.BucketNotFound;
        };
        const record = self.bucket_store.get(self.allocator, bucket_name) catch |err| {
            return mapBucketStoreError(err);
        };
        defer record.deinit(self.allocator);
        const bucket = switch (record) {
            .active => |value| value,
            .tombstone => return error.CorruptMetadata,
        };
        if (bucket.generation != indexed_generation) return error.CorruptMetadata;
    }
};

fn normalizedDelimiter(delimiter: ?[]const u8) ?[]const u8 {
    if (delimiter) |value| return if (value.len == 0) null else value;
    return null;
}

fn validateOptions(options: Options, delimiter: ?[]const u8) Error!void {
    if (options.max_keys > max_keys or
        !validOptionalKey(options.prefix, true) or
        (options.start_after != null and !validOptionalKey(options.start_after.?, true)) or
        (delimiter != null and !validOptionalKey(delimiter.?, false)) or
        (options.continuation_token != null and options.continuation_token.?.len == 0))
    {
        return error.InvalidListOptions;
    }
}

fn validOptionalKey(value: []const u8, allow_empty: bool) bool {
    return (allow_empty or value.len > 0) and
        value.len <= object_domain.max_key_length and
        std.mem.indexOfScalar(u8, value, 0) == null;
}

fn mapBucketStoreError(err: bucket_store_port.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotFound => error.BucketNotFound,
        error.InvalidValue, error.CorruptMetadata => error.CorruptMetadata,
        error.Conflict => error.CorruptMetadata,
        error.Unavailable => error.Unavailable,
    };
}

fn mapObjectStoreError(err: object_store_port.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotFound,
        error.Conflict,
        error.InvalidValue,
        error.CorruptMetadata,
        => error.CorruptMetadata,
        error.Unavailable => error.Unavailable,
    };
}
