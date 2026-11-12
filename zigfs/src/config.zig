const std = @import("std");

pub const Config = struct {
    pub const default_path = ".env";
    pub const max_file_size = 1024 * 1024;
    pub const min_stream_buffer_size = 4 * 1024;
    pub const max_stream_buffer_size = 1024 * 1024;
    const max_admin_username_length = 128;
    const max_admin_password_length = 1024;
    const max_admin_session_secret_length = 4096;
    const max_s3_region_length = 63;

    data_root: []const u8 = "data",
    stream_buffer_size: usize = 64 * 1024,
    metadata_maintenance_interval_seconds: u64 = 60,
    metadata_maintenance_batch_size: usize = 1000,
    api_address: []const u8 = "0.0.0.0:9000",
    metrics_enabled: bool = true,
    metrics_address: []const u8 = "127.0.0.1:9090",
    s3_public_endpoint: []const u8 = "http://127.0.0.1:9000",
    s3_virtual_hosted_style: bool = false,
    s3_region: []const u8 = "us-east-1",
    s3_request_time_skew_seconds: u64 = 15 * 60,
    s3_multipart_expiry_seconds: u64 = 7 * 24 * 60 * 60,
    s3_lifecycle_scan_interval_seconds: u64 = 5 * 60,
    root_access_key: []const u8 = "",
    root_secret_key: []const u8 = "",
    admin_username: []const u8 = "admin",
    admin_password: []const u8 = "zigfs-admin",
    admin_session_secret: []const u8 = "zigfs-local-session-secret-change-before-production",
    admin_session_ttl_seconds: u64 = 8 * 60 * 60,

    kms_allow_insecure_dev_defaults: bool = false,
    oidc_providers: []const u8 = "[]",

    pub const ParseError = error{
        InvalidEnv,
        MissingValue,
        UnknownArgument,
        UnknownKey,
        InvalidAdminConfig,
        InvalidRootCredentials,
        InvalidStorageConfig,
        InvalidS3Config,
    };

    pub const LoadError = ParseError || std.Io.Dir.ReadFileAllocError;

    const Arguments = struct {
        config_path: []const u8 = default_path,
        config_path_explicit: bool = false,
    };

    pub fn load(
        io: std.Io,
        allocator: std.mem.Allocator,
        args: []const []const u8,
    ) LoadError!Config {
        return loadWithEnvironment(io, allocator, args, .{});
    }

    pub const Environment = struct {
        data_root: ?[]const u8 = null,
        stream_buffer_size: ?[]const u8 = null,
        metadata_maintenance_interval_seconds: ?[]const u8 = null,
        metadata_maintenance_batch_size: ?[]const u8 = null,
        api_address: ?[]const u8 = null,
        metrics_enabled: ?[]const u8 = null,
        metrics_address: ?[]const u8 = null,
        s3_public_endpoint: ?[]const u8 = null,
        s3_virtual_hosted_style: ?[]const u8 = null,
        s3_region: ?[]const u8 = null,
        s3_request_time_skew_seconds: ?[]const u8 = null,
        s3_multipart_expiry_seconds: ?[]const u8 = null,
        s3_lifecycle_scan_interval_seconds: ?[]const u8 = null,
        root_access_key: ?[]const u8 = null,
        root_secret_key: ?[]const u8 = null,
        admin_username: ?[]const u8 = null,
        admin_password: ?[]const u8 = null,
        admin_session_secret: ?[]const u8 = null,
        admin_session_ttl_seconds: ?[]const u8 = null,
        kms_allow_insecure_dev_defaults: ?[]const u8 = null,
        oidc_providers: ?[]const u8 = null,
    };

    pub fn environmentFromMap(map: anytype) Environment {
        return .{
            .data_root = map.get("ZIGFS_DATA_ROOT"),
            .stream_buffer_size = map.get("ZIGFS_STREAM_BUFFER_SIZE"),
            .metadata_maintenance_interval_seconds = map.get("ZIGFS_METADATA_MAINTENANCE_INTERVAL_SECONDS"),
            .metadata_maintenance_batch_size = map.get("ZIGFS_METADATA_MAINTENANCE_BATCH_SIZE"),
            .api_address = map.get("ZIGFS_API_ADDRESS"),
            .metrics_enabled = map.get("ZIGFS_METRICS_ENABLED"),
            .metrics_address = map.get("ZIGFS_METRICS_ADDRESS"),
            .s3_public_endpoint = map.get("ZIGFS_S3_PUBLIC_ENDPOINT"),
            .s3_virtual_hosted_style = map.get("ZIGFS_S3_VIRTUAL_HOSTED_STYLE"),
            .s3_region = map.get("ZIGFS_S3_REGION"),
            .s3_request_time_skew_seconds = map.get("ZIGFS_S3_REQUEST_TIME_SKEW_SECONDS"),
            .s3_multipart_expiry_seconds = map.get("ZIGFS_S3_MULTIPART_EXPIRY_SECONDS"),
            .s3_lifecycle_scan_interval_seconds = map.get("ZIGFS_S3_LIFECYCLE_SCAN_INTERVAL_SECONDS"),
            .root_access_key = map.get("ZIGFS_ACCESS_KEY"),
            .root_secret_key = map.get("ZIGFS_SECRET_KEY"),
            .admin_username = map.get("ZIGFS_ROOT_USER"),
            .admin_password = map.get("ZIGFS_ROOT_PASSWORD"),
            .admin_session_secret = map.get("ZIGFS_ADMIN_SESSION_SECRET"),
            .admin_session_ttl_seconds = map.get("ZIGFS_ADMIN_SESSION_TTL_SECONDS"),
            .kms_allow_insecure_dev_defaults = map.get("ZIGFS_KMS_ALLOW_INSECURE_DEV_DEFAULTS"),
            .oidc_providers = map.get("ZIGFS_OIDC_PROVIDERS"),
        };
    }

    pub fn applyEnvironment(self: *Config, environment: Environment) ParseError!void {
        if (environment.data_root) |value| try self.applyValue("ZIGFS_DATA_ROOT", value);
        if (environment.stream_buffer_size) |value| try self.applyValue("ZIGFS_STREAM_BUFFER_SIZE", value);
        if (environment.metadata_maintenance_interval_seconds) |value| try self.applyValue("ZIGFS_METADATA_MAINTENANCE_INTERVAL_SECONDS", value);
        if (environment.metadata_maintenance_batch_size) |value| try self.applyValue("ZIGFS_METADATA_MAINTENANCE_BATCH_SIZE", value);
        if (environment.api_address) |value| try self.applyValue("ZIGFS_API_ADDRESS", value);
        if (environment.metrics_enabled) |value| try self.applyValue("ZIGFS_METRICS_ENABLED", value);
        if (environment.metrics_address) |value| try self.applyValue("ZIGFS_METRICS_ADDRESS", value);
        if (environment.s3_public_endpoint) |value| try self.applyValue("ZIGFS_S3_PUBLIC_ENDPOINT", value);
        if (environment.s3_virtual_hosted_style) |value| try self.applyValue("ZIGFS_S3_VIRTUAL_HOSTED_STYLE", value);
        if (environment.s3_region) |value| try self.applyValue("ZIGFS_S3_REGION", value);
        if (environment.s3_request_time_skew_seconds) |value| try self.applyValue("ZIGFS_S3_REQUEST_TIME_SKEW_SECONDS", value);
        if (environment.s3_multipart_expiry_seconds) |value| try self.applyValue("ZIGFS_S3_MULTIPART_EXPIRY_SECONDS", value);
        if (environment.s3_lifecycle_scan_interval_seconds) |value| try self.applyValue("ZIGFS_S3_LIFECYCLE_SCAN_INTERVAL_SECONDS", value);
        if (environment.root_access_key) |value| try self.applyValue("ZIGFS_ACCESS_KEY", value);
        if (environment.root_secret_key) |value| try self.applyValue("ZIGFS_SECRET_KEY", value);
        if (environment.admin_username) |value| try self.applyValue("ZIGFS_ROOT_USER", value);
        if (environment.admin_password) |value| try self.applyValue("ZIGFS_ROOT_PASSWORD", value);
        if (environment.admin_session_secret) |value| try self.applyValue("ZIGFS_ADMIN_SESSION_SECRET", value);
        if (environment.admin_session_ttl_seconds) |value| try self.applyValue("ZIGFS_ADMIN_SESSION_TTL_SECONDS", value);
        if (environment.kms_allow_insecure_dev_defaults) |value| try self.applyValue("ZIGFS_KMS_ALLOW_INSECURE_DEV_DEFAULTS", value);
        if (environment.oidc_providers) |value| try self.applyValue("ZIGFS_OIDC_PROVIDERS", value);
    }

    pub fn loadWithEnvironment(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, environment: Environment) LoadError!Config {
        const arguments = try parseArguments(args);
        var config: Config = .{};
        const source = std.Io.Dir.cwd().readFileAlloc(io, arguments.config_path, allocator, .limited(max_file_size)) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (arguments.config_path_explicit) return err;
                break :blk null;
            },
            else => return err,
        };
        // Strings borrow source memory, which lives in the startup arena.
        if (source) |content| try config.applyEnv(content);
        try config.applyEnvironment(environment);
        config = try applyOverrides(config, args);
        try config.validate();
        return config;
    }

    pub fn applyEnv(self: *Config, source: []const u8) ParseError!void {
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const separator = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidEnv;
            const key = std.mem.trim(u8, line[0..separator], " \t");
            if (key.len == 0) return error.InvalidEnv;
            for (key, 0..) |c, i| {
                if (!(std.ascii.isUpper(c) or c == '_' or (i > 0 and std.ascii.isDigit(c)))) return error.InvalidEnv;
            }
            try self.applyValue(key, try scalarValue(line[separator + 1 ..]));
        }
    }

    fn applyValue(self: *Config, key: []const u8, value: []const u8) ParseError!void {
        if (std.mem.eql(u8, key, "ZIGFS_DATA_ROOT")) {
            self.data_root = value;
            return;
        }
        if (std.mem.eql(u8, key, "ZIGFS_STREAM_BUFFER_SIZE")) {
            self.stream_buffer_size = std.fmt.parseInt(usize, value, 10) catch return error.InvalidEnv;
            return;
        }
        if (std.mem.eql(u8, key, "ZIGFS_METADATA_MAINTENANCE_INTERVAL_SECONDS")) {
            self.metadata_maintenance_interval_seconds = std.fmt.parseInt(u64, value, 10) catch return error.InvalidEnv;
            return;
        }
        if (std.mem.eql(u8, key, "ZIGFS_METADATA_MAINTENANCE_BATCH_SIZE")) {
            self.metadata_maintenance_batch_size = std.fmt.parseInt(usize, value, 10) catch return error.InvalidEnv;
            return;
        }
        if (std.mem.eql(u8, key, "ZIGFS_API_ADDRESS")) {
            self.api_address = value;
            return;
        }
        if (std.mem.eql(u8, key, "ZIGFS_METRICS_ENABLED")) {
            self.metrics_enabled = try booleanValue(value);
            return;
        }
        if (std.mem.eql(u8, key, "ZIGFS_METRICS_ADDRESS")) {
            self.metrics_address = value;
            return;
        }
        if (std.mem.eql(u8, key, "ZIGFS_S3_PUBLIC_ENDPOINT")) {
            self.s3_public_endpoint = value;
            return;
        }
        if (std.mem.eql(u8, key, "ZIGFS_S3_VIRTUAL_HOSTED_STYLE")) {
            self.s3_virtual_hosted_style = try booleanValue(value);
            return;
        }
        if (std.mem.eql(u8, key, "ZIGFS_S3_REGION")) {
            self.s3_region = value;
            return;
        }
        if (std.mem.eql(u8, key, "ZIGFS_S3_REQUEST_TIME_SKEW_SECONDS")) {
            self.s3_request_time_skew_seconds = std.fmt.parseInt(u64, value, 10) catch return error.InvalidEnv;
            return;
        }
        if (std.mem.eql(u8, key, "ZIGFS_S3_MULTIPART_EXPIRY_SECONDS")) {
            self.s3_multipart_expiry_seconds = std.fmt.parseInt(u64, value, 10) catch return error.InvalidEnv;
            return;
        }
        if (std.mem.eql(u8, key, "ZIGFS_S3_LIFECYCLE_SCAN_INTERVAL_SECONDS")) {
            self.s3_lifecycle_scan_interval_seconds = std.fmt.parseInt(u64, value, 10) catch return error.InvalidEnv;
            return;
        }
        if (std.mem.eql(u8, key, "ZIGFS_ACCESS_KEY")) {
            self.root_access_key = value;
            return;
        }
        if (std.mem.eql(u8, key, "ZIGFS_SECRET_KEY")) {
            self.root_secret_key = value;
            return;
        }
        if (std.mem.eql(u8, key, "ZIGFS_ROOT_USER")) {
            self.admin_username = value;
            return;
        }
        if (std.mem.eql(u8, key, "ZIGFS_ROOT_PASSWORD")) {
            self.admin_password = value;
            return;
        }
        if (std.mem.eql(u8, key, "ZIGFS_ADMIN_SESSION_SECRET")) {
            self.admin_session_secret = value;
            return;
        }
        if (std.mem.eql(u8, key, "ZIGFS_ADMIN_SESSION_TTL_SECONDS")) {
            self.admin_session_ttl_seconds = std.fmt.parseInt(u64, value, 10) catch return error.InvalidEnv;
            return;
        }
        if (std.mem.eql(u8, key, "ZIGFS_KMS_ALLOW_INSECURE_DEV_DEFAULTS")) {
            self.kms_allow_insecure_dev_defaults = try booleanValue(value);
            return;
        }
        if (std.mem.eql(u8, key, "ZIGFS_OIDC_PROVIDERS")) {
            self.oidc_providers = value;
            return;
        }
        // A shared Compose file also contains Admin, build and port variables.
        // They are not data-plane settings.
    }

    fn parseArguments(args: []const []const u8) ParseError!Arguments {
        var parsed: Arguments = .{};
        var index: usize = 1;
        while (index < args.len) : (index += 1) {
            const argument = args[index];
            if (std.mem.eql(u8, argument, "--env-file")) {
                index += 1;
                if (index >= args.len) return error.MissingValue;
                parsed.config_path = args[index];
                parsed.config_path_explicit = true;
            } else if (std.mem.eql(u8, argument, "--data-root") or
                std.mem.eql(u8, argument, "--api-address") or
                std.mem.eql(u8, argument, "--metrics-enabled") or
                std.mem.eql(u8, argument, "--metrics-address"))
            {
                index += 1;
                if (index >= args.len) return error.MissingValue;
            } else {
                return error.UnknownArgument;
            }
        }
        return parsed;
    }

    fn applyOverrides(initial: Config, args: []const []const u8) ParseError!Config {
        var config = initial;
        var index: usize = 1;
        while (index < args.len) : (index += 1) {
            const argument = args[index];
            index += 1;
            if (index >= args.len) return error.MissingValue;

            if (std.mem.eql(u8, argument, "--env-file")) {
                continue;
            } else if (std.mem.eql(u8, argument, "--data-root")) {
                config.data_root = args[index];
            } else if (std.mem.eql(u8, argument, "--api-address")) {
                config.api_address = args[index];
            } else if (std.mem.eql(u8, argument, "--metrics-enabled")) {
                config.metrics_enabled = try booleanValue(args[index]);
            } else if (std.mem.eql(u8, argument, "--metrics-address")) {
                config.metrics_address = args[index];
            } else {
                return error.UnknownArgument;
            }
        }
        return config;
    }

    fn scalarValue(raw_value: []const u8) ParseError![]const u8 {
        const value = std.mem.trim(u8, raw_value, " \t");
        if (value.len == 0) return "";
        if (value[0] == '"' or value[0] == '\'') {
            const end = std.mem.indexOfScalarPos(u8, value, 1, value[0]) orelse return error.InvalidEnv;
            const tail = std.mem.trim(u8, value[end + 1 ..], " \t");
            if (tail.len > 0 and tail[0] != '#') return error.InvalidEnv;
            return value[1..end];
        }
        for (value, 0..) |c, i| {
            if (c == '#' and (i == 0 or value[i - 1] == ' ' or value[i - 1] == '\t')) return std.mem.trimEnd(u8, value[0..i], " \t");
        }
        return value;
    }

    fn booleanValue(value: []const u8) ParseError!bool {
        if (std.mem.eql(u8, value, "true")) return true;
        if (std.mem.eql(u8, value, "false")) return false;
        return error.InvalidEnv;
    }

    fn validate(self: Config) ParseError!void {
        if (self.root_access_key.len > 0 or self.root_secret_key.len > 0) {
            @import("domain/credential.zig").validateAccessKey(self.root_access_key) catch return error.InvalidRootCredentials;
            if (std.mem.eql(u8, self.root_access_key, "ZIGFSCONSOLESESSION")) return error.InvalidRootCredentials;
            if (self.root_secret_key.len < 32 or self.root_secret_key.len > 64) return error.InvalidRootCredentials;
            for (self.root_secret_key) |c| if (c < 33 or c > 126) return error.InvalidRootCredentials;
        }
        if (self.stream_buffer_size < min_stream_buffer_size or
            self.stream_buffer_size > max_stream_buffer_size or
            self.metadata_maintenance_interval_seconds < 1 or
            self.metadata_maintenance_interval_seconds > 3600 or
            self.metadata_maintenance_batch_size < 1 or
            self.metadata_maintenance_batch_size > 10000)
        {
            return error.InvalidStorageConfig;
        }
        if (!isValidPublicEndpoint(self.s3_public_endpoint) or
            self.s3_region.len == 0 or self.s3_region.len > max_s3_region_length or
            !isValidS3Region(self.s3_region) or
            self.s3_request_time_skew_seconds < 60 or
            self.s3_request_time_skew_seconds > 60 * 60 or
            self.s3_multipart_expiry_seconds < 60 or
            self.s3_multipart_expiry_seconds > 30 * 24 * 60 * 60 or
            self.s3_lifecycle_scan_interval_seconds < 1 or
            self.s3_lifecycle_scan_interval_seconds > 24 * 60 * 60)
        {
            return error.InvalidS3Config;
        }
        if (self.admin_username.len == 0 or
            self.admin_username.len > max_admin_username_length or
            !isValidAdminUsername(self.admin_username) or
            self.admin_password.len == 0 or
            self.admin_password.len > max_admin_password_length or
            self.admin_session_secret.len < 32 or
            self.admin_session_secret.len > max_admin_session_secret_length or
            self.admin_session_ttl_seconds < 60 or
            self.admin_session_ttl_seconds > 24 * 60 * 60)
        {
            return error.InvalidAdminConfig;
        }
    }

    fn isValidAdminUsername(username: []const u8) bool {
        for (username) |character| {
            if (!std.ascii.isAlphanumeric(character) and
                character != '.' and
                character != '_' and
                character != '-' and
                character != '@')
            {
                return false;
            }
        }
        return true;
    }

    pub fn isValidS3Region(region: []const u8) bool {
        if (region.len == 0 or region.len > max_s3_region_length) return false;
        for (region) |character| {
            if (!std.ascii.isLower(character) and
                !std.ascii.isDigit(character) and
                character != '-')
            {
                return false;
            }
        }
        return region[0] != '-' and region[region.len - 1] != '-';
    }

    pub fn isValidPublicEndpoint(endpoint: []const u8) bool {
        const authority = if (std.mem.startsWith(u8, endpoint, "http://"))
            endpoint["http://".len..]
        else if (std.mem.startsWith(u8, endpoint, "https://"))
            endpoint["https://".len..]
        else
            return false;
        if (authority.len == 0 or
            std.mem.indexOfAny(u8, authority, "/?#@") != null)
        {
            return false;
        }
        for (authority) |character| {
            if (character <= 0x20 or character >= 0x7f) return false;
        }
        return true;
    }
};

