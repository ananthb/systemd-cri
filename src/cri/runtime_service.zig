const std = @import("std");
const types = @import("types.zig");
const pod = @import("../container/pod.zig");
const container = @import("../container/container.zig");
const store = @import("../state/store.zig");
const logging = @import("../util/logging.zig");

/// Filter for listing pod sandboxes
pub const PodSandboxFilter = struct {
    id: ?[]const u8 = null,
    state: ?types.PodSandboxState = null,
    label_selector: ?std.StringHashMap([]const u8) = null,
};

/// Filter for listing containers
pub const ContainerFilter = struct {
    id: ?[]const u8 = null,
    state: ?types.ContainerState = null,
    pod_sandbox_id: ?[]const u8 = null,
    label_selector: ?std.StringHashMap([]const u8) = null,
};

/// RuntimeService implements the CRI RuntimeService interface
pub const RuntimeService = struct {
    allocator: std.mem.Allocator,
    pod_manager: *pod.PodManager,
    container_manager: *container.ContainerManager,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        pod_manager: *pod.PodManager,
        container_manager: *container.ContainerManager,
    ) Self {
        return Self{
            .allocator = allocator,
            .pod_manager = pod_manager,
            .container_manager = container_manager,
        };
    }

    // ========================================================================
    // Version
    // ========================================================================

    pub fn version(self: *Self) VersionResponse {
        _ = self;
        return VersionResponse{
            .version = types.CRI_VERSION,
            .runtime_name = types.RUNTIME_NAME,
            .runtime_version = types.RUNTIME_VERSION,
            .runtime_api_version = types.CRI_VERSION,
        };
    }

    // ========================================================================
    // Pod Sandbox Operations
    // ========================================================================

    pub fn runPodSandbox(self: *Self, config: *const types.PodSandboxConfig) ![]const u8 {
        const pod_config = pod.PodConfig{
            .name = config.metadata.name,
            .uid = config.metadata.uid,
            .namespace = config.metadata.namespace,
            .labels = config.labels,
            .annotations = config.annotations,
            .hostname = config.hostname,
            .log_directory = config.log_directory,
            .dns_config = if (config.dns_config) |dns| pod.DnsConfig{
                .servers = dns.servers,
                .searches = dns.searches,
                .options = dns.options,
            } else null,
            .linux = if (config.linux) |linux| pod.LinuxPodSandboxConfig{
                .cgroup_parent = linux.cgroup_parent,
                .security_context = if (linux.security_context) |sc| pod.LinuxSandboxSecurityContext{
                    .privileged = sc.privileged,
                    .namespace_options = if (sc.namespace_options) |ns| pod.NamespaceOption{
                        .network = @enumFromInt(@intFromEnum(ns.network)),
                        .pid = @enumFromInt(@intFromEnum(ns.pid)),
                        .ipc = @enumFromInt(@intFromEnum(ns.ipc)),
                    } else null,
                } else null,
            } else null,
        };

        return try self.pod_manager.runPodSandbox(&pod_config);
    }

    pub fn stopPodSandbox(self: *Self, pod_sandbox_id: []const u8) !void {
        try self.pod_manager.stopPodSandbox(pod_sandbox_id);
    }

    pub fn removePodSandbox(self: *Self, pod_sandbox_id: []const u8) !void {
        try self.pod_manager.removePodSandbox(pod_sandbox_id);
    }

    pub fn podSandboxStatus(self: *Self, pod_sandbox_id: []const u8) !PodSandboxStatusResponse {
        const pod_status = try self.pod_manager.podSandboxStatus(pod_sandbox_id);

        return PodSandboxStatusResponse{
            .status = .{
                .id = pod_status.id,
                .metadata = .{
                    .name = pod_status.name,
                    .uid = pod_status.uid,
                    .namespace = pod_status.namespace,
                    .attempt = 0,
                },
                .state = switch (pod_status.state) {
                    .ready => .sandbox_ready,
                    else => .sandbox_notready,
                },
                .created_at = pod_status.created_at * 1_000_000_000, // Convert to nanoseconds
                .network = null,
                .linux = null,
                .labels = null,
                .annotations = null,
                .runtime_handler = null,
            },
            .info = null,
            .containers_statuses = null,
            .timestamp = std.time.timestamp(),
        };
    }

    pub fn listPodSandbox(self: *Self, filter: ?PodSandboxFilter) !std.ArrayList(PodSandboxInfo) {
        const pod_filter = if (filter) |f| pod.PodSandboxFilter{
            .id = f.id,
            .state = if (f.state) |s| switch (s) {
                .sandbox_ready => store.PodState.ready,
                .sandbox_notready => store.PodState.not_ready,
            } else null,
            .label_selector = f.label_selector,
        } else null;

        var pods = try self.pod_manager.listPodSandboxes(pod_filter);
        defer {
            for (pods.items) |*p| {
                p.deinit(self.allocator);
            }
            pods.deinit(self.allocator);
        }

        var results: std.ArrayList(PodSandboxInfo) = .empty;
        errdefer results.deinit(self.allocator);

        for (pods.items) |p| {
            try results.append(self.allocator, PodSandboxInfo{
                .id = try self.allocator.dupe(u8, p.id),
                .metadata = .{
                    .name = try self.allocator.dupe(u8, p.name),
                    .uid = try self.allocator.dupe(u8, p.uid),
                    .namespace = try self.allocator.dupe(u8, p.namespace),
                    .attempt = 0,
                },
                .state = switch (p.state) {
                    .ready => .sandbox_ready,
                    else => .sandbox_notready,
                },
                .created_at = p.created_at * 1_000_000_000,
                .labels = null,
                .annotations = null,
                .runtime_handler = null,
            });
        }

        return results;
    }

    // ========================================================================
    // Container Operations
    // ========================================================================

    pub fn createContainer(
        self: *Self,
        pod_sandbox_id: []const u8,
        config: *const types.ContainerConfig,
        sandbox_config: *const types.PodSandboxConfig,
    ) ![]const u8 {
        _ = sandbox_config;

        // Convert mounts if present
        var mounts: ?[]const container.Mount = null;
        if (config.mounts.len > 0) {
            var mount_list = try self.allocator.alloc(container.Mount, config.mounts.len);
            for (config.mounts, 0..) |m, i| {
                mount_list[i] = .{
                    .container_path = m.container_path,
                    .host_path = m.host_path,
                    .readonly = m.readonly,
                    .propagation = switch (m.propagation) {
                        .propagation_private => .private,
                        .propagation_host_to_container => .host_to_container,
                        .propagation_bidirectional => .bidirectional,
                    },
                };
            }
            mounts = mount_list;
        }

        // Convert linux security context if present
        var linux_config: ?container.LinuxContainerConfig = null;
        if (config.linux) |linux| {
            if (linux.security_context) |sec| {
                linux_config = .{
                    .security_context = .{
                        .privileged = sec.privileged,
                        .run_as_user = if (sec.run_as_user) |u| u.value else null,
                        .run_as_group = if (sec.run_as_group) |g| g.value else null,
                        .readonly_rootfs = sec.readonly_rootfs,
                    },
                };
            }
        }

        const container_config = container.ContainerConfig{
            .name = config.metadata.name,
            .image = .{
                .image = config.image.image,
                .annotations = config.image.annotations,
            },
            .command = if (config.command.len > 0) config.command else null,
            .args = if (config.args.len > 0) config.args else null,
            .working_dir = config.working_dir,
            .envs = if (config.envs.len > 0) blk: {
                var envs = try self.allocator.alloc(container.KeyValue, config.envs.len);
                for (config.envs, 0..) |env, i| {
                    envs[i] = .{ .key = env.key, .value = env.value };
                }
                break :blk envs;
            } else null,
            .mounts = mounts,
            .labels = config.labels,
            .annotations = config.annotations,
            .log_path = config.log_path,
            .linux = linux_config,
        };

        return try self.container_manager.createContainer(pod_sandbox_id, &container_config);
    }

    pub fn startContainer(self: *Self, container_id: []const u8) !void {
        try self.container_manager.startContainer(container_id);
    }

    pub fn stopContainer(self: *Self, container_id: []const u8, timeout: i64) !void {
        try self.container_manager.stopContainer(container_id, timeout);
    }

    pub fn removeContainer(self: *Self, container_id: []const u8) !void {
        try self.container_manager.removeContainer(container_id);
    }

    pub fn containerStatus(self: *Self, container_id: []const u8) !ContainerStatusResponse {
        var cont = try self.container_manager.containerStatus(container_id);
        defer cont.deinit(self.allocator);

        // Parse mounts from JSON if present and convert to types.Mount
        var mounts: ?[]types.Mount = null;
        if (cont.mounts_json) |mj| {
            const container_mounts = container.deserializeMounts(self.allocator, mj) catch null;
            if (container_mounts) |cm| {
                if (cm.len > 0) {
                    mounts = try self.allocator.alloc(types.Mount, cm.len);
                    for (cm, 0..) |m, i| {
                        mounts.?[i] = .{
                            .container_path = m.container_path,
                            .host_path = m.host_path,
                            .readonly = m.readonly,
                            .propagation = switch (m.propagation) {
                                .private => .propagation_private,
                                .host_to_container => .propagation_host_to_container,
                                .bidirectional => .propagation_bidirectional,
                            },
                        };
                    }
                }
            }
        }

        return ContainerStatusResponse{
            .status = .{
                .id = try self.allocator.dupe(u8, cont.id),
                .metadata = .{
                    .name = try self.allocator.dupe(u8, cont.name),
                    .attempt = 0,
                },
                .state = switch (cont.state) {
                    .created => .container_created,
                    .running => .container_running,
                    .exited => .container_exited,
                    .unknown => .container_unknown,
                },
                .created_at = cont.created_at * 1_000_000_000,
                .started_at = cont.started_at * 1_000_000_000,
                .finished_at = cont.finished_at * 1_000_000_000,
                .exit_code = cont.exit_code,
                .image = .{ .image = try self.allocator.dupe(u8, cont.image) },
                .image_ref = try self.allocator.dupe(u8, cont.image_ref),
                .reason = null,
                .message = null,
                .labels = null,
                .annotations = null,
                .mounts = mounts,
                .log_path = if (cont.log_path) |lp| try self.allocator.dupe(u8, lp) else null,
                .resources = null,
            },
            .info = null,
        };
    }

    pub fn listContainers(self: *Self, filter: ?container.ContainerFilter) !std.ArrayList(ContainerInfo) {
        var containers = try self.container_manager.listContainers(filter);
        defer {
            for (containers.items) |*c| {
                c.deinit(self.allocator);
            }
            containers.deinit(self.allocator);
        }

        var results: std.ArrayList(ContainerInfo) = .empty;
        errdefer results.deinit(self.allocator);

        for (containers.items) |c| {
            try results.append(self.allocator, ContainerInfo{
                .id = try self.allocator.dupe(u8, c.id),
                .pod_sandbox_id = try self.allocator.dupe(u8, c.pod_sandbox_id),
                .metadata = .{
                    .name = try self.allocator.dupe(u8, c.name),
                    .attempt = 0,
                },
                .image = .{ .image = try self.allocator.dupe(u8, c.image) },
                .image_ref = try self.allocator.dupe(u8, c.image_ref),
                .state = switch (c.state) {
                    .created => .container_created,
                    .running => .container_running,
                    .exited => .container_exited,
                    .unknown => .container_unknown,
                },
                .created_at = c.created_at * 1_000_000_000,
                .labels = null,
                .annotations = null,
            });
        }

        return results;
    }

    // ========================================================================
    // Runtime Status
    // ========================================================================

    pub fn status(self: *Self) StatusResponse {
        _ = self;
        return StatusResponse{
            .status = .{
                .conditions = &[_]types.RuntimeCondition{
                    .{ .type = "RuntimeReady", .status = true, .reason = null, .message = null },
                    .{ .type = "NetworkReady", .status = true, .reason = null, .message = null },
                },
            },
            .info = null,
        };
    }
};

