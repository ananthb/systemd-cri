const std = @import("std");
const dbus = @import("../systemd/dbus.zig");
const manager = @import("../systemd/manager.zig");
const properties = @import("../systemd/properties.zig");
const store = @import("../state/store.zig");
const uuid = @import("../util/uuid.zig");
const logging = @import("../util/logging.zig");
const cni = @import("../network/cni.zig");

pub const PodError = error{
    CreateFailed,
    NotFound,
    AlreadyExists,
    InvalidState,
    SystemdError,
    StoreError,
    OutOfMemory,
};

/// Configuration for creating a pod sandbox
pub const PodConfig = struct {
    /// Pod name (from Kubernetes metadata)
    name: []const u8,
    /// Pod UID (from Kubernetes metadata)
    uid: []const u8,
    /// Namespace
    namespace: []const u8,
    /// Labels
    labels: ?std.StringHashMap([]const u8) = null,
    /// Annotations
    annotations: ?std.StringHashMap([]const u8) = null,
    /// Hostname for the pod
    hostname: ?[]const u8 = null,
    /// Log directory
    log_directory: ?[]const u8 = null,
    /// DNS configuration
    dns_config: ?DnsConfig = null,
    /// Linux-specific options
    linux: ?LinuxPodSandboxConfig = null,
};

pub const DnsConfig = struct {
    servers: []const []const u8 = &.{},
    searches: []const []const u8 = &.{},
    options: []const []const u8 = &.{},
};

pub const LinuxPodSandboxConfig = struct {
    /// CGroup parent path
    cgroup_parent: ?[]const u8 = null,
    /// Security context
    security_context: ?LinuxSandboxSecurityContext = null,
};

pub const LinuxSandboxSecurityContext = struct {
    /// Run as privileged
    privileged: bool = false,
    /// Namespace options
    namespace_options: ?NamespaceOption = null,
};

pub const NamespaceOption = struct {
    network: NamespaceMode = .pod,
    pid: NamespaceMode = .pod,
    ipc: NamespaceMode = .pod,
};

pub const NamespaceMode = enum {
    pod,
    container,
    node,
};

/// Pod sandbox status
pub const PodStatus = struct {
    id: []const u8,
    name: []const u8,
    uid: []const u8,
    namespace: []const u8,
    state: store.PodState,
    created_at: i64,
    network: ?NetworkStatus = null,
    linux: ?LinuxPodStatus = null,
};

pub const NetworkStatus = struct {
    ip: ?[]const u8 = null,
    additional_ips: []const []const u8 = &.{},
};

pub const LinuxPodStatus = struct {
    namespaces: ?Namespaces = null,
};

pub const Namespaces = struct {
    network: ?[]const u8 = null,
    options: ?NamespaceOption = null,
};