test "built-in defaults are stable" {
    const config: Config = .{};
    try std.testing.expectEqualStrings("data", config.data_root);
    try std.testing.expectEqual(@as(usize, 64 * 1024), config.stream_buffer_size);
    try std.testing.expectEqualStrings("0.0.0.0:9000", config.api_address);
    try std.testing.expect(config.metrics_enabled);
    try std.testing.expectEqualStrings("127.0.0.1:9090", config.metrics_address);
    try std.testing.expectEqualStrings("http://127.0.0.1:9000", config.s3_public_endpoint);
    try std.testing.expect(!config.s3_virtual_hosted_style);
    try std.testing.expectEqualStrings("us-east-1", config.s3_region);
    try std.testing.expectEqual(@as(u64, 900), config.s3_request_time_skew_seconds);
    try std.testing.expectEqual(@as(u64, 7 * 24 * 60 * 60), config.s3_multipart_expiry_seconds);
    try std.testing.expectEqual(@as(u64, 300), config.s3_lifecycle_scan_interval_seconds);
    try std.testing.expectEqualStrings("admin", config.admin_username);
    try std.testing.expectEqualStrings("zigfs-admin", config.admin_password);
    try std.testing.expectEqual(@as(u64, 8 * 60 * 60), config.admin_session_ttl_seconds);
}