// ============================================================================
// Response Types
// ============================================================================

pub const VersionResponse = struct {
    version: []const u8,
    runtime_name: []const u8,
    runtime_version: []const u8,
    runtime_api_version: []const u8,
};

pub const PodSandboxStatusResponse = struct {
    status: PodSandboxStatus,
    info: ?std.StringHashMap([]const u8),
    containers_statuses: ?[]const ContainerStatus,
    timestamp: i64,
};

pub const PodSandboxStatus = struct {
    id: []const u8,
    metadata: types.PodSandboxMetadata,
    state: types.PodSandboxState,
    created_at: i64,
    network: ?PodSandboxNetworkStatus,
    linux: ?LinuxPodSandboxStatus,
    labels: ?std.StringHashMap([]const u8),
    annotations: ?std.StringHashMap([]const u8),
    runtime_handler: ?[]const u8,
};

pub const PodSandboxNetworkStatus = struct {
    ip: ?[]const u8,
    additional_ips: []const PodIP,
};

pub const PodIP = struct {
    ip: []const u8,
};

pub const LinuxPodSandboxStatus = struct {
    namespaces: ?Namespace,
};

pub const Namespace = struct {
    options: ?types.NamespaceOption,
};

pub const PodSandboxInfo = struct {
    id: []const u8,
    metadata: types.PodSandboxMetadata,
    state: types.PodSandboxState,
    created_at: i64,
    labels: ?std.StringHashMap([]const u8),
    annotations: ?std.StringHashMap([]const u8),
    runtime_handler: ?[]const u8,
};

