const std = @import("std");

pub const Config = struct {
    pub const default_path = "config.yaml";
    pub const max_file_size = 1024 * 1024;
    pub const min_stream_buffer_size = 4 * 1024;
    pub const max_stream_buffer_size = 1024 * 1024;
    const max_admin_username_length = 128;
    const max_admin_password_length = 1024;
    const max_admin_session_secret_length = 4096;
    const max_s3_region_length = 63;

    data_root: []const u8 = "data",
    stream_buffer_size: usize = 64 * 1024,
    api_address: []const u8 = "0.0.0.0:9000",
    metrics_enabled: bool = true,
    metrics_address: []const u8 = "127.0.0.1:9090",
    s3_region: []const u8 = "us-east-1",
    s3_request_time_skew_seconds: u64 = 15 * 60,
    admin_username: []const u8 = "admin",
    admin_password: []const u8 = "zigfs-admin",
    admin_session_secret: []const u8 = "zigfs-local-session-secret-change-before-production",
    admin_session_ttl_seconds: u64 = 8 * 60 * 60,

    pub const ParseError = error{
        InvalidYaml,
        MissingValue,
        UnknownArgument,
        UnknownKey,
        InvalidAdminConfig,
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
        const arguments = try parseArguments(args);
        var config: Config = .{};

        const source = std.Io.Dir.cwd().readFileAlloc(
            io,
            arguments.config_path,
            allocator,
            .limited(max_file_size),
        ) catch |err| switch (err) {
            error.FileNotFound => {
                if (arguments.config_path_explicit) return err;
                config = try applyOverrides(config, args);
                try config.validate();
                return config;
            },
            else => return err,
        };

        try config.applyYaml(source);
        config = try applyOverrides(config, args);
        try config.validate();
        return config;
    }

    pub fn applyYaml(self: *Config, source: []const u8) ParseError!void {
        var section: enum { none, server, observability, storage, s3, admin } = .none;
        var lines = std.mem.splitScalar(u8, source, '\n');

        while (lines.next()) |raw_line| {
            const without_cr = std.mem.trimEnd(u8, raw_line, "\r");
            const content = std.mem.trim(u8, without_cr, " \t");
            if (content.len == 0 or content[0] == '#') continue;

            const left_trimmed = std.mem.trimStart(u8, without_cr, " ");
            const indentation = without_cr.len - left_trimmed.len;
            if (indentation == 0) {
                if (!std.mem.endsWith(u8, content, ":")) return error.InvalidYaml;
                const name = std.mem.trimEnd(u8, content[0 .. content.len - 1], " ");
                section = if (std.mem.eql(u8, name, "server"))
                    .server
                else if (std.mem.eql(u8, name, "observability"))
                    .observability
                else if (std.mem.eql(u8, name, "storage"))
                    .storage
                else if (std.mem.eql(u8, name, "s3"))
                    .s3
                else if (std.mem.eql(u8, name, "admin"))
                    .admin
                else
                    return error.UnknownKey;
                continue;
            }

            if (indentation != 2 or section == .none) return error.InvalidYaml;
            const separator = std.mem.indexOfScalar(u8, content, ':') orelse return error.InvalidYaml;
            const key = std.mem.trim(u8, content[0..separator], " ");
            const value = try scalarValue(content[separator + 1 ..]);

            switch (section) {
                .server => {
                    if (std.mem.eql(u8, key, "api_address")) {
                        self.api_address = value;
                    } else {
                        return error.UnknownKey;
                    }
                },
                .observability => {
                    if (std.mem.eql(u8, key, "metrics_enabled")) {
                        self.metrics_enabled = try booleanValue(value);
                    } else if (std.mem.eql(u8, key, "metrics_address")) {
                        self.metrics_address = value;
                    } else {
                        return error.UnknownKey;
                    }
                },
                .storage => {
                    if (std.mem.eql(u8, key, "data_root")) {
                        self.data_root = value;
                    } else if (std.mem.eql(u8, key, "stream_buffer_size")) {
                        self.stream_buffer_size = std.fmt.parseInt(usize, value, 10) catch {
                            return error.InvalidYaml;
                        };
                    } else {
                        return error.UnknownKey;
                    }
                },
                .s3 => {
                    if (std.mem.eql(u8, key, "region")) {
                        self.s3_region = value;
                    } else if (std.mem.eql(u8, key, "request_time_skew_seconds")) {
                        self.s3_request_time_skew_seconds = std.fmt.parseInt(u64, value, 10) catch {
                            return error.InvalidYaml;
                        };
                    } else {
                        return error.UnknownKey;
                    }
                },
                .admin => {
                    if (std.mem.eql(u8, key, "username")) {
                        self.admin_username = value;
                    } else if (std.mem.eql(u8, key, "password")) {
                        self.admin_password = value;
                    } else if (std.mem.eql(u8, key, "session_secret")) {
                        self.admin_session_secret = value;
                    } else if (std.mem.eql(u8, key, "session_ttl_seconds")) {
                        self.admin_session_ttl_seconds = std.fmt.parseInt(u64, value, 10) catch {
                            return error.InvalidYaml;
                        };
                    } else {
                        return error.UnknownKey;
                    }
                },
                .none => unreachable,
            }
        }
    }

    fn parseArguments(args: []const []const u8) ParseError!Arguments {
        var parsed: Arguments = .{};
        var index: usize = 1;
        while (index < args.len) : (index += 1) {
            const argument = args[index];
            if (std.mem.eql(u8, argument, "--config")) {
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

            if (std.mem.eql(u8, argument, "--config")) {
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
        if (value.len == 0) return error.MissingValue;

        if (value[0] == '"' or value[0] == '\'') {
            if (value.len < 2 or value[value.len - 1] != value[0]) return error.InvalidYaml;
            return value[1 .. value.len - 1];
        }
        return value;
    }

    fn booleanValue(value: []const u8) ParseError!bool {
        if (std.mem.eql(u8, value, "true")) return true;
        if (std.mem.eql(u8, value, "false")) return false;
        return error.InvalidYaml;
    }

    fn validate(self: Config) ParseError!void {
        if (self.stream_buffer_size < min_stream_buffer_size or
            self.stream_buffer_size > max_stream_buffer_size)
        {
            return error.InvalidStorageConfig;
        }
        if (self.s3_region.len == 0 or self.s3_region.len > max_s3_region_length or
            !isValidS3Region(self.s3_region) or
            self.s3_request_time_skew_seconds < 60 or
            self.s3_request_time_skew_seconds > 60 * 60)
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

    fn isValidS3Region(region: []const u8) bool {
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
};

test "built-in defaults are stable" {
    const config: Config = .{};
    try std.testing.expectEqualStrings("data", config.data_root);
    try std.testing.expectEqual(@as(usize, 64 * 1024), config.stream_buffer_size);
    try std.testing.expectEqualStrings("0.0.0.0:9000", config.api_address);
    try std.testing.expect(config.metrics_enabled);
    try std.testing.expectEqualStrings("127.0.0.1:9090", config.metrics_address);
    try std.testing.expectEqualStrings("us-east-1", config.s3_region);
    try std.testing.expectEqual(@as(u64, 900), config.s3_request_time_skew_seconds);
    try std.testing.expectEqualStrings("admin", config.admin_username);
    try std.testing.expectEqualStrings("zigfs-admin", config.admin_password);
    try std.testing.expectEqual(@as(u64, 8 * 60 * 60), config.admin_session_ttl_seconds);
}

test "yaml values override defaults" {
    var config: Config = .{};
    try config.applyYaml(
        \\server:
        \\  api_address: "127.0.0.1:19000"
        \\observability:
        \\  metrics_enabled: false
        \\  metrics_address: "127.0.0.1:19090"
        \\storage:
        \\  data_root: "test-data"
        \\  stream_buffer_size: 131072
        \\s3:
        \\  region: "eu-central-1"
        \\  request_time_skew_seconds: 600
        \\admin:
        \\  username: "operator"
        \\  password: "local-password"
        \\  session_secret: "0123456789abcdef0123456789abcdef"
        \\  session_ttl_seconds: 3600
    );

    try std.testing.expectEqualStrings("test-data", config.data_root);
    try std.testing.expectEqual(@as(usize, 131072), config.stream_buffer_size);
    try std.testing.expectEqualStrings("127.0.0.1:19000", config.api_address);
    try std.testing.expectEqualStrings("eu-central-1", config.s3_region);
    try std.testing.expectEqual(@as(u64, 600), config.s3_request_time_skew_seconds);
    try std.testing.expect(!config.metrics_enabled);
    try std.testing.expectEqualStrings("127.0.0.1:19090", config.metrics_address);
    try std.testing.expectEqualStrings("operator", config.admin_username);
    try std.testing.expectEqualStrings("local-password", config.admin_password);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", config.admin_session_secret);
    try std.testing.expectEqual(@as(u64, 3600), config.admin_session_ttl_seconds);
}

test "command line overrides yaml" {
    const args = [_][]const u8{
        "zigfs",
        "--data-root",
        "cli-data",
    };
    var config: Config = .{ .data_root = "yaml-data" };
    config = try Config.applyOverrides(config, &args);

    try std.testing.expectEqualStrings("cli-data", config.data_root);
}

test "reject unknown yaml key" {
    var config: Config = .{};
    try std.testing.expectError(error.UnknownKey, config.applyYaml(
        \\storage:
        \\  database: "external"
    ));
}

test "reject invalid admin session configuration" {
    var config: Config = .{};
    try config.applyYaml(
        \\admin:
        \\  session_secret: "too-short"
    );
    try std.testing.expectError(error.InvalidAdminConfig, config.validate());
}

test "reject unsafe stream buffer configuration" {
    var config: Config = .{};
    try config.applyYaml(
        \\storage:
        \\  stream_buffer_size: 1024
    );
    try std.testing.expectError(error.InvalidStorageConfig, config.validate());
}

test "reject unsafe admin username" {
    var config: Config = .{};
    try config.applyYaml(
        \\admin:
        \\  username: "admin name"
    );
    try std.testing.expectError(error.InvalidAdminConfig, config.validate());
}
