const std = @import("std");
const logging = @import("../util/logging.zig");
const http2 = @import("http2.zig");
const proto = @import("../cri/proto.zig");
const runtime_service = @import("../cri/runtime_service.zig");
const image_service = @import("../cri/image_service.zig");

/// gRPC server for CRI using HTTP/2 and protobuf
pub const GrpcServer = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    runtime_service: *runtime_service.RuntimeService,
    image_service: *image_service.ImageService,
    server: ?std.net.Server = null,
    running: bool = false,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        socket_path: []const u8,
        rs: *runtime_service.RuntimeService,
        is: *image_service.ImageService,
    ) !Self {
        return Self{
            .allocator = allocator,
            .socket_path = try allocator.dupe(u8, socket_path),
            .runtime_service = rs,
            .image_service = is,
            .server = null,
            .running = false,
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

        self.running = true;
        logging.info("gRPC server listening on {s}", .{self.socket_path});
    }

    /// Stop the gRPC server
    pub fn stop(self: *Self) void {
        self.running = false;
        if (self.server) |*s| {
            s.deinit();
            self.server = null;
        }
        std.fs.deleteFileAbsolute(self.socket_path) catch {};
    }

    /// Run the server main loop
    pub fn run(self: *Self) !void {
        while (self.running) {
            self.acceptConnection() catch |err| {
                if (!self.running) break;
                logging.err("Accept error: {}", .{err});
                continue;
            };
        }
    }

    /// Accept and handle a single connection
    pub fn acceptConnection(self: *Self) !void {
        if (self.server == null) return error.NotStarted;

        const conn = try self.server.?.accept();
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

        while (true) {
            const n = conn.stream.read(&buf) catch break;
            if (n == 0) break;

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

                    // Send server settings
                    const output = session.getOutput();
                    if (output.len > 0) {
                        _ = conn.stream.write(output) catch break;
                        session.clearOutput();
                    }
                } else {
                    logging.warn("Invalid HTTP/2 preface, got: {x}", .{data[0..@min(n, 24)]});
                    break;
                }
            }

            // Pass all data to nghttp2 (it handles the preface internally)
            try session.processInput(data);

            // Send any output
            const output = session.getOutput();
            if (output.len > 0) {
                _ = conn.stream.write(output) catch break;
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

                // Send response output
                const resp_output = session.getOutput();
                if (resp_output.len > 0) {
                    _ = conn.stream.write(resp_output) catch break;
                    session.clearOutput();
                }
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
            .ListImages => try self.handleListImages(session, request),
            .ImageStatus => try self.handleImageStatus(session, request),
            .PullImage => try self.handlePullImage(session, request),
            .RemoveImage => try self.handleRemoveImage(session, request),
            .ImageFsInfo => try self.handleImageFsInfo(session, request),
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
            logging.err("Failed to stop pod sandbox: {}", .{err});
            try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, "Failed to stop pod");
            return;
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
            logging.err("Failed to remove pod sandbox: {}", .{err});
            try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, "Failed to remove pod");
            return;
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
        defer self.allocator.free(status_info.id);

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

        // Create metadata (simplified - would need to load from store for full data)
        var metadata = try self.allocator.create(proto.PodSandboxMetadata);
        defer self.allocator.destroy(metadata);
        metadata.* = std.mem.zeroes(proto.PodSandboxMetadata);
        metadata.base.descriptor = &proto.c.runtime__v1__pod_sandbox_metadata__descriptor;
        metadata.name = try self.allocator.dupeZ(u8, "");
        defer self.allocator.free(std.mem.span(metadata.name));
        metadata.uid = try self.allocator.dupeZ(u8, "");
        defer self.allocator.free(std.mem.span(metadata.uid));
        metadata.namespace_ = try self.allocator.dupeZ(u8, "default");
        defer self.allocator.free(std.mem.span(metadata.namespace_));

        status.metadata = metadata;
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

        // Create container config for our service
        const container_config = @import("../cri/types.zig").ContainerConfig{
            .metadata = .{
                .name = proto.getString(metadata.*.name),
                .attempt = metadata.*.attempt,
            },
            .image = .{ .image = proto.getString(image.*.image) },
            .working_dir = if (config.*.working_dir) |wd| proto.getString(wd) else null,
            .stdin = config.*.stdin != 0,
            .stdin_once = config.*.stdin_once != 0,
            .tty = config.*.tty != 0,
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
            logging.err("Failed to stop container: {}", .{err});
            try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, "Failed to stop container");
            return;
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
            logging.err("Failed to remove container: {}", .{err});
            try session.sendError(request.stream_id, http2.GrpcStatus.INTERNAL, "Failed to remove container");
            return;
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
        defer containers.deinit(self.allocator);

        // Create response
        const resp = try self.allocator.create(proto.ListContainersResponse);
        defer self.allocator.destroy(resp);
        resp.* = std.mem.zeroes(proto.ListContainersResponse);
        resp.base.descriptor = &proto.c.runtime__v1__list_containers_response__descriptor;

        // TODO: Populate containers list

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    fn handleContainerStatus(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        const req = proto.unpack(proto.ContainerStatusRequest, request.data) orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Invalid request");
            return;
        };
        defer proto.free(req);

        const container_id = proto.getString(req.container_id);
        _ = container_id;

        // TODO: Get actual container status
        const resp = try self.allocator.create(proto.ContainerStatusResponse);
        defer self.allocator.destroy(resp);
        resp.* = std.mem.zeroes(proto.ContainerStatusResponse);
        resp.base.descriptor = &proto.c.runtime__v1__container_status_response__descriptor;

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
        defer images.deinit(self.allocator);

        // Create response
        const resp = try self.allocator.create(proto.ListImagesResponse);
        defer self.allocator.destroy(resp);
        resp.* = std.mem.zeroes(proto.ListImagesResponse);
        resp.base.descriptor = &proto.c.runtime__v1__list_images_response__descriptor;

        // TODO: Populate images list

        const data = try proto.pack(self.allocator, resp);
        defer self.allocator.free(data);

        try session.sendResponse(request.stream_id, data, http2.GrpcStatus.OK);
    }

    fn handleImageStatus(self: *Self, session: *http2.Http2Session, request: http2.GrpcRequest) !void {
        const req = proto.unpack(proto.ImageStatusRequest, request.data) orelse {
            try session.sendError(request.stream_id, http2.GrpcStatus.INVALID_ARGUMENT, "Invalid request");
            return;
        };
        defer proto.free(req);

        // Create response (image not found returns empty response, not error)
        const resp = try self.allocator.create(proto.ImageStatusResponse);
        defer self.allocator.destroy(resp);
        resp.* = std.mem.zeroes(proto.ImageStatusResponse);
        resp.base.descriptor = &proto.c.runtime__v1__image_status_response__descriptor;

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
            .{ "/runtime.v1.ImageService/ListImages", .ListImages },
            .{ "/runtime.v1.ImageService/ImageStatus", .ImageStatus },
            .{ "/runtime.v1.ImageService/PullImage", .PullImage },
            .{ "/runtime.v1.ImageService/RemoveImage", .RemoveImage },
            .{ "/runtime.v1.ImageService/ImageFsInfo", .ImageFsInfo },
        });
        return methods.get(path);
    }
};