pub const ContainerStatusResponse = struct {
    status: ContainerStatus,
    info: ?std.StringHashMap([]const u8),
};

pub const ContainerStatus = struct {
    id: []const u8,
    metadata: types.ContainerMetadata,
    state: types.ContainerState,
    created_at: i64,
    started_at: i64,
    finished_at: i64,
    exit_code: i32,
    image: types.ImageSpec,
    image_ref: []const u8,
    reason: ?[]const u8,
    message: ?[]const u8,
    labels: ?std.StringHashMap([]const u8),
    annotations: ?std.StringHashMap([]const u8),
    mounts: ?[]const types.Mount,
    log_path: ?[]const u8,
    resources: ?types.LinuxContainerResources,
};

pub const ContainerInfo = struct {
    id: []const u8,
    pod_sandbox_id: []const u8,
    metadata: types.ContainerMetadata,
    image: types.ImageSpec,
    image_ref: []const u8,
    state: types.ContainerState,
    created_at: i64,
    labels: ?std.StringHashMap([]const u8),
    annotations: ?std.StringHashMap([]const u8),
};

pub const StatusResponse = struct {
    status: types.RuntimeStatus,
    info: ?std.StringHashMap([]const u8),
};

pub const types_PodSandboxFilter = struct {
    id: ?[]const u8 = null,
    state: ?types.PodSandboxState = null,
    label_selector: ?std.StringHashMap([]const u8) = null,
};
