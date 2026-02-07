const std = @import("std");
const prometheus = @import("prometheus.zig");
const logging = @import("../util/logging.zig");

pub const MetricsServerError = error{
    BindFailed,
    AcceptFailed,
    IoError,
    OutOfMemory,
};

/// HTTP server for Prometheus metrics endpoint
pub const MetricsServer = struct {
    allocator: std.mem.Allocator,
    registry: *prometheus.Registry,
    address: std.net.Address,
    server: ?std.net.Server = null,
    running: bool = false,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        registry: *prometheus.Registry,
        port: u16,
    ) Self {
        return Self{
            .allocator = allocator,
            .registry = registry,
            .address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port),
            .server = null,
            .running = false,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
    }

    /// Start the metrics server
    pub fn start(self: *Self) MetricsServerError!void {
        logging.info("Starting metrics server on port {d}", .{self.address.getPort()});

        self.server = std.net.Address.listen(self.address, .{
            .reuse_address = true,
        }) catch return MetricsServerError.BindFailed;

        self.running = true;
    }

    /// Stop the metrics server
    pub fn stop(self: *Self) void {
        self.running = false;
        if (self.server) |*s| {
            s.deinit();
            self.server = null;
        }
    }

    /// Accept and handle connections (call in a loop or use run())
    pub fn acceptConnection(self: *Self) MetricsServerError!void {
        if (self.server == null) return;

        const conn = self.server.?.accept() catch return MetricsServerError.AcceptFailed;
        defer conn.stream.close();

        self.handleConnection(conn.stream) catch |err| {
            logging.debug("Error handling metrics connection: {}", .{err});
        };
    }

    fn handleConnection(self: *Self, stream: std.net.Stream) !void {
        var buf: [4096]u8 = undefined;
        const n = stream.read(&buf) catch return;

        if (n == 0) return;

        const request = buf[0..n];

        // Parse HTTP request line
        var lines = std.mem.splitSequence(u8, request, "\r\n");
        const request_line = lines.next() orelse return;

        var parts = std.mem.splitScalar(u8, request_line, ' ');
        const method = parts.next() orelse return;
        const path = parts.next() orelse return;

        if (!std.mem.eql(u8, method, "GET")) {
            try self.sendError(stream, 405, "Method Not Allowed");
            return;
        }

        if (std.mem.eql(u8, path, "/metrics")) {
            try self.handleMetrics(stream);
        } else if (std.mem.eql(u8, path, "/health") or std.mem.eql(u8, path, "/healthz")) {
            try self.handleHealth(stream);
        } else if (std.mem.eql(u8, path, "/ready") or std.mem.eql(u8, path, "/readyz")) {
            try self.handleReady(stream);
        } else {
            try self.sendError(stream, 404, "Not Found");
        }
    }

    fn handleMetrics(self: *Self, stream: std.net.Stream) !void {
        const metrics_data = self.registry.render(self.allocator) catch |err| {
            logging.err("Failed to export metrics: {}", .{err});
            try self.sendError(stream, 500, "Internal Server Error");
            return;
        };
        defer self.allocator.free(metrics_data);

        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf,
            \\HTTP/1.1 200 OK
            \\Content-Type: text/plain; version=0.0.4; charset=utf-8
            \\Content-Length: {d}
            \\Connection: close
            \\
            \\
        , .{metrics_data.len}) catch return;

        _ = stream.write(header) catch return;
        _ = stream.write(metrics_data) catch return;
    }

    fn handleHealth(self: *Self, stream: std.net.Stream) !void {
        _ = self;
        const response =
            \\HTTP/1.1 200 OK
            \\Content-Type: application/json
            \\Content-Length: 15
            \\Connection: close
            \\
            \\{"status":"ok"}
        ;
        _ = stream.write(response) catch return;
    }

    fn handleReady(self: *Self, stream: std.net.Stream) !void {
        const runtime_ready = self.registry.runtime_ready.get() == 1;
        if (runtime_ready) {
            const response =
                \\HTTP/1.1 200 OK
                \\Content-Type: application/json
                \\Content-Length: 18
                \\Connection: close
                \\
                \\{"status":"ready"}
            ;
            _ = stream.write(response) catch return;
        } else {
            const response =
                \\HTTP/1.1 503 Service Unavailable
                \\Content-Type: application/json
                \\Content-Length: 22
                \\Connection: close
                \\
                \\{"status":"not_ready"}
            ;
            _ = stream.write(response) catch return;
        }
    }

    fn sendError(self: *Self, stream: std.net.Stream, status: u16, message: []const u8) !void {
        _ = self;
        var buf: [512]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}", .{message}) catch return;

        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf,
            \\HTTP/1.1 {d} {s}
            \\Content-Type: application/json
            \\Content-Length: {d}
            \\Connection: close
            \\
            \\
        , .{ status, message, body.len }) catch return;

        _ = stream.write(header) catch return;
        _ = stream.write(body) catch return;
    }

    /// Get the metrics server URL
    pub fn getUrl(self: *Self) ![]const u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "http://0.0.0.0:{d}/metrics",
            .{self.address.getPort()},
        );
    }
};

test "metrics server init" {
    const allocator = std.testing.allocator;
    var registry = prometheus.Registry.init(allocator);
    defer registry.deinit();

    var server = MetricsServer.init(allocator, &registry, 9090);
    defer server.deinit();

    try std.testing.expectEqual(@as(u16, 9090), server.address.getPort());
}