test "dotenv values override defaults" {
    var config: Config = .{};
    try config.applyEnv(
        \\ZIGFS_API_ADDRESS="127.0.0.1:19000"
        \\ZIGFS_METRICS_ENABLED=false
        \\ZIGFS_METRICS_ADDRESS="127.0.0.1:19090"
        \\ZIGFS_DATA_ROOT="test-data"
        \\ZIGFS_STREAM_BUFFER_SIZE=131072
        \\ZIGFS_S3_PUBLIC_ENDPOINT="https://objects.example.test"
        \\ZIGFS_S3_VIRTUAL_HOSTED_STYLE=true
        \\ZIGFS_S3_REGION="eu-central-1"
        \\ZIGFS_S3_REQUEST_TIME_SKEW_SECONDS=600
        \\ZIGFS_S3_MULTIPART_EXPIRY_SECONDS=86400
        \\ZIGFS_S3_LIFECYCLE_SCAN_INTERVAL_SECONDS=60
        \\ZIGFS_ROOT_USER="operator"
        \\ZIGFS_ROOT_PASSWORD="local-password"
        \\ZIGFS_ADMIN_SESSION_SECRET="0123456789abcdef0123456789abcdef"
        \\ZIGFS_ADMIN_SESSION_TTL_SECONDS=3600
    );

    try std.testing.expectEqualStrings("test-data", config.data_root);
    try std.testing.expectEqual(@as(usize, 131072), config.stream_buffer_size);
    try std.testing.expectEqualStrings("127.0.0.1:19000", config.api_address);
    try std.testing.expectEqualStrings("https://objects.example.test", config.s3_public_endpoint);
    try std.testing.expect(config.s3_virtual_hosted_style);
    try std.testing.expectEqualStrings("eu-central-1", config.s3_region);
    try std.testing.expectEqual(@as(u64, 600), config.s3_request_time_skew_seconds);
    try std.testing.expectEqual(@as(u64, 86400), config.s3_multipart_expiry_seconds);
    try std.testing.expectEqual(@as(u64, 60), config.s3_lifecycle_scan_interval_seconds);
    try std.testing.expect(!config.metrics_enabled);
    try std.testing.expectEqualStrings("127.0.0.1:19090", config.metrics_address);
    try std.testing.expectEqualStrings("operator", config.admin_username);
    try std.testing.expectEqualStrings("local-password", config.admin_password);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", config.admin_session_secret);
    try std.testing.expectEqual(@as(u64, 3600), config.admin_session_ttl_seconds);
}

