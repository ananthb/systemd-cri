const std = @import("std");
const dbus = @import("../systemd/dbus.zig");
const manager = @import("../systemd/manager.zig");
const properties = @import("../systemd/properties.zig");
const store = @import("../state/store.zig");
const overlay = @import("../rootfs/overlay.zig");
const uuid = @import("../util/uuid.zig");
const logging = @import("../util/logging.zig");
const c = dbus.raw;

pub const ContainerError = error{
    CreateFailed,
    StartFailed,
    StopFailed,
    NotFound,
    AlreadyExists,
    InvalidState,
    PodNotFound,
    ImageNotFound,
    RootfsFailed,
    SystemdError,
    StoreError,
    OutOfMemory,
};

/// Container configuration
pub const ContainerConfig = struct {
    /// Container name
    name: []const u8,
    /// Image to use
    image: ImageSpec,
    /// Command to run (overrides image entrypoint)
    command: ?[]const []const u8 = null,
    /// Arguments to command
    args: ?[]const []const u8 = null,
    /// Working directory
    working_dir: ?[]const u8 = null,
    /// Environment variables
    envs: ?[]const KeyValue = null,
    /// Mounts
    mounts: ?[]const Mount = null,
    /// Labels
    labels: ?std.StringHashMap([]const u8) = null,
    /// Annotations
    annotations: ?std.StringHashMap([]const u8) = null,
    /// Log path
    log_path: ?[]const u8 = null,
    /// Linux-specific config
    linux: ?LinuxContainerConfig = null,
};

pub const ImageSpec = struct {
    image: []const u8,
    annotations: ?std.StringHashMap([]const u8) = null,
};

pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

pub const Mount = struct {
    container_path: []const u8,
    host_path: []const u8,
    readonly: bool = false,
    propagation: MountPropagation = .private,
};

pub const MountPropagation = enum {
    private,
    host_to_container,
    bidirectional,
};

pub const LinuxContainerConfig = struct {
    resources: ?LinuxResources = null,
    security_context: ?LinuxContainerSecurityContext = null,
};

pub const LinuxResources = struct {
    cpu_period: ?i64 = null,
    cpu_quota: ?i64 = null,
    cpu_shares: ?i64 = null,
    memory_limit_bytes: ?i64 = null,
    oom_score_adj: ?i64 = null,
};

pub const LinuxContainerSecurityContext = struct {
    privileged: bool = false,
    run_as_user: ?i64 = null,
    run_as_group: ?i64 = null,
    readonly_rootfs: bool = false,
};

/// Container status information
pub const ContainerStatus = struct {
    id: []const u8,
    state: store.ContainerState,
    created_at: i64,
    started_at: i64,
    finished_at: i64,
    exit_code: i32,
    image_ref: []const u8,
    mounts: []const Mount,
    log_path: ?[]const u8,
};

