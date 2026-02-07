const std = @import("std");
const logging = @import("../util/logging.zig");
const uuid = @import("../util/uuid.zig");
const store = @import("../state/store.zig");

pub const ExecError = error{
    ContainerNotFound,
    ContainerNotRunning,
    ExecFailed,
    Timeout,
    OutOfMemory,
    IoError,
};

/// Exec request for running commands in containers
pub const ExecRequest = struct {
    container_id: []const u8,
    cmd: []const []const u8,
    tty: bool = false,
    stdin: bool = false,
    stdout: bool = true,
    stderr: bool = true,
};

/// Exec response with output
pub const ExecResponse = struct {
    exit_code: i32,
    stdout: []const u8,
    stderr: []const u8,

    pub fn deinit(self: *ExecResponse, allocator: std.mem.Allocator) void {
        if (self.stdout.len > 0) allocator.free(self.stdout);
        if (self.stderr.len > 0) allocator.free(self.stderr);
    }
};

/// Streaming exec session
pub const ExecSession = struct {
    id: []const u8,
    container_id: []const u8,
    cmd: []const []const u8,
    tty: bool,
    stdin: bool,
    created_at: i64,
    // For streaming, we'd hold file descriptors here
    process: ?std.process.Child = null,

    pub fn deinit(self: *ExecSession, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.container_id);
        for (self.cmd) |arg| {
            allocator.free(arg);
        }
        allocator.free(self.cmd);
    }
};