test "S3 public endpoint is an absolute HTTP authority without path or credentials" {
    var config: Config = .{};
    try config.applyEnv(
        \\ZIGFS_S3_PUBLIC_ENDPOINT="ftp://objects.example.test"
    );
    try std.testing.expectError(error.InvalidS3Config, config.validate());

    config.s3_public_endpoint = "https://user@objects.example.test/path";
    try std.testing.expectError(error.InvalidS3Config, config.validate());
}

test "metadata maintenance settings parse and reject unsafe bounds" {
    var config: Config = .{};
    try config.applyEnv(
        \\ZIGFS_METADATA_MAINTENANCE_INTERVAL_SECONDS=5
        \\ZIGFS_METADATA_MAINTENANCE_BATCH_SIZE=250
    );
    try std.testing.expectEqual(@as(u64, 5), config.metadata_maintenance_interval_seconds);
    try std.testing.expectEqual(@as(usize, 250), config.metadata_maintenance_batch_size);
    try config.validate();
    config.metadata_maintenance_batch_size = 0;
    try std.testing.expectError(error.InvalidStorageConfig, config.validate());
    config.metadata_maintenance_batch_size = 10001;
    try std.testing.expectError(error.InvalidStorageConfig, config.validate());
    config.metadata_maintenance_batch_size = 1000;
    config.metadata_maintenance_interval_seconds = 0;
    try std.testing.expectError(error.InvalidStorageConfig, config.validate());
    config.metadata_maintenance_interval_seconds = 3601;
    try std.testing.expectError(error.InvalidStorageConfig, config.validate());
}