/// Pod manager handles pod sandbox lifecycle
pub const PodManager = struct {
    allocator: std.mem.Allocator,
    bus: *dbus.Bus,
    systemd_manager: manager.Manager,
    state_store: *store.Store,
    cni_plugin: ?*cni.Cni,
    network_config: ?cni.NetworkConfig = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, bus: *dbus.Bus, state_store: *store.Store, cni_plugin: ?*cni.Cni) Self {
        return Self{
            .allocator = allocator,
            .bus = bus,
            .systemd_manager = manager.Manager.init(bus, allocator),
            .state_store = state_store,
            .cni_plugin = cni_plugin,
            .network_config = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.network_config) |*cfg| {
            cfg.deinit(self.allocator);
        }
    }

    /// Load and cache the network configuration
    fn ensureNetworkConfig(self: *Self) !*cni.NetworkConfig {
        if (self.network_config) |*cfg| {
            return cfg;
        }

        if (self.cni_plugin) |plugin| {
            self.network_config = try plugin.loadNetworkConfig(null);
            return &self.network_config.?;
        }

        return cni.CniError.ConfigNotFound;
    }

    /// Create and run a new pod sandbox
    /// Returns the pod ID
    pub fn runPodSandbox(self: *Self, config: *const PodConfig) PodError![]const u8 {
        // Generate pod ID
        const pod_id = uuid.generateString(self.allocator) catch return PodError.OutOfMemory;
        errdefer self.allocator.free(pod_id);

        logging.info("Creating pod sandbox: id={s} name={s} namespace={s}", .{
            pod_id,
            config.name,
            config.namespace,
        });

        // Generate unit name
        var unit_name_buf: [128]u8 = undefined;
        const unit_name = manager.podServiceName(pod_id, &unit_name_buf) catch return PodError.OutOfMemory;

        // Create null-terminated unit name for D-Bus
        const unit_name_z = self.allocator.dupeZ(u8, unit_name) catch return PodError.OutOfMemory;
        defer self.allocator.free(unit_name_z);

        // Determine the slice for resource control
        const slice: [*:0]const u8 = if (config.linux) |linux| blk: {
            if (linux.cgroup_parent) |parent| {
                break :blk self.allocator.dupeZ(u8, parent) catch return PodError.OutOfMemory;
            }
            break :blk "system.slice";
        } else "system.slice";

        // Create the pod config for the property builder closure
        const PodConfigContext = struct {
            slice: [*:0]const u8,
            description: [*:0]const u8,
        };

        var desc_buf: [256]u8 = undefined;
        const desc_slice = std.fmt.bufPrint(&desc_buf, "CRI Pod Sandbox: {s}/{s}", .{ config.namespace, config.name }) catch return PodError.OutOfMemory;
        const description = self.allocator.dupeZ(u8, desc_slice) catch return PodError.OutOfMemory;
        defer self.allocator.free(description);

        // Store context for closure
        var ctx = PodConfigContext{
            .slice = slice,
            .description = description,
        };
        _ = &ctx;

        // Start the transient service
        // The pod service is a simple "pause" container that keeps namespaces alive
        // For now, we use a simple sleep command; later this would be replaced with
        // a proper pause container image
        const job_path = self.systemd_manager.startTransientService(
            unit_name_z,
            "fail",
            &configurePodService,
        ) catch {
            logging.err("Failed to start transient unit for pod {s}", .{pod_id});
            return PodError.SystemdError;
        };
        defer self.allocator.free(job_path);

        logging.debug("Started systemd unit: {s}, job: {s}", .{ unit_name, job_path });

        // Create pod state
        var labels = std.StringHashMap([]const u8).init(self.allocator);
        var annotations = std.StringHashMap([]const u8).init(self.allocator);

        // Copy labels if provided
        if (config.labels) |src_labels| {
            var it = src_labels.iterator();
            while (it.next()) |entry| {
                const key = self.allocator.dupe(u8, entry.key_ptr.*) catch return PodError.OutOfMemory;
                const val = self.allocator.dupe(u8, entry.value_ptr.*) catch return PodError.OutOfMemory;
                labels.put(key, val) catch return PodError.OutOfMemory;
            }
        }

        // Copy annotations if provided
        if (config.annotations) |src_annots| {
            var it = src_annots.iterator();
            while (it.next()) |entry| {
                const key = self.allocator.dupe(u8, entry.key_ptr.*) catch return PodError.OutOfMemory;
                const val = self.allocator.dupe(u8, entry.value_ptr.*) catch return PodError.OutOfMemory;
                annotations.put(key, val) catch return PodError.OutOfMemory;
            }
        }

        // Set up networking via CNI
        var network_namespace: ?[]const u8 = null;
        var pod_ip: ?[]const u8 = null;
        var pod_gateway: ?[]const u8 = null;

        // Check if we should use host network
        const use_host_network = if (config.linux) |linux| blk: {
            if (linux.security_context) |sec_ctx| {
                if (sec_ctx.namespace_options) |ns_opts| {
                    break :blk ns_opts.network == .node;
                }
            }
            break :blk false;
        } else false;

        if (!use_host_network and self.cni_plugin != null) {
            // Create network namespace
            const netns_name = std.fmt.allocPrint(self.allocator, "cri-{s}", .{pod_id[0..8]}) catch return PodError.OutOfMemory;
            defer self.allocator.free(netns_name);

            if (cni.createNetns(self.allocator, netns_name)) |ns_path| {
                network_namespace = ns_path;

                // Set up networking
                if (self.ensureNetworkConfig()) |net_config| {
                    if (self.cni_plugin.?.setupNetwork(
                        pod_id,
                        config.name,
                        config.namespace,
                        ns_path,
                        "eth0",
                        net_config,
                    )) |result| {
                        var cni_result = result;
                        defer cni_result.deinit(self.allocator);

                        // Extract IP address (strip CIDR notation if present)
                        if (cni_result.getIp()) |ip| {
                            const ip_only = if (std.mem.indexOf(u8, ip, "/")) |idx|
                                self.allocator.dupe(u8, ip[0..idx]) catch return PodError.OutOfMemory
                            else
                                self.allocator.dupe(u8, ip) catch return PodError.OutOfMemory;
                            pod_ip = ip_only;
                        }

                        if (cni_result.getGateway()) |gw| {
                            pod_gateway = self.allocator.dupe(u8, gw) catch return PodError.OutOfMemory;
                        }

                        logging.info("Pod {s} assigned IP: {s}", .{ pod_id, pod_ip orelse "none" });
                    } else |err| {
                        logging.warn("CNI setup failed: {}, continuing without network", .{err});
                    }
                } else |err| {
                    logging.warn("Failed to load CNI config: {}", .{err});
                }
            } else |err| {
                logging.warn("Failed to create network namespace: {}", .{err});
                // Continue without network isolation if CNI fails
            }
        }

        var pod_state = store.PodSandbox{
            .id = pod_id,
            .name = self.allocator.dupe(u8, config.name) catch return PodError.OutOfMemory,
            .namespace = self.allocator.dupe(u8, config.namespace) catch return PodError.OutOfMemory,
            .uid = self.allocator.dupe(u8, config.uid) catch return PodError.OutOfMemory,
            .state = .ready,
            .created_at = std.time.timestamp(),
            .unit_name = self.allocator.dupe(u8, unit_name) catch return PodError.OutOfMemory,
            .network_namespace = network_namespace,
            .pod_ip = pod_ip,
            .pod_gateway = pod_gateway,
            .labels = labels,
            .annotations = annotations,
        };

        // Save pod state
        self.state_store.savePod(&pod_state) catch {
            // Try to stop the unit we just started
            _ = self.systemd_manager.stopUnitRaw(unit_name_z, "fail") catch {};
            return PodError.StoreError;
        };

        // Return owned copy of pod_id (state now owns original)
        return self.allocator.dupe(u8, pod_id) catch return PodError.OutOfMemory;
    }

    /// Stop a pod sandbox
    pub fn stopPodSandbox(self: *Self, pod_id: []const u8) PodError!void {
        logging.info("Stopping pod sandbox: {s}", .{pod_id});

        // Load pod state
        var pod = self.state_store.loadPod(pod_id) catch return PodError.NotFound;
        defer pod.deinit(self.allocator);

        // Create null-terminated unit name
        const unit_name_z = self.allocator.dupeZ(u8, pod.unit_name) catch return PodError.OutOfMemory;
        defer self.allocator.free(unit_name_z);

        // Stop the systemd unit
        _ = self.systemd_manager.stopUnitRaw(unit_name_z, "fail") catch |err| {
            logging.warn("Failed to stop unit {s}: {}", .{ pod.unit_name, err });
            // Continue anyway - unit might already be stopped
        };

        // Update pod state
        pod.state = .not_ready;
        self.state_store.savePod(&pod) catch return PodError.StoreError;
    }

    /// Remove a pod sandbox
    pub fn removePodSandbox(self: *Self, pod_id: []const u8) PodError!void {
        logging.info("Removing pod sandbox: {s}", .{pod_id});

        // Load pod state
        var pod = self.state_store.loadPod(pod_id) catch return PodError.NotFound;
        defer pod.deinit(self.allocator);

        // Ensure pod is stopped first
        if (pod.state == .ready) {
            self.stopPodSandbox(pod_id) catch {};
        }

        // Tear down networking via CNI
        if (pod.network_namespace) |ns_path| {
            if (self.cni_plugin) |plugin| {
                if (self.network_config) |*net_config| {
                    plugin.teardownNetwork(
                        pod_id,
                        pod.name,
                        pod.namespace,
                        ns_path,
                        "eth0",
                        net_config,
                    );
                }
            }

            // Delete network namespace
            // Extract netns name from path (e.g., /var/run/netns/cri-abcd1234 -> cri-abcd1234)
            if (std.mem.lastIndexOf(u8, ns_path, "/")) |idx| {
                const netns_name = ns_path[idx + 1 ..];
                cni.deleteNetns(self.allocator, netns_name);
            }
        }

        // Create null-terminated unit name
        const unit_name_z = self.allocator.dupeZ(u8, pod.unit_name) catch return PodError.OutOfMemory;
        defer self.allocator.free(unit_name_z);

        // Reset failed state if needed
        self.systemd_manager.resetFailedUnit(unit_name_z) catch {};

        // Delete pod state
        self.state_store.deletePod(pod_id) catch return PodError.StoreError;
    }

    /// Get pod sandbox status
    pub fn podSandboxStatus(self: *Self, pod_id: []const u8) PodError!PodStatus {
        // Load pod state
        var pod = self.state_store.loadPod(pod_id) catch return PodError.NotFound;
        defer pod.deinit(self.allocator);

        // Get current state from systemd
        const unit_name_z = self.allocator.dupeZ(u8, pod.unit_name) catch return PodError.OutOfMemory;
        defer self.allocator.free(unit_name_z);

        var current_state = pod.state;

        // Try to get unit status from systemd
        if (self.systemd_manager.getUnit(unit_name_z)) |unit_path| {
            defer self.allocator.free(unit_path);

            const unit_path_z = self.allocator.dupeZ(u8, unit_path) catch return PodError.OutOfMemory;
            defer self.allocator.free(unit_path_z);

            const active_state = self.systemd_manager.getUnitActiveState(unit_path_z) catch .unknown;

            current_state = switch (active_state) {
                .active, .reloading => .ready,
                .inactive, .failed, .deactivating => .not_ready,
                .activating => .created,
                .unknown => pod.state,
            };
        } else |_| {
            // Unit not found - pod is not ready
            current_state = .not_ready;
        }

        return PodStatus{
            .id = self.allocator.dupe(u8, pod_id) catch return PodError.OutOfMemory,
            .name = self.allocator.dupe(u8, pod.name) catch return PodError.OutOfMemory,
            .uid = self.allocator.dupe(u8, pod.uid) catch return PodError.OutOfMemory,
            .namespace = self.allocator.dupe(u8, pod.namespace) catch return PodError.OutOfMemory,
            .state = current_state,
            .created_at = pod.created_at,
            .network = if (pod.pod_ip) |ip| NetworkStatus{
                .ip = self.allocator.dupe(u8, ip) catch return PodError.OutOfMemory,
                .additional_ips = &.{},
            } else null,
            .linux = if (pod.network_namespace) |ns| LinuxPodStatus{
                .namespaces = Namespaces{
                    .network = self.allocator.dupe(u8, ns) catch return PodError.OutOfMemory,
                    .options = null,
                },
            } else null,
        };
    }

    /// List all pod sandboxes
    pub fn listPodSandboxes(self: *Self, filter: ?PodSandboxFilter) PodError!std.ArrayList(PodSandboxInfo) {
        var results: std.ArrayList(PodSandboxInfo) = .empty;
        errdefer {
            for (results.items) |*info| {
                info.deinit(self.allocator);
            }
            results.deinit(self.allocator);
        }

        // Get all pod IDs from store
        var pod_ids = self.state_store.listPods() catch return PodError.StoreError;
        defer {
            for (pod_ids.items) |id| {
                self.allocator.free(id);
            }
            pod_ids.deinit(self.allocator);
        }

        for (pod_ids.items) |pod_id| {
            var pod = self.state_store.loadPod(pod_id) catch continue;
            defer pod.deinit(self.allocator);

            // Apply filter if provided
            if (filter) |f| {
                if (f.id) |filter_id| {
                    if (!std.mem.eql(u8, pod.id, filter_id)) continue;
                }
                if (f.state) |filter_state| {
                    if (pod.state != filter_state) continue;
                }
                // TODO: Apply label selectors
            }

            // Copy labels
            var labels = std.StringHashMap([]const u8).init(self.allocator);
            var it = pod.labels.iterator();
            while (it.next()) |entry| {
                const key = self.allocator.dupe(u8, entry.key_ptr.*) catch return PodError.OutOfMemory;
                const val = self.allocator.dupe(u8, entry.value_ptr.*) catch return PodError.OutOfMemory;
                labels.put(key, val) catch return PodError.OutOfMemory;
            }

            // Copy annotations
            var annotations = std.StringHashMap([]const u8).init(self.allocator);
            var annot_it = pod.annotations.iterator();
            while (annot_it.next()) |entry| {
                const key = self.allocator.dupe(u8, entry.key_ptr.*) catch return PodError.OutOfMemory;
                const val = self.allocator.dupe(u8, entry.value_ptr.*) catch return PodError.OutOfMemory;
                annotations.put(key, val) catch return PodError.OutOfMemory;
            }

            const info = PodSandboxInfo{
                .id = self.allocator.dupe(u8, pod.id) catch return PodError.OutOfMemory,
                .name = self.allocator.dupe(u8, pod.name) catch return PodError.OutOfMemory,
                .uid = self.allocator.dupe(u8, pod.uid) catch return PodError.OutOfMemory,
                .namespace = self.allocator.dupe(u8, pod.namespace) catch return PodError.OutOfMemory,
                .state = pod.state,
                .created_at = pod.created_at,
                .labels = labels,
                .annotations = annotations,
            };
            results.append(self.allocator, info) catch return PodError.OutOfMemory;
        }

        return results;
    }
};

