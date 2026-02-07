const std = @import("std");
const logging = @import("../util/logging.zig");
const exec = @import("../container/exec.zig");

pub const StreamingError = error{
    BindFailed,
    AcceptFailed,
    SessionNotFound,
    InvalidRequest,
    IoError,
    OutOfMemory,
};

/// HTTP streaming server for exec/attach
pub const StreamingServer = struct {
    allocator: std.mem.Allocator,
    executor: *exec.Executor,
    address: std.net.Address,
    server: ?std.net.Server = null,
    running: bool = false,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        executor: *exec.Executor,
        port: u16,
    ) Self {
        return Self{
            .allocator = allocator,
            .executor = executor,
            .address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port),
            .server = null,
            .running = false,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
    }

    /// Start the streaming server
    pub fn start(self: *Self) StreamingError!void {
        logging.info("Starting streaming server on port {d}", .{self.address.getPort()});

        self.server = std.net.Address.listen(self.address, .{
            .reuse_address = true,
        }) catch return StreamingError.BindFailed;

        self.running = true;
    }

    /// Stop the streaming server
    pub fn stop(self: *Self) void {
        self.running = false;
        if (self.server) |*s| {
            s.deinit();
            self.server = null;
        }
    }

    /// Accept and handle connections (call in a loop)
    pub fn acceptConnection(self: *Self) StreamingError!void {
        if (self.server == null) return;

        const conn = self.server.?.accept() catch return StreamingError.AcceptFailed;
        defer conn.stream.close();

        self.handleConnection(conn) catch |err| {
            logging.err("Error handling streaming connection: {}", .{err});
        };
    }

    fn handleConnection(self: *Self, conn: std.net.Server.Connection) !void {
        var buf: [4096]u8 = undefined;
        const n = conn.stream.read(&buf) catch return StreamingError.IoError;

        if (n == 0) return;

        const request = buf[0..n];

        // Parse HTTP request (simple parsing)
        var lines = std.mem.splitSequence(u8, request, "\r\n");
        const request_line = lines.next() orelse return StreamingError.InvalidRequest;

        var parts = std.mem.splitScalar(u8, request_line, ' ');
        const method = parts.next() orelse return StreamingError.InvalidRequest;
        const path = parts.next() orelse return StreamingError.InvalidRequest;

        if (!std.mem.eql(u8, method, "GET") and !std.mem.eql(u8, method, "POST")) {
            try self.sendResponse(conn.stream, 405, "Method Not Allowed");
            return;
        }

        // Route the request
        if (std.mem.startsWith(u8, path, "/exec/")) {
            const session_id = path[6..];
            try self.handleExec(conn.stream, session_id);
        } else if (std.mem.startsWith(u8, path, "/attach/")) {
            const container_id = path[8..];
            try self.handleAttach(conn.stream, container_id);
        } else {
            try self.sendResponse(conn.stream, 404, "Not Found");
        }
    }

    fn handleExec(self: *Self, stream: std.net.Stream, session_id: []const u8) !void {
        const session = self.executor.getSession(session_id) orelse {
            try self.sendResponse(stream, 404, "Session not found");
            return;
        };

        // Upgrade to streaming protocol
        try self.sendResponse(stream, 101, "Switching Protocols");

        // Execute the command and stream output
        if (session.cmd.len > 0) {
            var response = self.executor.execSync(
                session.container_id,
                session.cmd,
                0, // no timeout for streaming
            ) catch |err| {
                const msg = std.fmt.allocPrint(self.allocator, "Exec failed: {}", .{err}) catch return;
                defer self.allocator.free(msg);
                _ = stream.write(msg) catch {};
                return;
            };
            defer response.deinit(self.allocator);

            // Send stdout
            if (response.stdout.len > 0) {
                _ = stream.write(response.stdout) catch {};
            }

            // Send stderr
            if (response.stderr.len > 0) {
                _ = stream.write(response.stderr) catch {};
            }
        }

        // Clean up session
        self.executor.removeSession(session_id);
    }

    fn handleAttach(self: *Self, stream: std.net.Stream, container_id: []const u8) !void {
        _ = container_id;

        // For attach, we'd connect to the container's main process
        // This is a simplified implementation
        try self.sendResponse(stream, 101, "Switching Protocols");

        // In a full implementation, we'd:
        // 1. Get the container's main process PID
        // 2. Connect to its stdin/stdout/stderr
        // 3. Proxy data between the HTTP stream and the process
        _ = stream.write("Attach not fully implemented\n") catch {};
    }

    fn sendResponse(self: *Self, stream: std.net.Stream, status: u16, message: []const u8) !void {
        _ = self;
        var buf: [1024]u8 = undefined;
        const response = std.fmt.bufPrint(&buf, "HTTP/1.1 {d} {s}\r\nConnection: close\r\n\r\n", .{ status, message }) catch return;
        _ = stream.write(response) catch {};
    }

    /// Get the streaming server URL base
    pub fn getBaseUrl(self: *Self) ![]const u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "http://127.0.0.1:{d}",
            .{self.address.getPort()},
        );
    }
};

/// WebSocket frame for streaming (simplified)
pub const StreamFrame = struct {
    stream_type: StreamType,
    data: []const u8,

    pub const StreamType = enum(u8) {
        stdin = 0,
        stdout = 1,
        stderr = 2,
        resize = 3,
        close = 4,
    };

    pub fn encode(self: *const StreamFrame, allocator: std.mem.Allocator) ![]u8 {
        var result = try allocator.alloc(u8, 1 + self.data.len);
        result[0] = @intFromEnum(self.stream_type);
        @memcpy(result[1..], self.data);
        return result;
    }

    pub fn decode(data: []const u8) ?StreamFrame {
        if (data.len < 1) return null;
        return StreamFrame{
            .stream_type = @enumFromInt(data[0]),
            .data = data[1..],
        };
    }
};

/// Terminal resize request
pub const ResizeRequest = struct {
    width: u16,
    height: u16,
};
