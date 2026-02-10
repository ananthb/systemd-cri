const std = @import("std");
const logging = @import("../util/logging.zig");
const http2 = @import("http2.zig");
const proto = @import("../cri/proto.zig");
const runtime_service = @import("../cri/runtime_service.zig");
const image_service = @import("../cri/image_service.zig");
const exec = @import("../container/exec.zig");

/// gRPC server for CRI using HTTP/2 and protobuf
pub const GrpcServer = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    runtime_service: *runtime_service.RuntimeService,
    image_service: *image_service.ImageService,
    executor: *exec.Executor,
    streaming_port: u16,
    server: ?std.net.Server = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    active_connections: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        socket_path: []const u8,
        rs: *runtime_service.RuntimeService,
        is: *image_service.ImageService,
        ex: *exec.Executor,
        streaming_port: u16,
    ) !Self {
        return Self{
            .allocator = allocator,
            .socket_path = try allocator.dupe(u8, socket_path),
            .runtime_service = rs,
            .image_service = is,
            .executor = ex,
            .streaming_port = streaming_port,
            .server = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.allocator.free(self.socket_path);
    }

    /// Start the gRPC server
    pub fn start(self: *Self) !void {
        logging.info("Starting gRPC server on {s}", .{self.socket_path});

        // Remove existing socket file
        std.fs.deleteFileAbsolute(self.socket_path) catch {};

        // Create parent directory if needed
        if (std.fs.path.dirname(self.socket_path)) |parent| {
            std.fs.makeDirAbsolute(parent) catch |e| {
                if (e != error.PathAlreadyExists) return e;
            };
        }

        // Bind to Unix socket
        const addr = std.net.Address.initUnix(self.socket_path) catch return error.InvalidAddress;
        self.server = std.net.Address.listen(addr, .{
            .reuse_address = true,
        }) catch return error.BindFailed;

        self.running.store(true, .release);
        logging.info("gRPC server listening on {s}", .{self.socket_path});
    }

    /// Stop the gRPC server
    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
        if (self.server) |*s| {
            s.deinit();
            self.server = null;
        }
        std.fs.deleteFileAbsolute(self.socket_path) catch {};
    }

    /// Run the server main loop
    pub fn run(self: *Self) !void {
        while (self.running.load(.acquire)) {
            self.acceptConnection() catch |err| {
                if (!self.running.load(.acquire)) break;
                logging.err("Accept error: {}", .{err});
                continue;
            };
        }
    }

    /// Accept and spawn a thread to handle the connection
    pub fn acceptConnection(self: *Self) !void {
        if (self.server == null) return error.NotStarted;

        const conn = try self.server.?.accept();

        // Spawn a thread to handle this connection
        const thread = std.Thread.spawn(.{}, handleConnectionThread, .{ self, conn }) catch |err| {
            logging.err("Failed to spawn connection thread: {}", .{err});
            conn.stream.close();
            return;
        };
        thread.detach();
    }

    fn handleConnectionThread(self: *Self, conn: std.net.Server.Connection) void {
        _ = self.active_connections.fetchAdd(1, .monotonic);
        defer _ = self.active_connections.fetchSub(1, .monotonic);
        defer conn.stream.close();

        self.handleConnection(conn) catch |err| {
            logging.err("Error handling connection: {}", .{err});
        };
    }

    fn handleConnection(self: *Self, conn: std.net.Server.Connection) !void {
        logging.debug("New connection accepted", .{});

        var session = try http2.Http2Session.init(self.allocator);
        session.fixUserData(); // Fix the user_data pointer now that session is at stable address
        defer session.deinit();

        var buf: [65536]u8 = undefined;
        var preface_received = false;
        var goaway_sent = false;

        while (!goaway_sent) {
            const n = conn.stream.read(&buf) catch |err| {
                logging.debug("Read error: {}", .{err});
                break;
            };
            if (n == 0) {
                logging.debug("Connection closed by client", .{});
                break;
            }

            const data = buf[0..n];
            logging.debug("Received {d} bytes", .{n});

            // Check for HTTP/2 client preface on first read
            if (!preface_received) {
                logging.debug("Checking for HTTP/2 preface...", .{});
                if (http2.isHttp2Preface(data)) {
                    logging.debug("Valid HTTP/2 preface received", .{});
                    preface_received = true;
                    // Send server preface first
                    session.sendServerPreface() catch |err| {
                        logging.err("Failed to send server preface: {}", .{err});
                        break;
                    };

                    // Send server settings immediately
                    const output = session.getOutput();
                    if (output.len > 0) {
                        conn.stream.writeAll(output) catch |err| {
                            logging.err("Failed to send settings: {}", .{err});
                            break;
                        };
                        session.clearOutput();
                    }
                } else {
                    logging.warn("Invalid HTTP/2 preface, got: {x}", .{data[0..@min(n, 24)]});
                    break;
                }
            }

            // Pass all data to nghttp2 (it handles the preface internally)
            session.processInput(data) catch |err| {
                logging.err("Failed to process input: {}", .{err});
                break;
            };

            // Send any output (e.g., SETTINGS ACK)
            const output = session.getOutput();
            if (output.len > 0) {
                conn.stream.writeAll(output) catch |err| {
                    logging.err("Failed to send output: {}", .{err});
                    break;
                };
                session.clearOutput();
            }

            // Process pending requests
            while (session.nextRequest()) |request| {
                defer {
                    self.allocator.free(request.method);
                    self.allocator.free(request.content_type);
                    self.allocator.free(request.data);
                }

                self.handleGrpcRequest(&session, request) catch |err| {
                    logging.err("Failed to handle request {s}: {}", .{ request.method, err });
                    session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, "Internal error") catch {};
                };

                // Send response output immediately
                const resp_output = session.getOutput();
                if (resp_output.len > 0) {
                    conn.stream.writeAll(resp_output) catch |err| {
                        logging.err("Failed to send response: {}", .{err});
                        goaway_sent = true;
                        break;
                    };
                    session.clearOutput();
                }
            }

            // Check if session wants to terminate
            if (session.wantsClose()) {
                logging.debug("Session wants to close", .{});
                goaway_sent = true;
            }
        }
    }

    fn handleGrpcRequest(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        const method = GrpcMethod.fromPath(request.method) orelse {
            logging.warn("Unknown gRPC method: {s}", .{request.method});
            try session.sendError(request.stream_id, http2.GrpcStatus.UNIMPLEMENTED, "Method not implemented");
            return;
        };

        logging.debug("Handling gRPC method: {s}", .{request.method});

        switch (method) {
            .Version => try self.handleVersion(session, request),
            .Status => try self.handleStatus(session, request),
            .RuntimeConfig => try self.handleRuntimeConfig(session, request),
            .RunPodSandbox => try self.handleRunPodSandbox(session, request),
            .StopPodSandbox => try self.handleStopPodSandbox(session, request),
            .RemovePodSandbox => try self.handleRemovePodSandbox(session, request),
            .PodSandboxStatus => try self.handlePodSandboxStatus(session, request),
            .ListPodSandbox => try self.handleListPodSandbox(session, request),
            .CreateContainer => try self.handleCreateContainer(session, request),
            .StartContainer => try self.handleStartContainer(session, request),
            .StopContainer => try self.handleStopContainer(session, request),
            .RemoveContainer => try self.handleRemoveContainer(session, request),
            .ListContainers => try self.handleListContainers(session, request),
            .ContainerStatus => try self.handleContainerStatus(session, request),
            .ExecSync => try self.handleExecSync(session, request),
            .Exec => try self.handleExec(session, request),
            .Attach => try self.handleAttach(session, request),
            .PortForward => try self.handlePortForward(session, request),
            .ListImages => try self.handleListImages(session, request),
            .ImageStatus => try self.handleImageStatus(session, request),
            .PullImage => try self.handlePullImage(session, request),
            .RemoveImage => try self.handleRemoveImage(session, request),
            .ImageFsInfo => try self.handleImageFsInfo(session, request),
            .ContainerStats => try self.handleContainerStats(session, request),
            .ListContainerStats => try self.handleListContainerStats(session, request),
            else => {
                logging.warn("Unimplemented method: {s}", .{request.method});
                try session.sendError(request.stream_id, http2.GrpcStatus.UNIMPLEMENTED, "Method not implemented");
            },
        }
    }

    // RuntimeService handlers

    fn handleVersion(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        // Unpack request (empty for Version)
        if (request.data.len > 0) {
            _ = proto.unpack(proto.VersionRequest, request.data);
        }

        // Get version from service
        const version_info = self.runtime_service.version();

        // Create response
        const resp = try proto.initVersionResponse(
            self.allocator,
            version_info.version,
            version_info.runtime_name,
            version_info.runtime_version,
            version_info.runtime_api_version,
        );
        defer self.allocator.destroy(resp);
        defer self.allocator.free(std.mem.span(resp.version));
        defer self.allocator.free(std.mem.span(resp.runtime_name));
        defer self.allocator.free(std.mem.span(resp.runtime_version));
        defer self.allocator.free(std.mem.span(resp.runtime_api_version));

        // Pack and send
        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    fn handleStatus(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        // Create response with runtime conditions
        const resp = try proto.initEmptyResponse(proto.StatusResponse, self.allocator);
        defer self.allocator.destroy(resp);

        // Create runtime status
        var status = try self.allocator.create(proto.RuntimeStatus);
        defer self.allocator.destroy(status);
        status.* = std.mem.zeroes(proto.RuntimeStatus);
        status.base.descriptor = &proto.c.runtime__v1__runtime_status__descriptor;

        // Create conditions array (as C-compatible pointer array)
        const conditions_slice = try self.allocator.alloc([*c]proto.RuntimeCondition, 2);
        defer self.allocator.free(conditions_slice);

        // RuntimeReady condition
        var runtime_ready = try self.allocator.create(proto.RuntimeCondition);
        defer self.allocator.destroy(runtime_ready);
        runtime_ready.* = std.mem.zeroes(proto.RuntimeCondition);
        runtime_ready.base.descriptor = &proto.c.runtime__v1__runtime_condition__descriptor;
        runtime_ready.type = try self.allocator.dupeZ(u8, "RuntimeReady");
        defer self.allocator.free(std.mem.span(runtime_ready.type));
        runtime_ready.status = 1;
        runtime_ready.reason = try self.allocator.dupeZ(u8, "");
        defer self.allocator.free(std.mem.span(runtime_ready.reason));
        runtime_ready.message = try self.allocator.dupeZ(u8, "");
        defer self.allocator.free(std.mem.span(runtime_ready.message));

        // NetworkReady condition
        var network_ready = try self.allocator.create(proto.RuntimeCondition);
        defer self.allocator.destroy(network_ready);
        network_ready.* = std.mem.zeroes(proto.RuntimeCondition);
        network_ready.base.descriptor = &proto.c.runtime__v1__runtime_condition__descriptor;
        network_ready.type = try self.allocator.dupeZ(u8, "NetworkReady");
        defer self.allocator.free(std.mem.span(network_ready.type));
        network_ready.status = 1;
        network_ready.reason = try self.allocator.dupeZ(u8, "");
        defer self.allocator.free(std.mem.span(network_ready.reason));
        network_ready.message = try self.allocator.dupeZ(u8, "");
        defer self.allocator.free(std.mem.span(network_ready.message));

        conditions_slice[0] = runtime_ready;
        conditions_slice[1] = network_ready;
        status.conditions = @ptrCast(conditions_slice.ptr);
        status.n_conditions = 2;

        resp.status = status;

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    fn handleRunPodSandbox(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        const req = proto.unpack(proto.RunPodSandboxRequest, request.data) orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Invalid request");
            return;
        };
        defer proto.free(req);

        // Extract pod config
        const config_ptr = req.config orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Missing config");
            return;
        };

        const metadata_ptr = config_ptr.*.metadata orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Missing metadata");
            return;
        };

        // Create pod using our service
        const types = @import("../cri/types.zig");
        const pod_config = types.PodSandboxConfig{
            .metadata = .{
                .name = proto.getString(metadata_ptr.*.name),
                .uid = proto.getString(metadata_ptr.*.uid),
                .namespace = proto.getString(metadata_ptr.*.namespace_),
                .attempt = metadata_ptr.*.attempt,
            },
            .hostname = null,
            .log_directory = null,
            .dns_config = null,
            .port_mappings = null,
            .labels = null,
            .annotations = null,
            .linux = null,
            .windows = null,
        };

        const pod_id = self.runtime_service.runPodSandbox(&pod_config) catch |err| {
            logging.err("Failed to run pod sandbox: {}", .{err});
            try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, "Failed to create pod");
            return;
        };
        defer self.allocator.free(pod_id);

        // Create response
        const resp = try proto.initRunPodSandboxResponse(self.allocator, pod_id);
        defer self.allocator.destroy(resp);
        defer self.allocator.free(std.mem.span(resp.pod_sandbox_id));

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    fn handleStopPodSandbox(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        const req = proto.unpack(proto.StopPodSandboxRequest, request.data) orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Invalid request");
            return;
        };
        defer proto.free(req);

        const pod_id = proto.getString(req.pod_sandbox_id);
        self.runtime_service.stopPodSandbox(pod_id) catch |err| {
            // Idempotent: NotFound means pod is already gone, that's fine
            if (err != error.NotFound) {
                logging.err("Failed to stop pod sandbox: {}", .{err});
                try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, "Failed to stop pod");
                return;
            }
            logging.debug("StopPodSandbox: pod {s} not found (already stopped/removed)", .{pod_id});
        };

        const resp = try proto.initEmptyResponse(proto.StopPodSandboxResponse, self.allocator);
        defer self.allocator.destroy(resp);

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    fn handleRemovePodSandbox(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        const req = proto.unpack(proto.RemovePodSandboxRequest, request.data) orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Invalid request");
            return;
        };
        defer proto.free(req);

        const pod_id = proto.getString(req.pod_sandbox_id);
        self.runtime_service.removePodSandbox(pod_id) catch |err| {
            // Idempotent: NotFound means pod is already gone, that's fine
            if (err != error.NotFound) {
                logging.err("Failed to remove pod sandbox: {}", .{err});
                try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, "Failed to remove pod");
                return;
            }
            logging.debug("RemovePodSandbox: pod {s} not found (already removed)", .{pod_id});
        };

        const resp = try proto.initEmptyResponse(proto.RemovePodSandboxResponse, self.allocator);
        defer self.allocator.destroy(resp);

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    fn handlePodSandboxStatus(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        const req = proto.unpack(proto.PodSandboxStatusRequest, request.data) orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Invalid request");
            return;
        };
        defer proto.free(req);

        const pod_id = proto.getString(req.pod_sandbox_id);
        const status_resp = self.runtime_service.podSandboxStatus(pod_id) catch |err| {
            logging.err("Failed to get pod status: {}", .{err});
            try session.sendError(request.stream_id, http2.GrpcStatus.NOT_FOUND, "Pod not found");
            return;
        };
        const status_info = status_resp.status;
        defer {
            self.allocator.free(status_info.id);
            self.allocator.free(status_info.metadata.name);
            self.allocator.free(status_info.metadata.uid);
            self.allocator.free(status_info.metadata.namespace);
        }

        // Create response
        const resp = try self.allocator.create(proto.PodSandboxStatusResponse);
        defer self.allocator.destroy(resp);
        resp.* = std.mem.zeroes(proto.PodSandboxStatusResponse);
        resp.base.descriptor = &proto.c.runtime__v1__pod_sandbox_status_response__descriptor;

        // Create status
        var status = try self.allocator.create(proto.PodSandboxStatus);
        defer self.allocator.destroy(status);
        status.* = std.mem.zeroes(proto.PodSandboxStatus);
        status.base.descriptor = &proto.c.runtime__v1__pod_sandbox_status__descriptor;
        status.id = try self.allocator.dupeZ(u8, status_info.id);
        defer self.allocator.free(std.mem.span(status.id));
        status.state = if (status_info.state == .sandbox_ready)
            proto.c.RUNTIME__V1__POD_SANDBOX_STATE__SANDBOX_READY
        else
            proto.c.RUNTIME__V1__POD_SANDBOX_STATE__SANDBOX_NOTREADY;
        status.created_at = status_info.created_at;

        // Create metadata with actual pod data
        var metadata = try self.allocator.create(proto.PodSandboxMetadata);
        defer self.allocator.destroy(metadata);
        metadata.* = std.mem.zeroes(proto.PodSandboxMetadata);
        metadata.base.descriptor = &proto.c.runtime__v1__pod_sandbox_metadata__descriptor;
        metadata.name = try self.allocator.dupeZ(u8, status_info.metadata.name);
        defer self.allocator.free(std.mem.span(metadata.name));
        metadata.uid = try self.allocator.dupeZ(u8, status_info.metadata.uid);
        defer self.allocator.free(std.mem.span(metadata.uid));
        metadata.namespace_ = try self.allocator.dupeZ(u8, status_info.metadata.namespace);
        defer self.allocator.free(std.mem.span(metadata.namespace_));

        status.metadata = metadata;

        // Create network status (required for CRI compliance)
        var network = try self.allocator.create(proto.PodSandboxNetworkStatus);
        defer self.allocator.destroy(network);
        network.* = std.mem.zeroes(proto.PodSandboxNetworkStatus);
        network.base.descriptor = &proto.c.runtime__v1__pod_sandbox_network_status__descriptor;
        // Use empty string for host network mode, or provide actual IP from CNI
        network.ip = try self.allocator.dupeZ(u8, "");
        defer self.allocator.free(std.mem.span(network.ip));
        network.n_additional_ips = 0;
        network.additional_ips = null;
        status.network = network;

        resp.status = status;

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    fn handleListPodSandbox(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        var pods = self.runtime_service.listPodSandbox(null) catch |err| {
            logging.err("Failed to list pods: {}", .{err});
            try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, "Failed to list pods");
            return;
        };
        defer {
            for (pods.items) |p| {
                self.allocator.free(p.id);
                self.allocator.free(p.metadata.name);
                self.allocator.free(p.metadata.uid);
                self.allocator.free(p.metadata.namespace);
            }
            pods.deinit(self.allocator);
        }

        // Create response
        const resp = try self.allocator.create(proto.ListPodSandboxResponse);
        defer self.allocator.destroy(resp);
        resp.* = std.mem.zeroes(proto.ListPodSandboxResponse);
        resp.base.descriptor = &proto.c.runtime__v1__list_pod_sandbox_response__descriptor;

        // Create pod sandbox array
        var items: ?[]*proto.PodSandbox = null;
        if (pods.items.len > 0) {
            items = try self.allocator.alloc(*proto.PodSandbox, pods.items.len);

            for (pods.items, 0..) |p, i| {
                var pod = try self.allocator.create(proto.PodSandbox);
                pod.* = std.mem.zeroes(proto.PodSandbox);
                pod.base.descriptor = &proto.c.runtime__v1__pod_sandbox__descriptor;
                pod.id = try self.allocator.dupeZ(u8, p.id);
                pod.state = if (p.state == .sandbox_ready)
                    proto.c.RUNTIME__V1__POD_SANDBOX_STATE__SANDBOX_READY
                else
                    proto.c.RUNTIME__V1__POD_SANDBOX_STATE__SANDBOX_NOTREADY;
                pod.created_at = p.created_at;

                var metadata = try self.allocator.create(proto.PodSandboxMetadata);
                metadata.* = std.mem.zeroes(proto.PodSandboxMetadata);
                metadata.base.descriptor = &proto.c.runtime__v1__pod_sandbox_metadata__descriptor;
                metadata.name = try self.allocator.dupeZ(u8, p.metadata.name);
                metadata.uid = try self.allocator.dupeZ(u8, p.metadata.uid);
                metadata.namespace_ = try self.allocator.dupeZ(u8, p.metadata.namespace);
                pod.metadata = metadata;

                items.?[i] = pod;
            }

            resp.items = @ptrCast(items.?.ptr);
            resp.n_items = pods.items.len;
        }

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        // Free pod items
        if (items) |pod_items| {
            for (pod_items) |pod| {
                if (pod.metadata) |m| {
                    self.allocator.free(std.mem.span(m.*.name));
                    self.allocator.free(std.mem.span(m.*.uid));
                    self.allocator.free(std.mem.span(m.*.namespace_));
                    self.allocator.destroy(@as(*proto.PodSandboxMetadata, @ptrCast(m)));
                }
                self.allocator.free(std.mem.span(pod.id));
                self.allocator.destroy(pod);
            }
            self.allocator.free(pod_items);
        }

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    fn handleCreateContainer(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        const req = proto.unpack(proto.CreateContainerRequest, request.data) orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Invalid request");
            return;
        };
        defer proto.free(req);

        const pod_sandbox_id = proto.getString(req.pod_sandbox_id);
        const config = req.config orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Missing container config");
            return;
        };

        const metadata = config.*.metadata orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Missing container metadata");
            return;
        };

        const image = config.*.image orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Missing image");
            return;
        };

        const cri_types = @import("../cri/types.zig");

        // Extract command and args
        var command: []const []const u8 = &.{};
        if (config.*.n_command > 0 and config.*.command != null) {
            var cmd_list = self.allocator.alloc([]const u8, config.*.n_command) catch {
                try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, "Out of memory");
                return;
            };
            for (0..config.*.n_command) |i| {
                cmd_list[i] = proto.getString(config.*.command[i]);
            }
            command = cmd_list;
        }

        var args: []const []const u8 = &.{};
        if (config.*.n_args > 0 and config.*.args != null) {
            var args_list = self.allocator.alloc([]const u8, config.*.n_args) catch {
                try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, "Out of memory");
                return;
            };
            for (0..config.*.n_args) |i| {
                args_list[i] = proto.getString(config.*.args[i]);
            }
            args = args_list;
        }

        // Extract mounts
        var mounts: []const cri_types.Mount = &.{};
        if (config.*.n_mounts > 0 and config.*.mounts != null) {
            var mount_list = self.allocator.alloc(cri_types.Mount, config.*.n_mounts) catch {
                try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, "Out of memory");
                return;
            };
            for (0..config.*.n_mounts) |i| {
                const m = config.*.mounts[i];
                mount_list[i] = .{
                    .container_path = proto.getString(m.*.container_path),
                    .host_path = proto.getString(m.*.host_path),
                    .readonly = m.*.readonly != 0,
                    .propagation = switch (m.*.propagation) {
                        1 => .propagation_host_to_container,
                        2 => .propagation_bidirectional,
                        else => .propagation_private,
                    },
                };
            }
            mounts = mount_list;
        }

        // Extract linux security context
        var linux_config: ?cri_types.LinuxContainerConfig = null;
        if (config.*.linux) |linux| {
            if (linux.*.security_context) |sec_ctx| {
                linux_config = .{
                    .security_context = .{
                        .privileged = sec_ctx.*.privileged != 0,
                        .run_as_user = if (sec_ctx.*.run_as_user) |u| .{ .value = u.*.value } else null,
                        .run_as_group = if (sec_ctx.*.run_as_group) |g| .{ .value = g.*.value } else null,
                        .readonly_rootfs = sec_ctx.*.readonly_rootfs != 0,
                        .no_new_privs = sec_ctx.*.no_new_privs != 0,
                    },
                };
            }
        }

        // Create container config for our service
        const container_config = cri_types.ContainerConfig{
            .metadata = .{
                .name = proto.getString(metadata.*.name),
                .attempt = metadata.*.attempt,
            },
            .image = .{ .image = proto.getString(image.*.image) },
            .command = command,
            .args = args,
            .mounts = mounts,
            .working_dir = if (config.*.working_dir) |wd| proto.getString(wd) else null,
            .stdin = config.*.stdin != 0,
            .stdin_once = config.*.stdin_once != 0,
            .tty = config.*.tty != 0,
            .linux = linux_config,
        };

        // Get sandbox config (simplified)
        const sandbox_config = @import("../cri/types.zig").PodSandboxConfig{
            .metadata = .{
                .name = "",
                .uid = "",
                .namespace = "default",
                .attempt = 0,
            },
            .hostname = null,
            .log_directory = null,
            .dns_config = null,
            .port_mappings = null,
            .labels = null,
            .annotations = null,
            .linux = null,
            .windows = null,
        };

        const container_id = self.runtime_service.createContainer(pod_sandbox_id, &container_config, &sandbox_config) catch |err| {
            logging.err("Failed to create container: {}", .{err});
            try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, "Failed to create container");
            return;
        };
        defer self.allocator.free(container_id);

        // Create response
        const resp = try self.allocator.create(proto.CreateContainerResponse);
        defer self.allocator.destroy(resp);
        resp.* = std.mem.zeroes(proto.CreateContainerResponse);
        resp.base.descriptor = &proto.c.runtime__v1__create_container_response__descriptor;
        resp.container_id = try self.allocator.dupeZ(u8, container_id);
        defer self.allocator.free(std.mem.span(resp.container_id));

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    fn handleStartContainer(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        const req = proto.unpack(proto.StartContainerRequest, request.data) orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Invalid request");
            return;
        };
        defer proto.free(req);

        const container_id = proto.getString(req.container_id);
        self.runtime_service.startContainer(container_id) catch |err| {
            logging.err("Failed to start container: {}", .{err});
            try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, "Failed to start container");
            return;
        };

        const resp = try proto.initEmptyResponse(proto.StartContainerResponse, self.allocator);
        defer self.allocator.destroy(resp);

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    fn handleStopContainer(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        const req = proto.unpack(proto.StopContainerRequest, request.data) orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Invalid request");
            return;
        };
        defer proto.free(req);

        const container_id = proto.getString(req.container_id);
        self.runtime_service.stopContainer(container_id, req.timeout) catch |err| {
            // Idempotent: NotFound means container is already gone, that's fine
            if (err != error.NotFound) {
                logging.err("Failed to stop container: {}", .{err});
                try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, "Failed to stop container");
                return;
            }
            logging.debug("StopContainer: container {s} not found (already stopped/removed)", .{container_id});
        };

        const resp = try proto.initEmptyResponse(proto.StopContainerResponse, self.allocator);
        defer self.allocator.destroy(resp);

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    fn handleRemoveContainer(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        const req = proto.unpack(proto.RemoveContainerRequest, request.data) orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Invalid request");
            return;
        };
        defer proto.free(req);

        const container_id = proto.getString(req.container_id);
        self.runtime_service.removeContainer(container_id) catch |err| {
            // Idempotent: NotFound means container is already gone, that's fine
            if (err != error.NotFound) {
                logging.err("Failed to remove container: {}", .{err});
                try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, "Failed to remove container");
                return;
            }
            logging.debug("RemoveContainer: container {s} not found (already removed)", .{container_id});
        };

        const resp = try proto.initEmptyResponse(proto.RemoveContainerResponse, self.allocator);
        defer self.allocator.destroy(resp);

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    fn handleListContainers(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        var containers = self.runtime_service.listContainers(null) catch |err| {
            logging.err("Failed to list containers: {}", .{err});
            try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, "Failed to list containers");
            return;
        };
        defer {
            for (containers.items) |c| {
                self.allocator.free(c.id);
                self.allocator.free(c.pod_sandbox_id);
                self.allocator.free(c.metadata.name);
                self.allocator.free(c.image.image);
                self.allocator.free(c.image_ref);
            }
            containers.deinit(self.allocator);
        }

        // Create response
        const resp = try self.allocator.create(proto.ListContainersResponse);
        defer self.allocator.destroy(resp);
        resp.* = std.mem.zeroes(proto.ListContainersResponse);
        resp.base.descriptor = &proto.c.runtime__v1__list_containers_response__descriptor;

        // Populate containers list
        var items: ?[]*proto.Container = null;
        if (containers.items.len > 0) {
            items = try self.allocator.alloc(*proto.Container, containers.items.len);

            for (containers.items, 0..) |c, i| {
                var container = try self.allocator.create(proto.Container);
                container.* = std.mem.zeroes(proto.Container);
                container.base.descriptor = &proto.c.runtime__v1__container__descriptor;
                container.id = (try self.allocator.dupeZ(u8, c.id)).ptr;
                container.pod_sandbox_id = (try self.allocator.dupeZ(u8, c.pod_sandbox_id)).ptr;
                container.state = switch (c.state) {
                    .container_created => proto.c.RUNTIME__V1__CONTAINER_STATE__CONTAINER_CREATED,
                    .container_running => proto.c.RUNTIME__V1__CONTAINER_STATE__CONTAINER_RUNNING,
                    .container_exited => proto.c.RUNTIME__V1__CONTAINER_STATE__CONTAINER_EXITED,
                    .container_unknown => proto.c.RUNTIME__V1__CONTAINER_STATE__CONTAINER_UNKNOWN,
                };
                container.created_at = c.created_at;
                container.image_ref = (try self.allocator.dupeZ(u8, c.image_ref)).ptr;

                // Create metadata
                var metadata = try self.allocator.create(proto.ContainerMetadata);
                metadata.* = std.mem.zeroes(proto.ContainerMetadata);
                metadata.base.descriptor = &proto.c.runtime__v1__container_metadata__descriptor;
                metadata.name = (try self.allocator.dupeZ(u8, c.metadata.name)).ptr;
                metadata.attempt = c.metadata.attempt;
                container.metadata = metadata;

                // Create image spec
                var image = try self.allocator.create(proto.ImageSpec);
                image.* = std.mem.zeroes(proto.ImageSpec);
                image.base.descriptor = &proto.c.runtime__v1__image_spec__descriptor;
                image.image = (try self.allocator.dupeZ(u8, c.image.image)).ptr;
                container.image = image;

                items.?[i] = container;
            }

            resp.containers = @ptrCast(items.?.ptr);
            resp.n_containers = containers.items.len;
        }

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        // Free container items
        if (items) |container_items| {
            for (container_items) |container| {
                if (container.metadata) |m| {
                    self.allocator.free(std.mem.span(m.*.name));
                    self.allocator.destroy(@as(*proto.ContainerMetadata, @ptrCast(m)));
                }
                if (container.image) |img| {
                    self.allocator.free(std.mem.span(img.*.image));
                    self.allocator.destroy(@as(*proto.ImageSpec, @ptrCast(img)));
                }
                self.allocator.free(std.mem.span(container.id));
                self.allocator.free(std.mem.span(container.pod_sandbox_id));
                self.allocator.free(std.mem.span(container.image_ref));
                self.allocator.destroy(container);
            }
            self.allocator.free(container_items);
        }

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    fn handleContainerStatus(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        const req = proto.unpack(proto.ContainerStatusRequest, request.data) orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Invalid request");
            return;
        };
        defer proto.free(req);

        const container_id = proto.getString(req.container_id);

        // Get container status from runtime service
        const status_info = self.runtime_service.containerStatus(container_id) catch |err| {
            logging.err("Failed to get container status: {}", .{err});
            try session.sendError(request.stream_id, http2.GrpcStatus.NOT_FOUND, "Container not found");
            return;
        };
        defer {
            self.allocator.free(status_info.status.id);
            self.allocator.free(status_info.status.metadata.name);
            self.allocator.free(status_info.status.image.image);
            self.allocator.free(status_info.status.image_ref);
            if (status_info.status.log_path) |lp| self.allocator.free(lp);
        }

        // Create response
        const resp = try self.allocator.create(proto.ContainerStatusResponse);
        defer self.allocator.destroy(resp);
        resp.* = std.mem.zeroes(proto.ContainerStatusResponse);
        resp.base.descriptor = &proto.c.runtime__v1__container_status_response__descriptor;

        // Create status
        var status = try self.allocator.create(proto.ContainerStatusProto);
        defer self.allocator.destroy(status);
        status.* = std.mem.zeroes(proto.ContainerStatusProto);
        status.base.descriptor = &proto.c.runtime__v1__container_status__descriptor;

        status.id = try self.allocator.dupeZ(u8, status_info.status.id);
        defer self.allocator.free(std.mem.span(status.id));

        status.state = switch (status_info.status.state) {
            .container_created => proto.c.RUNTIME__V1__CONTAINER_STATE__CONTAINER_CREATED,
            .container_running => proto.c.RUNTIME__V1__CONTAINER_STATE__CONTAINER_RUNNING,
            .container_exited => proto.c.RUNTIME__V1__CONTAINER_STATE__CONTAINER_EXITED,
            .container_unknown => proto.c.RUNTIME__V1__CONTAINER_STATE__CONTAINER_UNKNOWN,
        };

        status.created_at = status_info.status.created_at;
        status.started_at = status_info.status.started_at;
        status.finished_at = status_info.status.finished_at;
        status.exit_code = status_info.status.exit_code;

        status.image_ref = try self.allocator.dupeZ(u8, status_info.status.image_ref);
        defer self.allocator.free(std.mem.span(status.image_ref));

        // Create metadata
        var metadata = try self.allocator.create(proto.ContainerMetadata);
        defer self.allocator.destroy(metadata);
        metadata.* = std.mem.zeroes(proto.ContainerMetadata);
        metadata.base.descriptor = &proto.c.runtime__v1__container_metadata__descriptor;
        metadata.name = try self.allocator.dupeZ(u8, status_info.status.metadata.name);
        defer self.allocator.free(std.mem.span(metadata.name));
        metadata.attempt = status_info.status.metadata.attempt;
        status.metadata = metadata;

        // Create image spec
        var image = try self.allocator.create(proto.ImageSpec);
        defer self.allocator.destroy(image);
        image.* = std.mem.zeroes(proto.ImageSpec);
        image.base.descriptor = &proto.c.runtime__v1__image_spec__descriptor;
        image.image = try self.allocator.dupeZ(u8, status_info.status.image.image);
        defer self.allocator.free(std.mem.span(image.image));
        status.image = image;

        // Set log path if available
        if (status_info.status.log_path) |lp| {
            status.log_path = try self.allocator.dupeZ(u8, lp);
        }
        defer if (status.log_path) |lp| self.allocator.free(std.mem.span(lp));

        // Set mounts if available
        var mount_items: ?[]*proto.Mount = null;
        if (status_info.status.mounts) |mounts| {
            if (mounts.len > 0) {
                mount_items = try self.allocator.alloc(*proto.Mount, mounts.len);
                for (mounts, 0..) |m, i| {
                    const mount_proto = try self.allocator.create(proto.Mount);
                    mount_proto.* = std.mem.zeroes(proto.Mount);
                    mount_proto.base.descriptor = &proto.c.runtime__v1__mount__descriptor;
                    mount_proto.container_path = try self.allocator.dupeZ(u8, m.container_path);
                    mount_proto.host_path = try self.allocator.dupeZ(u8, m.host_path);
                    mount_proto.readonly = if (m.readonly) 1 else 0;
                    mount_proto.propagation = switch (m.propagation) {
                        .propagation_private => proto.c.RUNTIME__V1__MOUNT_PROPAGATION__PROPAGATION_PRIVATE,
                        .propagation_host_to_container => proto.c.RUNTIME__V1__MOUNT_PROPAGATION__PROPAGATION_HOST_TO_CONTAINER,
                        .propagation_bidirectional => proto.c.RUNTIME__V1__MOUNT_PROPAGATION__PROPAGATION_BIDIRECTIONAL,
                    };
                    mount_items.?[i] = mount_proto;
                }
                status.mounts = @ptrCast(mount_items.?.ptr);
                status.n_mounts = mounts.len;
            }
        }
        defer if (mount_items) |items| {
            for (items) |mount_proto| {
                self.allocator.free(std.mem.span(mount_proto.container_path));
                self.allocator.free(std.mem.span(mount_proto.host_path));
                self.allocator.destroy(mount_proto);
            }
            self.allocator.free(items);
        };

        resp.status = status;

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    fn handleExecSync(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        const req = proto.unpack(proto.ExecSyncRequest, request.data) orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Invalid request");
            return;
        };
        defer proto.free(req);

        const container_id = proto.getString(req.container_id);
        if (container_id.len == 0) {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Missing container_id");
            return;
        }

        // Build command from request
        var cmd_list: std.ArrayList([]const u8) = .empty;
        defer cmd_list.deinit(self.allocator);

        if (req.n_cmd > 0) {
            for (req.cmd[0..req.n_cmd]) |c| {
                if (c) |ptr| {
                    try cmd_list.append(self.allocator, std.mem.span(ptr));
                }
            }
        }

        if (cmd_list.items.len == 0) {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Missing command");
            return;
        }

        logging.info("ExecSync: container={s} cmd={s}", .{ container_id, cmd_list.items[0] });

        // Execute the command in the container using nsenter
        const timeout: i64 = if (req.timeout > 0) req.timeout else 60;
        var exec_result = self.executor.execSync(container_id, cmd_list.items, timeout) catch |err| {
            logging.err("ExecSync failed: {}", .{err});
            const err_msg = switch (err) {
                exec.ExecError.ContainerNotFound => "Container not found",
                exec.ExecError.ContainerNotRunning => "Container not running",
                exec.ExecError.ExecFailed => "Exec failed",
                exec.ExecError.Timeout => "Exec timed out",
                else => "Internal error",
            };
            try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, err_msg);
            return;
        };
        defer exec_result.deinit(self.allocator);

        // Create response with actual output
        const resp = try self.allocator.create(proto.ExecSyncResponse);
        defer self.allocator.destroy(resp);
        resp.* = std.mem.zeroes(proto.ExecSyncResponse);
        resp.base.descriptor = &proto.c.runtime__v1__exec_sync_response__descriptor;

        resp.exit_code = exec_result.exit_code;

        // Set stdout if available
        if (exec_result.stdout.len > 0) {
            resp.stdout.data = @constCast(exec_result.stdout.ptr);
            resp.stdout.len = exec_result.stdout.len;
        }

        // Set stderr if available
        if (exec_result.stderr.len > 0) {
            resp.stderr.data = @constCast(exec_result.stderr.ptr);
            resp.stderr.len = exec_result.stderr.len;
        }

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    fn handleExec(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        const req = proto.unpack(proto.ExecRequest, request.data) orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Invalid request");
            return;
        };
        defer proto.free(req);

        const container_id = proto.getString(req.container_id);
        if (container_id.len == 0) {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Missing container_id");
            return;
        }

        // Build command from request
        var cmd_list: std.ArrayList([]const u8) = .empty;
        defer cmd_list.deinit(self.allocator);

        if (req.n_cmd > 0) {
            for (req.cmd[0..req.n_cmd]) |c| {
                if (c) |ptr| {
                    try cmd_list.append(self.allocator, std.mem.span(ptr));
                }
            }
        }

        if (cmd_list.items.len == 0) {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Missing command");
            return;
        }

        logging.info("Exec: container={s} cmd={s} tty={}", .{ container_id, cmd_list.items[0], req.tty != 0 });

        // Create exec session and get URL
        const url_path = self.executor.exec(
            container_id,
            cmd_list.items,
            req.tty != 0,
            req.stdin != 0,
        ) catch |err| {
            logging.err("Exec failed: {}", .{err});
            const err_msg = switch (err) {
                exec.ExecError.ContainerNotFound => "Container not found",
                exec.ExecError.ContainerNotRunning => "Container not running",
                else => "Internal error",
            };
            try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, err_msg);
            return;
        };
        defer self.allocator.free(url_path);

        // Build full URL (streaming server base URL + path)
        const url = std.fmt.allocPrint(
            self.allocator,
            "http://127.0.0.1:{d}{s}",
            .{ self.streaming_port, url_path },
        ) catch {
            try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, "Out of memory");
            return;
        };
        defer self.allocator.free(url);

        // Create response
        const resp = try self.allocator.create(proto.ExecResponse);
        defer self.allocator.destroy(resp);
        resp.* = std.mem.zeroes(proto.ExecResponse);
        resp.base.descriptor = &proto.c.runtime__v1__exec_response__descriptor;
        resp.url = try self.allocator.dupeZ(u8, url);
        defer self.allocator.free(std.mem.span(resp.url));

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    fn handleAttach(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        const req = proto.unpack(proto.AttachRequest, request.data) orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Invalid request");
            return;
        };
        defer proto.free(req);

        const container_id = proto.getString(req.container_id);
        if (container_id.len == 0) {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Missing container_id");
            return;
        }

        logging.info("Attach: container={s} tty={}", .{ container_id, req.tty != 0 });

        // Create attach session and get URL
        const url_path = self.executor.attach(
            container_id,
            req.tty != 0,
            req.stdin != 0,
        ) catch |err| {
            logging.err("Attach failed: {}", .{err});
            const err_msg = switch (err) {
                exec.ExecError.ContainerNotFound => "Container not found",
                exec.ExecError.ContainerNotRunning => "Container not running",
                else => "Internal error",
            };
            try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, err_msg);
            return;
        };
        defer self.allocator.free(url_path);

        // Build full URL
        const url = std.fmt.allocPrint(
            self.allocator,
            "http://127.0.0.1:{d}{s}",
            .{ self.streaming_port, url_path },
        ) catch {
            try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, "Out of memory");
            return;
        };
        defer self.allocator.free(url);

        // Create response
        const resp = try self.allocator.create(proto.AttachResponse);
        defer self.allocator.destroy(resp);
        resp.* = std.mem.zeroes(proto.AttachResponse);
        resp.base.descriptor = &proto.c.runtime__v1__attach_response__descriptor;
        resp.url = try self.allocator.dupeZ(u8, url);
        defer self.allocator.free(std.mem.span(resp.url));

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    fn handlePortForward(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        const req = proto.unpack(proto.PortForwardRequest, request.data) orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Invalid request");
            return;
        };
        defer proto.free(req);

        const pod_sandbox_id = proto.getString(req.pod_sandbox_id);
        if (pod_sandbox_id.len == 0) {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Missing pod_sandbox_id");
            return;
        }

        // Extract ports from request
        var ports: []i32 = &.{};
        if (req.n_port > 0 and req.port != null) {
            ports = req.port[0..req.n_port];
        }

        logging.info("PortForward: pod={s} ports={any}", .{ pod_sandbox_id, ports });

        // Create port forward session and get URL
        const url_path = self.executor.portForward(
            pod_sandbox_id,
            ports,
        ) catch |err| {
            logging.err("PortForward failed: {}", .{err});
            const err_msg = switch (err) {
                exec.ExecError.ContainerNotFound => "Pod not found",
                exec.ExecError.ContainerNotRunning => "Pod not running",
                else => "Internal error",
            };
            try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, err_msg);
            return;
        };
        defer self.allocator.free(url_path);

        // Build full URL
        const url = std.fmt.allocPrint(
            self.allocator,
            "http://127.0.0.1:{d}{s}",
            .{ self.streaming_port, url_path },
        ) catch {
            try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, "Out of memory");
            return;
        };
        defer self.allocator.free(url);

        // Create response
        const resp = try self.allocator.create(proto.PortForwardResponse);
        defer self.allocator.destroy(resp);
        resp.* = std.mem.zeroes(proto.PortForwardResponse);
        resp.base.descriptor = &proto.c.runtime__v1__port_forward_response__descriptor;
        resp.url = try self.allocator.dupeZ(u8, url);
        defer self.allocator.free(std.mem.span(resp.url));

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    // ImageService handlers

    fn handleListImages(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        var images = self.image_service.listImages(null) catch |err| {
            logging.err("Failed to list images: {}", .{err});
            try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, "Failed to list images");
            return;
        };
        defer {
            for (images.items) |*img| {
                self.allocator.free(img.id);
                for (img.repo_tags) |tag| self.allocator.free(tag);
                for (img.repo_digests) |digest| self.allocator.free(digest);
            }
            images.deinit(self.allocator);
        }

        // Create response
        const resp = try self.allocator.create(proto.ListImagesResponse);
        defer self.allocator.destroy(resp);
        resp.* = std.mem.zeroes(proto.ListImagesResponse);
        resp.base.descriptor = &proto.c.runtime__v1__list_images_response__descriptor;

        // Populate images list
        if (images.items.len > 0) {
            const proto_images = try self.allocator.alloc([*c]proto.Image, images.items.len);
            defer self.allocator.free(proto_images);

            for (images.items, 0..) |img, i| {
                const proto_img = try self.allocator.create(proto.Image);
                proto_img.* = std.mem.zeroes(proto.Image);
                proto_img.base.descriptor = &proto.c.runtime__v1__image__descriptor;
                proto_img.id = try self.allocator.dupeZ(u8, img.id);
                proto_img.size = img.size;

                // Add repo tags
                if (img.repo_tags.len > 0) {
                    const tags = try self.allocator.alloc([*c]u8, img.repo_tags.len);
                    for (img.repo_tags, 0..) |tag, j| {
                        tags[j] = try self.allocator.dupeZ(u8, tag);
                    }
                    proto_img.repo_tags = tags.ptr;
                    proto_img.n_repo_tags = img.repo_tags.len;
                }

                // Add repo digests
                if (img.repo_digests.len > 0) {
                    const digests = try self.allocator.alloc([*c]u8, img.repo_digests.len);
                    for (img.repo_digests, 0..) |digest, j| {
                        digests[j] = try self.allocator.dupeZ(u8, digest);
                    }
                    proto_img.repo_digests = digests.ptr;
                    proto_img.n_repo_digests = img.repo_digests.len;
                }

                proto_images[i] = proto_img;
            }

            resp.images = proto_images.ptr;
            resp.n_images = images.items.len;
        }

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        // Clean up proto images
        if (resp.n_images > 0) {
            const img_slice = resp.images[0..resp.n_images];
            for (img_slice) |img_c_ptr| {
                const img: *proto.Image = img_c_ptr orelse continue;
                if (img.n_repo_tags > 0) {
                    const tags_slice = img.repo_tags[0..img.n_repo_tags];
                    for (tags_slice) |tag| {
                        if (tag) |t| self.allocator.free(std.mem.span(t));
                    }
                    self.allocator.free(tags_slice);
                }
                if (img.n_repo_digests > 0) {
                    const digests_slice = img.repo_digests[0..img.n_repo_digests];
                    for (digests_slice) |digest| {
                        if (digest) |d| self.allocator.free(std.mem.span(d));
                    }
                    self.allocator.free(digests_slice);
                }
                if (img.id) |id| self.allocator.free(std.mem.span(id));
                self.allocator.destroy(img);
            }
        }

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    fn handleImageStatus(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        const req = proto.unpack(proto.ImageStatusRequest, request.data) orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Invalid request");
            return;
        };
        defer proto.free(req);

        // Create response
        const resp = try self.allocator.create(proto.ImageStatusResponse);
        defer self.allocator.destroy(resp);
        resp.* = std.mem.zeroes(proto.ImageStatusResponse);
        resp.base.descriptor = &proto.c.runtime__v1__image_status_response__descriptor;

        // Extract image spec and look up image
        if (req.image) |image_spec| {
            const image_ref = proto.getString(image_spec.*.image);

            const types = @import("../cri/types.zig");
            const spec = types.ImageSpec{
                .image = image_ref,
                .annotations = null,
            };

            if (self.image_service.imageStatus(&spec, false) catch null) |status| {
                // Create proto image
                const img = try self.allocator.create(proto.c.Runtime__V1__Image);
                defer self.allocator.destroy(img);
                img.* = std.mem.zeroes(proto.c.Runtime__V1__Image);
                img.base.descriptor = &proto.c.runtime__v1__image__descriptor;

                // Set image ID - dupeZ for proto, keep status.image.id for cleanup
                const img_id_z = try self.allocator.dupeZ(u8, status.image.id);
                defer self.allocator.free(img_id_z);
                img.id = img_id_z.ptr;

                // Set size
                img.size = status.image.size;

                // Set repo_tags - need to allocate array and each string
                var tags_alloc: ?[][*c]u8 = null;
                defer if (tags_alloc) |tags| {
                    for (tags) |t| self.allocator.free(std.mem.span(t));
                    self.allocator.free(tags);
                };

                if (status.image.repo_tags.len > 0) {
                    const tags = try self.allocator.alloc([*c]u8, status.image.repo_tags.len);
                    tags_alloc = tags;
                    for (status.image.repo_tags, 0..) |tag, i| {
                        const tag_z = try self.allocator.dupeZ(u8, tag);
                        tags[i] = tag_z.ptr;
                    }
                    img.repo_tags = tags.ptr;
                    img.n_repo_tags = status.image.repo_tags.len;
                }

                resp.image = img;

                // Pack and send - at this point all proto fields are valid
                const data = try proto.pack(self.allocator, resp);
                defer self.allocator.free(data);
                try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);

                // Clean up status after sending
                self.allocator.free(status.image.id);
                for (status.image.repo_tags) |t| self.allocator.free(t);
                self.allocator.free(status.image.repo_tags);
                return;
            }
        }

        // Image not found - return empty response (per CRI spec)
        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    fn handlePullImage(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        const req = proto.unpack(proto.PullImageRequest, request.data) orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Invalid request");
            return;
        };
        defer proto.free(req);

        const image_spec = req.image orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Missing image spec");
            return;
        };

        const image_ref = proto.getString(image_spec.*.image);

        // Pull image
        const spec = @import("../cri/types.zig").ImageSpec{
            .image = image_ref,
            .annotations = null,
        };

        const image_id = self.image_service.pullImage(&spec, null, null) catch |err| {
            logging.err("Failed to pull image: {}", .{err});
            try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, "Failed to pull image");
            return;
        };
        defer self.allocator.free(image_id);

        // Create response
        const resp = try self.allocator.create(proto.PullImageResponse);
        defer self.allocator.destroy(resp);
        resp.* = std.mem.zeroes(proto.PullImageResponse);
        resp.base.descriptor = &proto.c.runtime__v1__pull_image_response__descriptor;
        resp.image_ref = try self.allocator.dupeZ(u8, image_id);
        defer self.allocator.free(std.mem.span(resp.image_ref));

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    fn handleRemoveImage(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        const req = proto.unpack(proto.RemoveImageRequest, request.data) orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Invalid request");
            return;
        };
        defer proto.free(req);

        const image_spec = req.image orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Missing image spec");
            return;
        };

        const image_ref = proto.getString(image_spec.*.image);

        const spec = @import("../cri/types.zig").ImageSpec{
            .image = image_ref,
            .annotations = null,
        };

        self.image_service.removeImage(&spec) catch |err| {
            logging.err("Failed to remove image: {}", .{err});
            try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, "Failed to remove image");
            return;
        };

        const resp = try proto.initEmptyResponse(proto.RemoveImageResponse, self.allocator);
        defer self.allocator.destroy(resp);

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    fn handleImageFsInfo(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        const resp = try self.allocator.create(proto.ImageFsInfoResponse);
        defer self.allocator.destroy(resp);
        resp.* = std.mem.zeroes(proto.ImageFsInfoResponse);
        resp.base.descriptor = &proto.c.runtime__v1__image_fs_info_response__descriptor;

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    fn handleContainerStats(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        const req = proto.unpack(proto.ContainerStatsRequest, request.data) orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Invalid request");
            return;
        };
        defer proto.free(req);

        const container_id = proto.getString(req.container_id);
        if (container_id.len == 0) {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Missing container_id");
            return;
        }

        // Get container info
        const container_info = self.runtime_service.container_manager.containerStatus(container_id) catch {
            try session.sendError(request.stream_id, http2.GrpcStatus.NOT_FOUND, "Container not found");
            return;
        };
        defer {
            var c = container_info;
            c.deinit(self.allocator);
        }

        // Create response
        const resp = try self.allocator.create(proto.ContainerStatsResponse);
        defer self.allocator.destroy(resp);
        resp.* = std.mem.zeroes(proto.ContainerStatsResponse);
        resp.base.descriptor = &proto.c.runtime__v1__container_stats_response__descriptor;

        // Create stats
        var stats = try self.allocator.create(proto.ContainerStats);
        defer self.allocator.destroy(stats);
        stats.* = std.mem.zeroes(proto.ContainerStats);
        stats.base.descriptor = &proto.c.runtime__v1__container_stats__descriptor;

        // Create attributes
        var attrs = try self.allocator.create(proto.ContainerAttributes);
        defer self.allocator.destroy(attrs);
        attrs.* = std.mem.zeroes(proto.ContainerAttributes);
        attrs.base.descriptor = &proto.c.runtime__v1__container_attributes__descriptor;
        attrs.id = try self.allocator.dupeZ(u8, container_info.id);
        defer self.allocator.free(std.mem.span(attrs.id));

        // Create metadata for attributes
        var metadata = try self.allocator.create(proto.ContainerMetadata);
        defer self.allocator.destroy(metadata);
        metadata.* = std.mem.zeroes(proto.ContainerMetadata);
        metadata.base.descriptor = &proto.c.runtime__v1__container_metadata__descriptor;
        metadata.name = try self.allocator.dupeZ(u8, container_info.name);
        defer self.allocator.free(std.mem.span(metadata.name));
        attrs.metadata = metadata;
        stats.attributes = attrs;

        // Read cgroup stats if container is running
        if (container_info.state == .running) {
            const now_ns: i64 = @intCast(std.time.nanoTimestamp());

            // Try to read CPU stats from cgroup
            if (self.readCgroupCpuStats(container_info.id)) |cpu_stats| {
                var cpu = try self.allocator.create(proto.CpuUsage);
                defer self.allocator.destroy(cpu);
                cpu.* = std.mem.zeroes(proto.CpuUsage);
                cpu.base.descriptor = &proto.c.runtime__v1__cpu_usage__descriptor;
                cpu.timestamp = now_ns;

                var usage_core = try self.allocator.create(proto.UInt64Value);
                defer self.allocator.destroy(usage_core);
                usage_core.* = std.mem.zeroes(proto.UInt64Value);
                usage_core.base.descriptor = &proto.c.runtime__v1__uint64_value__descriptor;
                usage_core.value = cpu_stats.usage_usec * 1000; // Convert usec to nsec
                cpu.usage_core_nano_seconds = usage_core;

                stats.cpu = cpu;
            } else |_| {}

            // Try to read memory stats from cgroup
            if (self.readCgroupMemoryStats(container_info.id)) |mem_stats| {
                var memory = try self.allocator.create(proto.MemoryUsage);
                defer self.allocator.destroy(memory);
                memory.* = std.mem.zeroes(proto.MemoryUsage);
                memory.base.descriptor = &proto.c.runtime__v1__memory_usage__descriptor;
                memory.timestamp = now_ns;

                var working_set = try self.allocator.create(proto.UInt64Value);
                defer self.allocator.destroy(working_set);
                working_set.* = std.mem.zeroes(proto.UInt64Value);
                working_set.base.descriptor = &proto.c.runtime__v1__uint64_value__descriptor;
                working_set.value = mem_stats.current;
                memory.working_set_bytes = working_set;

                stats.memory = memory;
            } else |_| {}
        }

        resp.stats = stats;

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    fn handleListContainerStats(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        const req = proto.unpack(proto.ListContainerStatsRequest, request.data) orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Invalid request");
            return;
        };
        defer proto.free(req);

        // Get filter if provided
        var filter: ?struct { id: ?[]const u8, pod_sandbox_id: ?[]const u8 } = null;
        if (req.filter) |f| {
            const filter_ptr = f.*;
            const id_str = if (filter_ptr.id) |id| std.mem.span(id) else "";
            const pod_id_str = if (filter_ptr.pod_sandbox_id) |id| std.mem.span(id) else "";
            filter = .{
                .id = if (id_str.len > 0) id_str else null,
                .pod_sandbox_id = if (pod_id_str.len > 0) pod_id_str else null,
            };
        }

        // List all containers
        var containers = self.runtime_service.listContainers(null) catch |err| {
            logging.err("Failed to list containers: {}", .{err});
            try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, "Failed to list containers");
            return;
        };
        defer {
            for (containers.items) |c| {
                self.allocator.free(c.id);
                self.allocator.free(c.pod_sandbox_id);
                self.allocator.free(c.metadata.name);
                self.allocator.free(c.image.image);
                self.allocator.free(c.image_ref);
            }
            containers.deinit(self.allocator);
        }


        // Create response
        const resp = try self.allocator.create(proto.ListContainerStatsResponse);
        defer self.allocator.destroy(resp);
        resp.* = std.mem.zeroes(proto.ListContainerStatsResponse);
        resp.base.descriptor = &proto.c.runtime__v1__list_container_stats_response__descriptor;

        // Apply filter and create stats array
        var stats_list: std.ArrayList(*proto.ContainerStats) = .empty;
        defer stats_list.deinit(self.allocator);

        const now_ns: i64 = @intCast(std.time.nanoTimestamp());

        for (containers.items) |cont| {
            // Apply filter
            if (filter) |f| {
                if (f.id) |id| {
                    if (!std.mem.eql(u8, cont.id, id)) continue;
                }
                if (f.pod_sandbox_id) |pod_id| {
                    if (!std.mem.eql(u8, cont.pod_sandbox_id, pod_id)) continue;
                }
            }

            var stats = try self.allocator.create(proto.ContainerStats);
            stats.* = std.mem.zeroes(proto.ContainerStats);
            stats.base.descriptor = &proto.c.runtime__v1__container_stats__descriptor;

            // Create attributes
            var attrs = try self.allocator.create(proto.ContainerAttributes);
            attrs.* = std.mem.zeroes(proto.ContainerAttributes);
            attrs.base.descriptor = &proto.c.runtime__v1__container_attributes__descriptor;
            attrs.id = try self.allocator.dupeZ(u8, cont.id);

            var metadata = try self.allocator.create(proto.ContainerMetadata);
            metadata.* = std.mem.zeroes(proto.ContainerMetadata);
            metadata.base.descriptor = &proto.c.runtime__v1__container_metadata__descriptor;
            metadata.name = try self.allocator.dupeZ(u8, cont.metadata.name);
            attrs.metadata = metadata;
            stats.attributes = attrs;

            // Try to read cgroup stats (will succeed if container is actually running)
            {
                if (self.readCgroupCpuStats(cont.id)) |cpu_stats| {
                    var cpu = try self.allocator.create(proto.CpuUsage);
                    cpu.* = std.mem.zeroes(proto.CpuUsage);
                    cpu.base.descriptor = &proto.c.runtime__v1__cpu_usage__descriptor;
                    cpu.timestamp = now_ns;

                    var usage_core = try self.allocator.create(proto.UInt64Value);
                    usage_core.* = std.mem.zeroes(proto.UInt64Value);
                    usage_core.base.descriptor = &proto.c.runtime__v1__uint64_value__descriptor;
                    usage_core.value = cpu_stats.usage_usec * 1000;
                    cpu.usage_core_nano_seconds = usage_core;
                    stats.cpu = cpu;
                } else |_| {}

                if (self.readCgroupMemoryStats(cont.id)) |mem_stats| {
                    var memory = try self.allocator.create(proto.MemoryUsage);
                    memory.* = std.mem.zeroes(proto.MemoryUsage);
                    memory.base.descriptor = &proto.c.runtime__v1__memory_usage__descriptor;
                    memory.timestamp = now_ns;

                    var working_set = try self.allocator.create(proto.UInt64Value);
                    working_set.* = std.mem.zeroes(proto.UInt64Value);
                    working_set.base.descriptor = &proto.c.runtime__v1__uint64_value__descriptor;
                    working_set.value = mem_stats.current;
                    memory.working_set_bytes = working_set;
                    stats.memory = memory;
                } else |_| {}
            }

            try stats_list.append(self.allocator, stats);
        }

        if (stats_list.items.len > 0) {
            resp.stats = @ptrCast(stats_list.items.ptr);
            resp.n_stats = stats_list.items.len;
        }

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        // Free stats after packing
        for (stats_list.items) |stats| {
            if (stats.attributes) |attrs_ptr| {
                const attrs = attrs_ptr.*;
                if (attrs.metadata) |m_ptr| {
                    const m = m_ptr.*;
                    self.allocator.free(std.mem.span(m.name));
                    self.allocator.destroy(@as(*proto.ContainerMetadata, @ptrCast(@alignCast(m_ptr))));
                }
                self.allocator.free(std.mem.span(attrs.id));
                self.allocator.destroy(@as(*proto.ContainerAttributes, @ptrCast(@alignCast(attrs_ptr))));
            }
            if (stats.cpu) |cpu_ptr| {
                const cpu = cpu_ptr.*;
                if (cpu.usage_core_nano_seconds) |u| {
                    self.allocator.destroy(@as(*proto.UInt64Value, @ptrCast(@alignCast(u))));
                }
                self.allocator.destroy(@as(*proto.CpuUsage, @ptrCast(@alignCast(cpu_ptr))));
            }
            if (stats.memory) |mem_ptr| {
                const mem = mem_ptr.*;
                if (mem.working_set_bytes) |w| {
                    self.allocator.destroy(@as(*proto.UInt64Value, @ptrCast(@alignCast(w))));
                }
                self.allocator.destroy(@as(*proto.MemoryUsage, @ptrCast(@alignCast(mem_ptr))));
            }
            self.allocator.destroy(stats);
        }

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    // Helper structs for cgroup stats
    const CgroupCpuStats = struct {
        usage_usec: u64,
    };

    const CgroupMemoryStats = struct {
        current: u64,
    };

    fn readCgroupCpuStats(self: *Self, container_id: []const u8) !CgroupCpuStats {
        // Try to find the cgroup for the container
        // systemd creates cgroups under /sys/fs/cgroup/system.slice/cri-container-<id>.service/
        const cgroup_path = try std.fmt.allocPrint(
            self.allocator,
            "/sys/fs/cgroup/system.slice/cri-container-{s}.service/cpu.stat",
            .{container_id},
        );
        defer self.allocator.free(cgroup_path);

        const file = std.fs.openFileAbsolute(cgroup_path, .{}) catch {
            return error.CgroupNotFound;
        };
        defer file.close();

        var buf: [4096]u8 = undefined;
        const bytes_read = file.readAll(&buf) catch return error.ReadError;

        // Parse cpu.stat - format: "usage_usec <value>\n..."
        var lines = std.mem.splitScalar(u8, buf[0..bytes_read], '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "usage_usec ")) {
                const value_str = line["usage_usec ".len..];
                const usage = std.fmt.parseInt(u64, std.mem.trim(u8, value_str, " \t"), 10) catch continue;
                return CgroupCpuStats{ .usage_usec = usage };
            }
        }

        return error.ParseError;
    }

    fn readCgroupMemoryStats(self: *Self, container_id: []const u8) !CgroupMemoryStats {
        // Try to find the cgroup for the container
        const cgroup_path = try std.fmt.allocPrint(
            self.allocator,
            "/sys/fs/cgroup/system.slice/cri-container-{s}.service/memory.current",
            .{container_id},
        );
        defer self.allocator.free(cgroup_path);

        const file = std.fs.openFileAbsolute(cgroup_path, .{}) catch {
            return error.CgroupNotFound;
        };
        defer file.close();

        var buf: [64]u8 = undefined;
        const bytes_read = file.readAll(&buf) catch return error.ReadError;

        const current = std.fmt.parseInt(u64, std.mem.trim(u8, buf[0..bytes_read], " \t\n"), 10) catch {
            return error.ParseError;
        };

        return CgroupMemoryStats{ .current = current };
    }

    fn handleRuntimeConfig(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        // RuntimeConfig returns the runtime configuration (cgroup driver, etc.)
        const resp = try self.allocator.create(proto.RuntimeConfigResponse);
        defer self.allocator.destroy(resp);
        resp.* = std.mem.zeroes(proto.RuntimeConfigResponse);
        resp.base.descriptor = &proto.c.runtime__v1__runtime_config_response__descriptor;

        // Create LinuxRuntimeConfiguration with cgroup driver
        var linux_config = try self.allocator.create(proto.LinuxRuntimeConfiguration);
        defer self.allocator.destroy(linux_config);
        linux_config.* = std.mem.zeroes(proto.LinuxRuntimeConfiguration);
        linux_config.base.descriptor = &proto.c.runtime__v1__linux_runtime_configuration__descriptor;
        // Use systemd cgroup driver (value 1)
        linux_config.cgroup_driver = proto.c.RUNTIME__V1__CGROUP_DRIVER__SYSTEMD;

        resp.linux = linux_config;

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }
};