/// Filter for listing pod sandboxes
pub const PodSandboxFilter = struct {
    id: ?[]const u8 = null,
    state: ?store.PodState = null,
    label_selector: ?std.StringHashMap([]const u8) = null,
};

/// Summary info returned by ListPodSandbox
pub const PodSandboxInfo = struct {
    id: []const u8,
    name: []const u8,
    uid: []const u8,
    namespace: []const u8,
    state: store.PodState,
    created_at: i64,
    labels: std.StringHashMap([]const u8),
    annotations: std.StringHashMap([]const u8),

    pub fn deinit(self: *PodSandboxInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.uid);
        allocator.free(self.namespace);

        var it = self.labels.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.labels.deinit();

        var annot_it = self.annotations.iterator();
        while (annot_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.annotations.deinit();
    }
};

/// Configure pod service properties
fn configurePodService(builder: *properties.PropertyBuilder) anyerror!void {
    // Set service description
    try properties.PodServiceProperties.setDescription(builder, "CRI Pod Sandbox");

    // Set slice for resource control
    try properties.PodServiceProperties.setSlice(builder, "system.slice");

    // Use Type=exec for simple process management
    try properties.PodServiceProperties.setType(builder, "exec");

    // ExecStart - run a simple pause command
    // In production, this would be a proper pause container
    // For now, just sleep indefinitely
    const argv = [_][*:0]const u8{ "/bin/sleep", "infinity" };
    try builder.addExecStart("/bin/sleep", &argv, false);
}
