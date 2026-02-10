const std = @import("std");
const posix = std.posix;
const logging = @import("../util/logging.zig");
const exec = @import("../container/exec.zig");
const store = @import("../state/store.zig");

pub const StreamingError = error{
    BindFailed,
    AcceptFailed,
    SessionNotFound,
    InvalidRequest,
    IoError,
    OutOfMemory,
    PodNotFound,
    ConnectionFailed,
    SpawnFailed,
    PollFailed,
};

/// HTTP streaming server for exec/attach/portforward
pub const StreamingServer = struct {
    allocator: std.mem.Allocator,
    executor: *exec.Executor,
    address: std.net.Address,
    server: ?std.net.Server = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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

        self.running.store(true, .release);

        // Start accept thread
        const thread = std.Thread.spawn(.{}, acceptLoop, .{self}) catch {
            logging.err("Failed to spawn streaming server thread", .{});
            return StreamingError.BindFailed;
        };
        thread.detach();
    }

    /// Stop the streaming server
    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
        if (self.server) |*s| {
            s.deinit();
            self.server = null;
        }
    }

    fn acceptLoop(self: *Self) void {
        while (self.running.load(.acquire)) {
            self.acceptConnection() catch |err| {
                if (!self.running.load(.acquire)) break;
                logging.debug("Accept error: {}", .{err});
            };
        }
    }

    /// Accept and handle connections
    pub fn acceptConnection(self: *Self) StreamingError!void {
        if (self.server == null) return StreamingError.BindFailed;

        const conn = self.server.?.accept() catch return StreamingError.AcceptFailed;

        // Spawn thread to handle connection
        const thread = std.Thread.spawn(.{}, handleConnectionThread, .{ self, conn }) catch {
            conn.stream.close();
            return StreamingError.OutOfMemory;
        };
        thread.detach();
    }

    fn handleConnectionThread(self: *Self, conn: std.net.Server.Connection) void {
        defer conn.stream.close();
        self.handleConnection(conn) catch |err| {
            logging.err("Error handling streaming connection: {}", .{err});
        };
    }

    fn handleConnection(self: *Self, conn: std.net.Server.Connection) !void {
        var buf: [8192]u8 = undefined;
        const n = conn.stream.read(&buf) catch return StreamingError.IoError;

        if (n == 0) return;

        const request = buf[0..n];

        // Parse HTTP request
        var lines = std.mem.splitSequence(u8, request, "\r\n");
        const request_line = lines.next() orelse return StreamingError.InvalidRequest;

        var parts = std.mem.splitScalar(u8, request_line, ' ');
        const method = parts.next() orelse return StreamingError.InvalidRequest;
        const path = parts.next() orelse return StreamingError.InvalidRequest;

        logging.debug("Streaming request: {s} {s}", .{ method, path });

        if (!std.mem.eql(u8, method, "GET") and !std.mem.eql(u8, method, "POST")) {
            try self.sendErrorResponse(conn.stream, 405, "Method Not Allowed");
            return;
        }

        // Route the request based on path
        if (std.mem.startsWith(u8, path, "/exec/")) {
            const session_id = path[6..];
            try self.handleExecStream(conn.stream, session_id);
        } else if (std.mem.startsWith(u8, path, "/attach/")) {
            const session_id = path[8..];
            try self.handleAttachStream(conn.stream, session_id);
        } else if (std.mem.startsWith(u8, path, "/portforward/")) {
            const session_id = path[13..];
            try self.handlePortForwardStream(conn.stream, session_id);
        } else {
            try self.sendErrorResponse(conn.stream, 404, "Not Found");
        }
    }

    fn handleExecStream(self: *Self, stream: std.net.Stream, session_id: []const u8) !void {
        const session = self.executor.getSession(session_id) orelse {
            try self.sendErrorResponse(stream, 404, "Session not found");
            return;
        };

        logging.info("Exec streaming: session={s} container={s} tty={}", .{
            session_id,
            session.container_id,
            session.tty,
        });

        // Get container info
        const container_info = self.executor.state_store.getContainer(session.container_id) catch {
            try self.sendErrorResponse(stream, 404, "Container not found");
            self.executor.removeSession(session_id);
            return;
        };
        defer {
            var c = container_info;
            c.deinit(self.allocator);
        }

        if (container_info.state != .running) {
            try self.sendErrorResponse(stream, 400, "Container not running");
            self.executor.removeSession(session_id);
            return;
        }

        const pid = container_info.pid orelse {
            try self.sendErrorResponse(stream, 500, "Container has no PID");
            self.executor.removeSession(session_id);
            return;
        };

        // Send upgrade response
        try self.sendUpgradeResponse(stream);

        // Build nsenter command
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);

        try args.append(self.allocator,self.executor.nsenter_path);
        try args.append(self.allocator,"-t");

        const pid_str = try std.fmt.allocPrint(self.allocator, "{d}", .{pid});
        defer self.allocator.free(pid_str);
        try args.append(self.allocator,pid_str);

        // Enter all namespaces
        try args.append(self.allocator,"-m"); // mount
        try args.append(self.allocator,"-u"); // UTS
        try args.append(self.allocator,"-i"); // IPC
        try args.append(self.allocator,"-n"); // network
        try args.append(self.allocator,"-p"); // PID
        try args.append(self.allocator,"-r"); // root
        try args.append(self.allocator,"-w"); // working dir

        // Add command arguments with path resolution
        for (session.cmd, 0..) |arg, i| {
            if (i == 0) {
                // Resolve common commands to absolute paths
                const resolved = resolveCommand(self.allocator, arg) catch arg;
                try args.append(self.allocator,resolved);
            } else {
                try args.append(self.allocator,arg);
            }
        }

        // Spawn the child process
        var child = std.process.Child.init(args.items, self.allocator);
        child.stdin_behavior = if (session.stdin) .Pipe else .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.spawn() catch {
            try self.sendStreamFrame(stream, .stderr, "Failed to spawn process\n");
            self.executor.removeSession(session_id);
            return;
        };

        // Bidirectional streaming using poll
        self.streamBidirectional(
            stream,
            child.stdin,
            child.stdout,
            child.stderr,
            session.stdin,
        );

        // Wait for child to exit
        const term = child.wait() catch {
            self.executor.removeSession(session_id);
            return;
        };

        // Send exit code
        const exit_code: i32 = switch (term) {
            .Exited => |code| @intCast(code),
            .Signal => |sig| -@as(i32, @intCast(sig)),
            else => -1,
        };

        logging.debug("Exec process exited with code {d}", .{exit_code});

        // Clean up session
        self.executor.removeSession(session_id);
    }

    fn handleAttachStream(self: *Self, stream: std.net.Stream, session_id: []const u8) !void {
        const session = self.executor.getSession(session_id) orelse {
            try self.sendErrorResponse(stream, 404, "Session not found");
            return;
        };

        logging.info("Attach streaming: session={s} container={s}", .{ session_id, session.container_id });

        // Get container info
        const container_info = self.executor.state_store.getContainer(session.container_id) catch {
            try self.sendErrorResponse(stream, 404, "Container not found");
            self.executor.removeSession(session_id);
            return;
        };
        defer {
            var c = container_info;
            c.deinit(self.allocator);
        }

        if (container_info.state != .running) {
            try self.sendErrorResponse(stream, 400, "Container not running");
            self.executor.removeSession(session_id);
            return;
        }

        const pid = container_info.pid orelse {
            try self.sendErrorResponse(stream, 500, "Container has no PID");
            self.executor.removeSession(session_id);
            return;
        };

        // Send upgrade response
        try self.sendUpgradeResponse(stream);

        // For attach, we run a shell in the container's namespaces that connects
        // to the main process's terminal. We use nsenter to enter all namespaces
        // and then cat the process's stdout/stderr while forwarding stdin.
        //
        // Note: True attach would require a console socket set up at container start.
        // This implementation spawns a shell in the container's context.
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);

        try args.append(self.allocator,self.executor.nsenter_path);
        try args.append(self.allocator,"-t");

        const pid_str = try std.fmt.allocPrint(self.allocator, "{d}", .{pid});
        defer self.allocator.free(pid_str);
        try args.append(self.allocator,pid_str);

        // Enter all namespaces
        try args.append(self.allocator,"-m");
        try args.append(self.allocator,"-u");
        try args.append(self.allocator,"-i");
        try args.append(self.allocator,"-n");
        try args.append(self.allocator,"-p");
        try args.append(self.allocator,"-r");
        try args.append(self.allocator,"-w");

        // For attach mode without a specific command, spawn a shell
        try args.append(self.allocator,"/bin/sh");

        // Spawn the child process
        var child = std.process.Child.init(args.items, self.allocator);
        child.stdin_behavior = if (session.stdin) .Pipe else .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.spawn() catch {
            try self.sendStreamFrame(stream, .stderr, "Failed to attach to container\n");
            self.executor.removeSession(session_id);
            return;
        };

        // Bidirectional streaming
        self.streamBidirectional(
            stream,
            child.stdin,
            child.stdout,
            child.stderr,
            session.stdin,
        );

        // Wait for child to exit
        _ = child.wait() catch {};

        // Clean up session
        self.executor.removeSession(session_id);
    }

    fn handlePortForwardStream(self: *Self, stream: std.net.Stream, session_id: []const u8) !void {
        const session = self.executor.getSession(session_id) orelse {
            try self.sendErrorResponse(stream, 404, "Session not found");
            return;
        };

        logging.info("Port forward: session={s} pod={s} ports={any}", .{
            session_id,
            session.container_id,
            session.ports,
        });

        if (session.ports.len == 0) {
            try self.sendErrorResponse(stream, 400, "No ports specified");
            self.executor.removeSession(session_id);
            return;
        }

        // Get pod info to find a container PID for the network namespace
        const pod_info = self.executor.state_store.loadPod(session.container_id) catch {
            try self.sendErrorResponse(stream, 404, "Pod not found");
            self.executor.removeSession(session_id);
            return;
        };
        defer {
            var p = pod_info;
            p.deinit(self.allocator);
        }

        if (pod_info.state != .ready) {
            try self.sendErrorResponse(stream, 400, "Pod not ready");
            self.executor.removeSession(session_id);
            return;
        }

        // Get PID from a container in this pod for the network namespace
        var containers = self.executor.state_store.listContainersForPod(session.container_id) catch {
            try self.sendErrorResponse(stream, 500, "Cannot find pod containers");
            self.executor.removeSession(session_id);
            return;
        };
        defer {
            for (containers.items) |cid| self.allocator.free(cid);
            containers.deinit(self.allocator);
        }

        if (containers.items.len == 0) {
            try self.sendErrorResponse(stream, 500, "Pod has no containers");
            self.executor.removeSession(session_id);
            return;
        }

        // Get PID from first running container
        var pod_pid: ?u32 = null;
        for (containers.items) |cid| {
            const cont = self.executor.state_store.getContainer(cid) catch continue;
            defer {
                var c = cont;
                c.deinit(self.allocator);
            }
            if (cont.state == .running and cont.pid != null) {
                pod_pid = cont.pid;
                break;
            }
        }

        if (pod_pid == null) {
            try self.sendErrorResponse(stream, 500, "No running container with PID found");
            self.executor.removeSession(session_id);
            return;
        }

        // Send upgrade response
        try self.sendUpgradeResponse(stream);

        const target_port = session.ports[0];

        // Use socat via nsenter to forward the port
        // nsenter -t <pid> -n socat - TCP:127.0.0.1:<port>
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);

        try args.append(self.allocator,self.executor.nsenter_path);
        try args.append(self.allocator,"-t");

        const pid_str = try std.fmt.allocPrint(self.allocator, "{d}", .{pod_pid.?});
        defer self.allocator.free(pid_str);
        try args.append(self.allocator,pid_str);

        try args.append(self.allocator,"-n"); // Only enter network namespace

        // Use socat or nc to connect to the port
        // Try socat first, fall back to basic shell redirect
        try args.append(self.allocator,"/bin/sh");
        try args.append(self.allocator,"-c");

        const connect_cmd = try std.fmt.allocPrint(
            self.allocator,
            "exec 3<>/dev/tcp/127.0.0.1/{d} && cat <&3 & cat >&3",
            .{target_port},
        );
        defer self.allocator.free(connect_cmd);
        try args.append(self.allocator,connect_cmd);

        // Spawn the proxy process
        var child = std.process.Child.init(args.items, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.spawn() catch {
            try self.sendStreamFrame(stream, .stderr, "Failed to start port forward\n");
            self.executor.removeSession(session_id);
            return;
        };

        // Bidirectional streaming
        self.streamBidirectional(
            stream,
            child.stdin,
            child.stdout,
            child.stderr,
            true, // Port forward always accepts stdin
        );

        // Wait for child to exit
        _ = child.wait() catch {};

        // Clean up session
        self.executor.removeSession(session_id);
    }

    /// Bidirectional streaming between HTTP stream and child process
    fn streamBidirectional(
        self: *Self,
        http_stream: std.net.Stream,
        child_stdin: ?std.fs.File,
        child_stdout: ?std.fs.File,
        child_stderr: ?std.fs.File,
        enable_stdin: bool,
    ) void {
        _ = self;

        const http_fd = http_stream.handle;
        const stdout_fd = if (child_stdout) |f| f.handle else -1;
        const stderr_fd = if (child_stderr) |f| f.handle else -1;

        // Set up poll fds
        var poll_fds: [3]posix.pollfd = undefined;
        var nfds: usize = 0;

        // HTTP stream (for reading client input)
        poll_fds[nfds] = .{
            .fd = http_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        };
        nfds += 1;

        // Child stdout
        if (stdout_fd != -1) {
            poll_fds[nfds] = .{
                .fd = stdout_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            };
            nfds += 1;
        }

        // Child stderr
        if (stderr_fd != -1) {
            poll_fds[nfds] = .{
                .fd = stderr_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            };
            nfds += 1;
        }

        var buf: [8192]u8 = undefined;

        while (true) {
            const ready = posix.poll(poll_fds[0..nfds], 100) catch break;

            if (ready == 0) continue; // Timeout, check again

            // Check for data from HTTP client (stdin to child)
            if (poll_fds[0].revents & posix.POLL.IN != 0) {
                const n = posix.read(http_fd, &buf) catch break;
                if (n == 0) break; // Client disconnected

                // The streaming protocol uses the first byte as stream type
                if (n > 0 and enable_stdin) {
                    const frame = StreamFrame.decode(buf[0..n]);
                    if (frame) |f| {
                        if (f.stream_type == .stdin and child_stdin != null) {
                            _ = child_stdin.?.write(f.data) catch break;
                        } else if (f.stream_type == .resize) {
                            // Handle terminal resize (would need ioctl for PTY)
                        } else if (f.stream_type == .close) {
                            break;
                        }
                    }
                }
            }

            // Check for HUP on HTTP stream
            if (poll_fds[0].revents & posix.POLL.HUP != 0) {
                break;
            }

            // Check for data from child stdout
            const stdout_idx: usize = 1;
            if (stdout_fd != -1 and nfds > stdout_idx) {
                if (poll_fds[stdout_idx].revents & posix.POLL.IN != 0) {
                    const n = posix.read(stdout_fd, &buf) catch break;
                    if (n > 0) {
                        // Send with stdout frame prefix
                        const header = [_]u8{@intFromEnum(StreamFrame.StreamType.stdout)};
                        _ = posix.write(http_fd, &header) catch break;
                        _ = posix.write(http_fd, buf[0..n]) catch break;
                    }
                }
                if (poll_fds[stdout_idx].revents & posix.POLL.HUP != 0) {
                    // stdout closed, continue for stderr
                }
            }

            // Check for data from child stderr
            const stderr_idx: usize = if (stdout_fd != -1) 2 else 1;
            if (stderr_fd != -1 and nfds > stderr_idx) {
                if (poll_fds[stderr_idx].revents & posix.POLL.IN != 0) {
                    const n = posix.read(stderr_fd, &buf) catch break;
                    if (n > 0) {
                        // Send with stderr frame prefix
                        const header = [_]u8{@intFromEnum(StreamFrame.StreamType.stderr)};
                        _ = posix.write(http_fd, &header) catch break;
                        _ = posix.write(http_fd, buf[0..n]) catch break;
                    }
                }
                if (poll_fds[stderr_idx].revents & posix.POLL.HUP != 0) {
                    break; // Child process ended
                }
            }

            // Check for errors on any fd
            for (poll_fds[0..nfds]) |pfd| {
                if (pfd.revents & posix.POLL.ERR != 0 or pfd.revents & posix.POLL.NVAL != 0) {
                    return;
                }
            }
        }

        // Close child stdin to signal EOF
        if (child_stdin) |stdin| {
            stdin.close();
        }
    }

    fn sendUpgradeResponse(self: *Self, stream: std.net.Stream) !void {
        _ = self;
        const response =
            "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Upgrade: SPDY/3.1\r\n" ++
            "X-Stream-Protocol-Version: v4.channel.k8s.io\r\n" ++
            "\r\n";
        _ = stream.write(response) catch return StreamingError.IoError;
    }

    fn sendErrorResponse(self: *Self, stream: std.net.Stream, status: u16, message: []const u8) !void {
        _ = self;
        var buf: [1024]u8 = undefined;
        const response = std.fmt.bufPrint(
            &buf,
            "HTTP/1.1 {d} {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            .{ status, message },
        ) catch return;
        _ = stream.write(response) catch {};
    }

    fn sendStreamFrame(self: *Self, stream: std.net.Stream, stream_type: StreamFrame.StreamType, data: []const u8) !void {
        _ = self;
        // Send stream type byte followed by data
        const header = [_]u8{@intFromEnum(stream_type)};
        _ = stream.write(&header) catch return StreamingError.IoError;
        _ = stream.write(data) catch return StreamingError.IoError;
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

/// Resolve common command names to absolute paths
fn resolveCommand(allocator: std.mem.Allocator, cmd: []const u8) ![]const u8 {
    // Common command mappings
    const mappings = .{
        .{ "sh", "/bin/sh" },
        .{ "ash", "/bin/sh" },
        .{ "bash", "/bin/bash" },
        .{ "cat", "/bin/cat" },
        .{ "ls", "/bin/ls" },
        .{ "echo", "/bin/echo" },
        .{ "grep", "/bin/grep" },
        .{ "sleep", "/bin/sleep" },
        .{ "touch", "/bin/touch" },
        .{ "hostname", "/bin/hostname" },
        .{ "id", "/usr/bin/id" },
        .{ "ps", "/bin/ps" },
        .{ "env", "/usr/bin/env" },
        .{ "pwd", "/bin/pwd" },
        .{ "whoami", "/usr/bin/whoami" },
        .{ "uname", "/bin/uname" },
    };

    // If already absolute, return as-is
    if (cmd.len > 0 and cmd[0] == '/') {
        return allocator.dupe(u8, cmd);
    }

    // Check mappings
    inline for (mappings) |mapping| {
        if (std.mem.eql(u8, cmd, mapping[0])) {
            return allocator.dupe(u8, mapping[1]);
        }
    }

    // Default to /bin/<cmd>
    return std.fmt.allocPrint(allocator, "/bin/{s}", .{cmd});
}

/// Stream frame for the streaming protocol
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
