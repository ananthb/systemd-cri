const std = @import("std");

pub const Level = enum {
    debug,
    info,
    warn,
    err,

    pub fn toString(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

pub const Logger = struct {
    min_level: Level,

    const Self = @This();

    pub fn init(min_level: Level) Self {
        return .{
            .min_level = min_level,
        };
    }

    pub fn log(self: *const Self, level: Level, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(level) < @intFromEnum(self.min_level)) {
            return;
        }

        const timestamp = std.time.timestamp();
        std.debug.print("{d} [{s}] " ++ fmt ++ "\n", .{timestamp, level.toString()} ++ args);
    }

    pub fn debug(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }

    pub fn info(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    pub fn warn(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    pub fn err(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }
};

/// Global logger instance
var global_logger: ?Logger = null;

pub fn initGlobal(min_level: Level) void {
    global_logger = Logger.init(min_level);
}

pub fn getGlobal() *const Logger {
    if (global_logger) |*logger| {
        return logger;
    }
    // Initialize with default level if not already initialized
    global_logger = Logger.init(.info);
    return &global_logger.?;
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    getGlobal().debug(fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    getGlobal().info(fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    getGlobal().warn(fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    getGlobal().err(fmt, args);
}

test "logger basic" {
    const logger = Logger.init(.debug);
    logger.info("test message: {s}", .{"hello"});
}