/// gRPC method routing
pub const GrpcMethod = enum {
    // RuntimeService
    Version,
    RunPodSandbox,
    StopPodSandbox,
    RemovePodSandbox,
    PodSandboxStatus,
    ListPodSandbox,
    CreateContainer,
    StartContainer,
    StopContainer,
    RemoveContainer,
    ListContainers,
    ContainerStatus,
    UpdateContainerResources,
    ReopenContainerLog,
    ExecSync,
    Exec,
    Attach,
    PortForward,
    ContainerStats,
    ListContainerStats,
    PodSandboxStats,
    ListPodSandboxStats,
    UpdateRuntimeConfig,
    Status,
    CheckpointContainer,
    GetContainerEvents,
    ListMetricDescriptors,
    ListPodSandboxMetrics,
    RuntimeConfig,

    // ImageService
    ListImages,
    ImageStatus,
    PullImage,
    RemoveImage,
    ImageFsInfo,

    pub fn fromPath(path: []const u8) ?GrpcMethod {
        const methods = std.StaticStringMap(GrpcMethod).initComptime(.{
            .{ "/runtime.v1.RuntimeService/Version", .Version },
            .{ "/runtime.v1.RuntimeService/RunPodSandbox", .RunPodSandbox },
            .{ "/runtime.v1.RuntimeService/StopPodSandbox", .StopPodSandbox },
            .{ "/runtime.v1.RuntimeService/RemovePodSandbox", .RemovePodSandbox },
            .{ "/runtime.v1.RuntimeService/PodSandboxStatus", .PodSandboxStatus },
            .{ "/runtime.v1.RuntimeService/ListPodSandbox", .ListPodSandbox },
            .{ "/runtime.v1.RuntimeService/CreateContainer", .CreateContainer },
            .{ "/runtime.v1.RuntimeService/StartContainer", .StartContainer },
            .{ "/runtime.v1.RuntimeService/StopContainer", .StopContainer },
            .{ "/runtime.v1.RuntimeService/RemoveContainer", .RemoveContainer },
            .{ "/runtime.v1.RuntimeService/ListContainers", .ListContainers },
            .{ "/runtime.v1.RuntimeService/ContainerStatus", .ContainerStatus },
            .{ "/runtime.v1.RuntimeService/UpdateContainerResources", .UpdateContainerResources },
            .{ "/runtime.v1.RuntimeService/ReopenContainerLog", .ReopenContainerLog },
            .{ "/runtime.v1.RuntimeService/ExecSync", .ExecSync },
            .{ "/runtime.v1.RuntimeService/Exec", .Exec },
            .{ "/runtime.v1.RuntimeService/Attach", .Attach },
            .{ "/runtime.v1.RuntimeService/PortForward", .PortForward },
            .{ "/runtime.v1.RuntimeService/ContainerStats", .ContainerStats },
            .{ "/runtime.v1.RuntimeService/ListContainerStats", .ListContainerStats },
            .{ "/runtime.v1.RuntimeService/PodSandboxStats", .PodSandboxStats },
            .{ "/runtime.v1.RuntimeService/ListPodSandboxStats", .ListPodSandboxStats },
            .{ "/runtime.v1.RuntimeService/UpdateRuntimeConfig", .UpdateRuntimeConfig },
            .{ "/runtime.v1.RuntimeService/Status", .Status },
            .{ "/runtime.v1.RuntimeService/RuntimeConfig", .RuntimeConfig },
            .{ "/runtime.v1.ImageService/ListImages", .ListImages },
            .{ "/runtime.v1.ImageService/ImageStatus", .ImageStatus },
            .{ "/runtime.v1.ImageService/PullImage", .PullImage },
            .{ "/runtime.v1.ImageService/RemoveImage", .RemoveImage },
            .{ "/runtime.v1.ImageService/ImageFsInfo", .ImageFsInfo },
        });
        return methods.get(path);
    }
};