test "command line overrides dotenv" {
    const args = [_][]const u8{
        "zigfs",
        "--data-root",
        "cli-data",
    };
    var config: Config = .{ .data_root = "dotenv-data" };
    config = try Config.applyOverrides(config, &args);

    try std.testing.expectEqualStrings("cli-data", config.data_root);
}

test "reject invalid admin session configuration" {
    var config: Config = .{};
    try config.applyEnv(
        \\ZIGFS_ADMIN_SESSION_SECRET="too-short"
    );
    try std.testing.expectError(error.InvalidAdminConfig, config.validate());
}

test "reject unsafe stream buffer configuration" {
    var config: Config = .{};
    try config.applyEnv(
        \\ZIGFS_STREAM_BUFFER_SIZE=1024
    );
    try std.testing.expectError(error.InvalidStorageConfig, config.validate());
}

test "reject unsafe admin username" {
    var config: Config = .{};
    try config.applyEnv(
        \\ZIGFS_ROOT_USER="admin name"
    );
    try std.testing.expectError(error.InvalidAdminConfig, config.validate());
}

test "dotenv literals, comments, empty values and process overrides" {
    var config: Config = .{};
    try config.applyEnv("ZIGFS_ROOT_PASSWORD='literal$()#=password' # comment\r\nZIGFS_ACCESS_KEY=\nZIGFS_METRICS_ENABLED=false # comment\nZIGFS_ADMIN_PORT=9001\n");
    try std.testing.expectEqualStrings("literal$()#=password", config.admin_password);
    try std.testing.expect(!config.metrics_enabled);
    try config.applyEnvironment(.{ .admin_password = "process-password", .s3_region = "eu-west-1" });
    try std.testing.expectEqualStrings("process-password", config.admin_password);
    try std.testing.expectEqualStrings("eu-west-1", config.s3_region);
    try config.validate();
    try std.testing.expectError(error.InvalidEnv, config.applyEnv("lowercase=value"));
    try std.testing.expectError(error.InvalidEnv, config.applyEnv("ZIGFS_ROOT_PASSWORD='unclosed"));
    try config.applyEnvironment(.{ .root_access_key = "RootAccessKey123456" });
    try std.testing.expectError(error.InvalidRootCredentials, config.validate());
}