/// Executor for running commands in containers
pub const Executor = struct {
    allocator: std.mem.Allocator,
    state_store: *store.Store,
    sessions: std.StringHashMap(ExecSession),
    nsenter_path: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, state_store: *store.Store) !Self {
        // Find nsenter binary
        const nsenter_path = findExecutable(allocator, "nsenter") catch "/usr/bin/nsenter";

        return Self{
            .allocator = allocator,
            .state_store = state_store,
            .sessions = std.StringHashMap(ExecSession).init(allocator),
            .nsenter_path = nsenter_path,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            var session = entry.value_ptr.*;
            session.deinit(self.allocator);
        }
        self.sessions.deinit();
    }

    /// Execute a command synchronously and return the result
    pub fn execSync(
        self: *Self,
        container_id: []const u8,
        cmd: []const []const u8,
        timeout_secs: i64,
    ) ExecError!ExecResponse {
        logging.info("ExecSync in container {s}: {any}", .{ container_id, cmd });

        // Get container info
        const container_info = self.state_store.getContainer(container_id) catch {
            return ExecError.ContainerNotFound;
        };
        defer {
            var c = container_info;
            c.deinit(self.allocator);
        }

        if (container_info.state != .running) {
            return ExecError.ContainerNotRunning;
        }

        // Get the PID of the container's init process
        const pid = container_info.pid orelse return ExecError.ContainerNotRunning;

        // Build nsenter command
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);

        // nsenter with all namespaces
        args.append(self.allocator, self.nsenter_path) catch return ExecError.OutOfMemory;
        args.append(self.allocator, "-t") catch return ExecError.OutOfMemory;

        const pid_str = std.fmt.allocPrint(self.allocator, "{d}", .{pid}) catch return ExecError.OutOfMemory;
        defer self.allocator.free(pid_str);
        args.append(self.allocator, pid_str) catch return ExecError.OutOfMemory;

        // Enter all namespaces
        args.append(self.allocator, "-m") catch return ExecError.OutOfMemory; // mount
        args.append(self.allocator, "-u") catch return ExecError.OutOfMemory; // UTS
        args.append(self.allocator, "-i") catch return ExecError.OutOfMemory; // IPC
        args.append(self.allocator, "-n") catch return ExecError.OutOfMemory; // network
        args.append(self.allocator, "-p") catch return ExecError.OutOfMemory; // PID

        // Add the command to execute
        for (cmd) |arg| {
            args.append(self.allocator, arg) catch return ExecError.OutOfMemory;
        }

        // Execute
        var child = std.process.Child.init(args.items, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.spawn() catch return ExecError.ExecFailed;

        // Set up timeout if specified
        _ = timeout_secs; // TODO: Implement timeout with async

        const stdout = child.stdout.?.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch return ExecError.IoError;
        errdefer self.allocator.free(stdout);

        const stderr = child.stderr.?.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch return ExecError.IoError;
        errdefer self.allocator.free(stderr);

        const term = child.wait() catch return ExecError.ExecFailed;

        const exit_code: i32 = switch (term) {
            .Exited => |code| @intCast(code),
            .Signal => |sig| -@as(i32, @intCast(sig)),
            else => -1,
        };

        return ExecResponse{
            .exit_code = exit_code,
            .stdout = stdout,
            .stderr = stderr,
        };
    }

    /// Create a streaming exec session (returns URL for streaming server)
    pub fn exec(
        self: *Self,
        container_id: []const u8,
        cmd: []const []const u8,
        tty: bool,
        stdin: bool,
    ) ExecError![]const u8 {
        logging.info("Creating exec session for container {s}", .{container_id});

        // Verify container exists and is running
        const container_info = self.state_store.getContainer(container_id) catch {
            return ExecError.ContainerNotFound;
        };
        defer {
            var c = container_info;
            c.deinit(self.allocator);
        }

        if (container_info.state != .running) {
            return ExecError.ContainerNotRunning;
        }

        // Generate session ID
        var id_buf: [36]u8 = undefined;
        uuid.generate(&id_buf);
        const session_id = self.allocator.dupe(u8, &id_buf) catch return ExecError.OutOfMemory;
        errdefer self.allocator.free(session_id);

        // Copy command arguments
        var cmd_copy = self.allocator.alloc([]const u8, cmd.len) catch return ExecError.OutOfMemory;
        errdefer self.allocator.free(cmd_copy);

        for (cmd, 0..) |arg, i| {
            cmd_copy[i] = self.allocator.dupe(u8, arg) catch return ExecError.OutOfMemory;
        }

        const session = ExecSession{
            .id = session_id,
            .container_id = self.allocator.dupe(u8, container_id) catch return ExecError.OutOfMemory,
            .cmd = cmd_copy,
            .tty = tty,
            .stdin = stdin,
            .created_at = std.time.timestamp(),
            .process = null,
        };

        self.sessions.put(session_id, session) catch return ExecError.OutOfMemory;

        // Return the streaming URL
        const url = std.fmt.allocPrint(
            self.allocator,
            "/exec/{s}",
            .{session_id},
        ) catch return ExecError.OutOfMemory;

        return url;
    }

    /// Attach to a running container's main process
    pub fn attach(
        self: *Self,
        container_id: []const u8,
        tty: bool,
        stdin: bool,
    ) ExecError![]const u8 {
        logging.info("Creating attach session for container {s}", .{container_id});

        // For attach, we create an exec session that connects to the container's
        // main process stdin/stdout/stderr
        const cmd = &[_][]const u8{};
        return self.exec(container_id, cmd, tty, stdin);
    }

    /// Get an exec session by ID
    pub fn getSession(self: *Self, session_id: []const u8) ?*ExecSession {
        return self.sessions.getPtr(session_id);
    }

    /// Remove an exec session
    pub fn removeSession(self: *Self, session_id: []const u8) void {
        if (self.sessions.fetchRemove(session_id)) |kv| {
            var session = kv.value;
            session.deinit(self.allocator);
        }
    }
};

fn findExecutable(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const path_env = std.posix.getenv("PATH") orelse "/usr/bin:/bin";
    var paths = std.mem.splitScalar(u8, path_env, ':');

    while (paths.next()) |dir| {
        const full_path = try std.fs.path.join(allocator, &.{ dir, name });
        errdefer allocator.free(full_path);

        std.fs.accessAbsolute(full_path, .{}) catch {
            allocator.free(full_path);
            continue;
        };

        return full_path;
    }

    return error.NotFound;
}