/// Container manager handles container lifecycle
pub const ContainerManager = struct {
    allocator: std.mem.Allocator,
    bus: *dbus.Bus,
    systemd_manager: manager.Manager,
    state_store: *store.Store,
    base_path: []const u8,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        bus: *dbus.Bus,
        state_store: *store.Store,
        base_path: []const u8,
    ) Self {
        return Self{
            .allocator = allocator,
            .bus = bus,
            .systemd_manager = manager.Manager.init(bus, allocator),
            .state_store = state_store,
            .base_path = base_path,
        };
    }

    /// Create a new container (does not start it)
    pub fn createContainer(
        self: *Self,
        pod_sandbox_id: []const u8,
        config: *const ContainerConfig,
    ) ContainerError![]const u8 {
        // Verify pod exists
        _ = self.state_store.loadPod(pod_sandbox_id) catch {
            return ContainerError.PodNotFound;
        };

        // Generate container ID
        const container_id = uuid.generateString(self.allocator) catch return ContainerError.OutOfMemory;
        errdefer self.allocator.free(container_id);

        logging.info("Creating container: id={s} name={s} pod={s}", .{
            container_id,
            config.name,
            pod_sandbox_id,
        });

        // Generate unit name for the container scope
        var unit_name_buf: [128]u8 = undefined;
        const unit_name = manager.containerScopeName(container_id, &unit_name_buf) catch return ContainerError.OutOfMemory;

        // TODO: Setup rootfs from image layers
        // For now, we'll use the image name as a placeholder
        const image_ref = self.allocator.dupe(u8, config.image.image) catch return ContainerError.OutOfMemory;

        // Create container state
        var labels = std.StringHashMap([]const u8).init(self.allocator);
        var annotations = std.StringHashMap([]const u8).init(self.allocator);

        if (config.labels) |src_labels| {
            var it = src_labels.iterator();
            while (it.next()) |entry| {
                const key = self.allocator.dupe(u8, entry.key_ptr.*) catch return ContainerError.OutOfMemory;
                const val = self.allocator.dupe(u8, entry.value_ptr.*) catch return ContainerError.OutOfMemory;
                labels.put(key, val) catch return ContainerError.OutOfMemory;
            }
        }

        if (config.annotations) |src_annots| {
            var it = src_annots.iterator();
            while (it.next()) |entry| {
                const key = self.allocator.dupe(u8, entry.key_ptr.*) catch return ContainerError.OutOfMemory;
                const val = self.allocator.dupe(u8, entry.value_ptr.*) catch return ContainerError.OutOfMemory;
                annotations.put(key, val) catch return ContainerError.OutOfMemory;
            }
        }

        // Build rootfs path
        const rootfs_path = std.fs.path.join(self.allocator, &.{
            self.base_path, "containers", container_id, "rootfs",
        }) catch return ContainerError.OutOfMemory;

        var container_state = store.Container{
            .id = container_id,
            .pod_sandbox_id = self.allocator.dupe(u8, pod_sandbox_id) catch return ContainerError.OutOfMemory,
            .name = self.allocator.dupe(u8, config.name) catch return ContainerError.OutOfMemory,
            .image = self.allocator.dupe(u8, config.image.image) catch return ContainerError.OutOfMemory,
            .image_ref = image_ref,
            .state = .created,
            .created_at = std.time.timestamp(),
            .started_at = 0,
            .finished_at = 0,
            .exit_code = 0,
            .pid = null,
            .unit_name = self.allocator.dupe(u8, unit_name) catch return ContainerError.OutOfMemory,
            .rootfs_path = rootfs_path,
            .log_path = if (config.log_path) |lp| self.allocator.dupe(u8, lp) catch return ContainerError.OutOfMemory else null,
            .labels = labels,
            .annotations = annotations,
        };

        // Save container state
        self.state_store.saveContainer(&container_state) catch {
            return ContainerError.StoreError;
        };

        return self.allocator.dupe(u8, container_id) catch return ContainerError.OutOfMemory;
    }

    /// Start a created container
    pub fn startContainer(self: *Self, container_id: []const u8) ContainerError!void {
        logging.info("Starting container: {s}", .{container_id});

        // Load container state
        var container = self.state_store.loadContainer(container_id) catch return ContainerError.NotFound;
        defer container.deinit(self.allocator);

        if (container.state != .created) {
            return ContainerError.InvalidState;
        }

        // Create null-terminated unit name
        const unit_name_z = self.allocator.dupeZ(u8, container.unit_name) catch return ContainerError.OutOfMemory;
        defer self.allocator.free(unit_name_z);

        // Start a transient scope for the container
        // In a full implementation, this would:
        // 1. Fork a process
        // 2. Set up namespaces, cgroups, etc.
        // 3. Exec the container command
        // For now, we'll use a simple sleep command as a placeholder
        const job_path = self.systemd_manager.startTransientService(
            unit_name_z,
            "fail",
            &configureContainerScope,
        ) catch {
            logging.err("Failed to start container unit {s}", .{container.unit_name});
            return ContainerError.SystemdError;
        };
        defer self.allocator.free(job_path);

        // Update container state
        container.state = .running;
        container.started_at = std.time.timestamp();

        // Re-save with updated state
        var updated = store.Container{
            .id = self.allocator.dupe(u8, container.id) catch return ContainerError.OutOfMemory,
            .pod_sandbox_id = self.allocator.dupe(u8, container.pod_sandbox_id) catch return ContainerError.OutOfMemory,
            .name = self.allocator.dupe(u8, container.name) catch return ContainerError.OutOfMemory,
            .image = self.allocator.dupe(u8, container.image) catch return ContainerError.OutOfMemory,
            .image_ref = self.allocator.dupe(u8, container.image_ref) catch return ContainerError.OutOfMemory,
            .state = .running,
            .created_at = container.created_at,
            .started_at = std.time.timestamp(),
            .finished_at = 0,
            .exit_code = 0,
            .pid = container.pid,
            .unit_name = self.allocator.dupe(u8, container.unit_name) catch return ContainerError.OutOfMemory,
            .rootfs_path = if (container.rootfs_path) |p| self.allocator.dupe(u8, p) catch return ContainerError.OutOfMemory else null,
            .log_path = if (container.log_path) |p| self.allocator.dupe(u8, p) catch return ContainerError.OutOfMemory else null,
            .labels = std.StringHashMap([]const u8).init(self.allocator),
            .annotations = std.StringHashMap([]const u8).init(self.allocator),
        };
        defer updated.deinit(self.allocator);

        self.state_store.saveContainer(&updated) catch return ContainerError.StoreError;
    }

    /// Stop a running container
    pub fn stopContainer(self: *Self, container_id: []const u8, timeout: i64) ContainerError!void {
        _ = timeout;
        logging.info("Stopping container: {s}", .{container_id});

        var container = self.state_store.loadContainer(container_id) catch return ContainerError.NotFound;
        defer container.deinit(self.allocator);

        if (container.state != .running) {
            return; // Already stopped
        }

        const unit_name_z = self.allocator.dupeZ(u8, container.unit_name) catch return ContainerError.OutOfMemory;
        defer self.allocator.free(unit_name_z);

        _ = self.systemd_manager.stopUnitRaw(unit_name_z, "fail") catch |err| {
            logging.warn("Failed to stop container unit: {}", .{err});
        };

        // Update state
        var updated = store.Container{
            .id = self.allocator.dupe(u8, container.id) catch return ContainerError.OutOfMemory,
            .pod_sandbox_id = self.allocator.dupe(u8, container.pod_sandbox_id) catch return ContainerError.OutOfMemory,
            .name = self.allocator.dupe(u8, container.name) catch return ContainerError.OutOfMemory,
            .image = self.allocator.dupe(u8, container.image) catch return ContainerError.OutOfMemory,
            .image_ref = self.allocator.dupe(u8, container.image_ref) catch return ContainerError.OutOfMemory,
            .state = .exited,
            .created_at = container.created_at,
            .started_at = container.started_at,
            .finished_at = std.time.timestamp(),
            .exit_code = 0,
            .pid = null,
            .unit_name = self.allocator.dupe(u8, container.unit_name) catch return ContainerError.OutOfMemory,
            .rootfs_path = if (container.rootfs_path) |p| self.allocator.dupe(u8, p) catch return ContainerError.OutOfMemory else null,
            .log_path = if (container.log_path) |p| self.allocator.dupe(u8, p) catch return ContainerError.OutOfMemory else null,
            .labels = std.StringHashMap([]const u8).init(self.allocator),
            .annotations = std.StringHashMap([]const u8).init(self.allocator),
        };
        defer updated.deinit(self.allocator);

        self.state_store.saveContainer(&updated) catch return ContainerError.StoreError;
    }

    /// Remove a container
    pub fn removeContainer(self: *Self, container_id: []const u8) ContainerError!void {
        logging.info("Removing container: {s}", .{container_id});

        var container = self.state_store.loadContainer(container_id) catch return ContainerError.NotFound;
        defer container.deinit(self.allocator);

        // Stop if running
        if (container.state == .running) {
            self.stopContainer(container_id, 10) catch {};
        }

        // Reset failed unit if needed
        const unit_name_z = self.allocator.dupeZ(u8, container.unit_name) catch return ContainerError.OutOfMemory;
        defer self.allocator.free(unit_name_z);
        self.systemd_manager.resetFailedUnit(unit_name_z) catch {};

        // Clean up rootfs
        if (container.rootfs_path) |rootfs_path| {
            const container_dir = std.fs.path.dirname(rootfs_path) orelse rootfs_path;
            std.fs.deleteTreeAbsolute(container_dir) catch {};
        }

        // Delete from store
        self.state_store.deleteContainer(container_id) catch return ContainerError.StoreError;
    }

    /// Get container status
    pub fn containerStatus(self: *Self, container_id: []const u8) ContainerError!store.Container {
        var container = self.state_store.loadContainer(container_id) catch return ContainerError.NotFound;

        // Update state from systemd if running
        if (container.state == .running) {
            const unit_name_z = self.allocator.dupeZ(u8, container.unit_name) catch return ContainerError.OutOfMemory;
            defer self.allocator.free(unit_name_z);

            if (self.systemd_manager.getUnit(unit_name_z)) |unit_path| {
                defer self.allocator.free(unit_path);
                const unit_path_z = self.allocator.dupeZ(u8, unit_path) catch return ContainerError.OutOfMemory;
                defer self.allocator.free(unit_path_z);

                const active_state = self.systemd_manager.getUnitActiveState(unit_path_z) catch .unknown;
                if (active_state == .inactive or active_state == .failed) {
                    container.state = .exited;
                    container.finished_at = std.time.timestamp();
                }
            } else |_| {
                container.state = .exited;
                container.finished_at = std.time.timestamp();
            }
        }

        return container;
    }

    /// List containers
    pub fn listContainers(self: *Self, filter: ?ContainerFilter) ContainerError!std.ArrayList(store.Container) {
        var results: std.ArrayList(store.Container) = .empty;
        errdefer {
            for (results.items) |*cont| {
                cont.deinit(self.allocator);
            }
            results.deinit(self.allocator);
        }

        var container_ids = self.state_store.listContainers() catch return ContainerError.StoreError;
        defer {
            for (container_ids.items) |id| {
                self.allocator.free(id);
            }
            container_ids.deinit(self.allocator);
        }

        for (container_ids.items) |id| {
            var container = self.state_store.loadContainer(id) catch continue;

            // Apply filter
            if (filter) |f| {
                if (f.id) |filter_id| {
                    if (!std.mem.eql(u8, container.id, filter_id)) {
                        container.deinit(self.allocator);
                        continue;
                    }
                }
                if (f.pod_sandbox_id) |pod_id| {
                    if (!std.mem.eql(u8, container.pod_sandbox_id, pod_id)) {
                        container.deinit(self.allocator);
                        continue;
                    }
                }
                if (f.state) |state| {
                    if (container.state != state) {
                        container.deinit(self.allocator);
                        continue;
                    }
                }
            }

            results.append(self.allocator, container) catch return ContainerError.OutOfMemory;
        }

        return results;
    }
};

/// Container filter for listing
pub const ContainerFilter = struct {
    id: ?[]const u8 = null,
    pod_sandbox_id: ?[]const u8 = null,
    state: ?store.ContainerState = null,
    label_selector: ?std.StringHashMap([]const u8) = null,
};

/// Configure container scope properties
fn configureContainerScope(builder: *properties.PropertyBuilder) anyerror!void {
    try properties.PodServiceProperties.setDescription(builder, "CRI Container");
    try properties.PodServiceProperties.setSlice(builder, "system.slice");
    try properties.PodServiceProperties.setType(builder, "exec");

    // Placeholder command - in real implementation this would exec the container process
    const argv = [_][*:0]const u8{ "/bin/sleep", "3600" };
    try builder.addExecStart("/bin/sleep", &argv, false);
}
