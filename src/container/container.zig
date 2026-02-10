const std = @import("std");
const dbus = @import("../systemd/dbus.zig");
const manager = @import("../systemd/manager.zig");
const properties = @import("../systemd/properties.zig");
const store = @import("../state/store.zig");
const overlay = @import("../rootfs/overlay.zig");
const mount = @import("../rootfs/mount.zig");
const image_store = @import("../image/store.zig");
const uuid = @import("../util/uuid.zig");
const logging = @import("../util/logging.zig");
const c = dbus.raw;

/// Default path where machined stores images
const MACHINES_PATH = "/var/lib/machines";

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

/// Generate a machine name from an image reference
/// Machine names must be valid hostnames (alphanumeric, hyphens, max 64 chars)
fn generateMachineName(allocator: std.mem.Allocator, image_ref: []const u8) ![]const u8 {
    var ref = image_store.ImageReference.parse(allocator, image_ref) catch return error.OutOfMemory;
    defer ref.deinit(allocator);

    var name_buf: std.ArrayList(u8) = .empty;
    errdefer name_buf.deinit(allocator);

    // Use repository name, replacing invalid chars
    for (ref.repository) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            name_buf.append(allocator, std.ascii.toLower(char)) catch return error.OutOfMemory;
        } else if (char == '/' or char == '_' or char == '.') {
            name_buf.append(allocator, '-') catch return error.OutOfMemory;
        }
    }

    // Add tag if not 'latest'
    if (ref.tag) |tag| {
        if (!std.mem.eql(u8, tag, "latest")) {
            name_buf.append(allocator, '-') catch return error.OutOfMemory;
            for (tag) |char| {
                if (std.ascii.isAlphanumeric(char)) {
                    name_buf.append(allocator, std.ascii.toLower(char)) catch return error.OutOfMemory;
                } else if (char == '.' or char == '_') {
                    name_buf.append(allocator, '-') catch return error.OutOfMemory;
                }
            }
        }
    }

    var result = name_buf.toOwnedSlice(allocator) catch return error.OutOfMemory;

    // Truncate to 64 chars max
    if (result.len > 64) {
        const truncated = allocator.dupe(u8, result[0..64]) catch {
            allocator.free(result);
            return error.OutOfMemory;
        };
        allocator.free(result);
        result = truncated;
    }

    return result;
}

/// Get the image rootfs path for a given image reference
fn getImageRootfsPath(allocator: std.mem.Allocator, image_ref: []const u8) ![]const u8 {
    const machine_name = try generateMachineName(allocator, image_ref);
    defer allocator.free(machine_name);

    return std.fs.path.join(allocator, &.{ MACHINES_PATH, machine_name });
}

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

        // Store the image reference
        const image_ref = self.allocator.dupe(u8, config.image.image) catch return ContainerError.OutOfMemory;

        // Get the image rootfs path from machined
        const image_rootfs: ?[]const u8 = getImageRootfsPath(self.allocator, config.image.image) catch |err| blk: {
            logging.debug("Image rootfs not found in machined: {}, will use host filesystem", .{err});
            break :blk null;
        };
        errdefer if (image_rootfs) |p| self.allocator.free(p);

        // Create container directory structure (with parent directories)
        const container_dir = std.fs.path.join(self.allocator, &.{
            self.base_path, "containers", container_id,
        }) catch return ContainerError.OutOfMemory;
        defer self.allocator.free(container_dir);

        // First ensure the containers directory exists
        const containers_dir = std.fs.path.join(self.allocator, &.{
            self.base_path, "containers",
        }) catch return ContainerError.OutOfMemory;
        defer self.allocator.free(containers_dir);

        std.fs.makeDirAbsolute(containers_dir) catch |e| {
            if (e != error.PathAlreadyExists) {
                logging.err("Failed to create containers directory: {}", .{e});
                return ContainerError.CreateFailed;
            }
        };

        std.fs.makeDirAbsolute(container_dir) catch |e| {
            if (e != error.PathAlreadyExists) {
                logging.err("Failed to create container directory: {}", .{e});
                return ContainerError.CreateFailed;
            }
        };

        // Create overlay directories (upper, work, rootfs)
        const dirs = [_][]const u8{ "upper", "work", "rootfs" };
        for (dirs) |subdir| {
            const dir_path = std.fs.path.join(self.allocator, &.{ container_dir, subdir }) catch return ContainerError.OutOfMemory;
            defer self.allocator.free(dir_path);
            std.fs.makeDirAbsolute(dir_path) catch |e| {
                if (e != error.PathAlreadyExists) {
                    logging.err("Failed to create {s} directory: {}", .{ subdir, e });
                    return ContainerError.CreateFailed;
                }
            };
        }

        // Build rootfs path (merged overlay mount point)
        const rootfs_path = std.fs.path.join(self.allocator, &.{
            self.base_path, "containers", container_id, "rootfs",
        }) catch return ContainerError.OutOfMemory;

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

        // Build command string from command and args
        var command_str: ?[]const u8 = null;
        if (config.command) |cmd| {
            var cmd_parts: std.ArrayList(u8) = .empty;
            errdefer cmd_parts.deinit(self.allocator);

            for (cmd, 0..) |part, i| {
                if (i > 0) cmd_parts.append(self.allocator, ' ') catch return ContainerError.OutOfMemory;
                cmd_parts.appendSlice(self.allocator, part) catch return ContainerError.OutOfMemory;
            }
            if (config.args) |args| {
                for (args) |arg| {
                    cmd_parts.append(self.allocator, ' ') catch return ContainerError.OutOfMemory;
                    cmd_parts.appendSlice(self.allocator, arg) catch return ContainerError.OutOfMemory;
                }
            }
            command_str = cmd_parts.toOwnedSlice(self.allocator) catch return ContainerError.OutOfMemory;
        }

        // Extract security context from linux config
        var run_as_user: ?i64 = null;
        var run_as_group: ?i64 = null;
        var privileged: bool = false;
        var readonly_rootfs: bool = false;

        if (config.linux) |linux_config| {
            if (linux_config.security_context) |sec_ctx| {
                run_as_user = sec_ctx.run_as_user;
                run_as_group = sec_ctx.run_as_group;
                privileged = sec_ctx.privileged;
                readonly_rootfs = sec_ctx.readonly_rootfs;
            }
        }

        // Serialize mounts to JSON
        var mounts_json: ?[]const u8 = null;
        if (config.mounts) |mounts| {
            if (mounts.len > 0) {
                mounts_json = serializeMounts(self.allocator, mounts) catch return ContainerError.OutOfMemory;
            }
        }

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
            .command = command_str,
            .working_dir = if (config.working_dir) |wd| self.allocator.dupe(u8, wd) catch return ContainerError.OutOfMemory else null,
            .labels = labels,
            .annotations = annotations,
            .run_as_user = run_as_user,
            .run_as_group = run_as_group,
            .privileged = privileged,
            .readonly_rootfs = readonly_rootfs,
            .image_rootfs = image_rootfs,
            .mounts_json = mounts_json,
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

        // Try to mount overlay filesystem if we have image_rootfs
        var overlay_mounted = false;
        if (container.image_rootfs) |image_rootfs| {
            if (container.rootfs_path) |rootfs_path| {
                // Build overlay paths
                const container_dir = std.fs.path.join(self.allocator, &.{
                    self.base_path, "containers", container_id,
                }) catch return ContainerError.OutOfMemory;
                defer self.allocator.free(container_dir);

                const upper_path = std.fs.path.join(self.allocator, &.{ container_dir, "upper" }) catch return ContainerError.OutOfMemory;
                defer self.allocator.free(upper_path);

                const work_path = std.fs.path.join(self.allocator, &.{ container_dir, "work" }) catch return ContainerError.OutOfMemory;
                defer self.allocator.free(work_path);

                // Check if image rootfs exists and has valid content (at least /bin or /usr exists)
                const rootfs_valid = blk: {
                    var dir = std.fs.openDirAbsolute(image_rootfs, .{}) catch break :blk false;
                    defer dir.close();

                    // Check for common binary directories that indicate a valid rootfs
                    var bin_check = dir.openDir("bin", .{}) catch {
                        var usr_check = dir.openDir("usr", .{}) catch break :blk false;
                        usr_check.close();
                        break :blk true;
                    };
                    bin_check.close();
                    break :blk true;
                };
                const rootfs_exists = rootfs_valid;

                if (rootfs_exists) {
                    // Create overlay config
                    var overlay_fs = overlay.Overlay.init(self.allocator, .{
                        .lower_dirs = &.{image_rootfs},
                        .upper_dir = upper_path,
                        .work_dir = work_path,
                        .merged_dir = rootfs_path,
                    });

                    overlay_fs.prepare() catch |e| {
                        logging.warn("Failed to prepare overlay: {}", .{e});
                    };

                    overlay_fs.mountOverlay() catch |e| {
                        logging.warn("Failed to mount overlay: {}, continuing without isolation", .{e});
                    };

                    if (overlay_fs.mounted) {
                        overlay_mounted = true;
                        logging.info("Overlay mounted at {s}", .{rootfs_path});
                    }
                } else {
                    logging.debug("Image rootfs not found at {s}, continuing without isolation", .{image_rootfs});
                }
            }
        }

        // Log the command for debugging
        if (container.command) |cmd| {
            logging.debug("Container command: {s}", .{cmd});
        } else {
            logging.debug("Container has no command, will use fallback", .{});
        }

        // Build context for the service configuration
        const context = ContainerExecContext{
            .command = container.command,
            .working_dir = container.working_dir,
            .rootfs_path = container.rootfs_path,
            .log_path = container.log_path,
            .image_rootfs = container.image_rootfs,
            .overlay_mounted = overlay_mounted,
            .run_as_user = container.run_as_user,
            .run_as_group = container.run_as_group,
            .privileged = container.privileged,
            .readonly_rootfs = container.readonly_rootfs,
            .mounts_json = container.mounts_json,
        };

        // Start a transient service for the container
        const job_path = self.systemd_manager.startTransientServiceWithContext(
            unit_name_z,
            "fail",
            context,
            configureContainerService,
        ) catch {
            logging.err("Failed to start container unit {s}", .{container.unit_name});
            return ContainerError.SystemdError;
        };
        defer self.allocator.free(job_path);

        // Wait briefly for systemd to start the process, then get the PID
        std.Thread.sleep(50 * std.time.ns_per_ms);

        var main_pid: ?u32 = null;
        if (self.systemd_manager.getUnit(unit_name_z)) |unit_path| {
            defer self.allocator.free(unit_path);
            logging.info("Got unit path: {s}", .{unit_path});
            const unit_path_z = self.allocator.dupeZ(u8, unit_path) catch null;
            if (unit_path_z) |upz| {
                defer self.allocator.free(upz);
                main_pid = self.systemd_manager.getServiceMainPID(upz) catch |err| blk: {
                    logging.warn("Failed to get MainPID: {}", .{err});
                    break :blk null;
                };
                if (main_pid) |pid| {
                    logging.info("Got MainPID: {d}", .{pid});
                } else {
                    logging.warn("MainPID is null", .{});
                }
            }
        } else |err| {
            logging.warn("Failed to get unit: {}", .{err});
        }

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
            .pid = main_pid,
            .unit_name = self.allocator.dupe(u8, container.unit_name) catch return ContainerError.OutOfMemory,
            .rootfs_path = if (container.rootfs_path) |p| self.allocator.dupe(u8, p) catch return ContainerError.OutOfMemory else null,
            .image_rootfs = if (container.image_rootfs) |p| self.allocator.dupe(u8, p) catch return ContainerError.OutOfMemory else null,
            .log_path = if (container.log_path) |p| self.allocator.dupe(u8, p) catch return ContainerError.OutOfMemory else null,
            .command = if (container.command) |cmd| self.allocator.dupe(u8, cmd) catch return ContainerError.OutOfMemory else null,
            .working_dir = if (container.working_dir) |wd| self.allocator.dupe(u8, wd) catch return ContainerError.OutOfMemory else null,
            .labels = std.StringHashMap([]const u8).init(self.allocator),
            .annotations = std.StringHashMap([]const u8).init(self.allocator),
            .run_as_user = container.run_as_user,
            .run_as_group = container.run_as_group,
            .privileged = container.privileged,
            .readonly_rootfs = container.readonly_rootfs,
            .mounts_json = if (container.mounts_json) |m| self.allocator.dupe(u8, m) catch return ContainerError.OutOfMemory else null,
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

        // Unmount overlay if mounted
        if (container.rootfs_path) |rootfs_path| {
            const rootfs_z = self.allocator.dupeZ(u8, rootfs_path) catch return ContainerError.OutOfMemory;
            defer self.allocator.free(rootfs_z);
            mount.umountLazy(rootfs_z) catch |err| {
                logging.debug("Overlay unmount: {} (may already be unmounted)", .{err});
            };
        }

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
            .command = if (container.command) |cmd| self.allocator.dupe(u8, cmd) catch return ContainerError.OutOfMemory else null,
            .working_dir = if (container.working_dir) |wd| self.allocator.dupe(u8, wd) catch return ContainerError.OutOfMemory else null,
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

        // Clean up rootfs - unmount overlay first
        if (container.rootfs_path) |rootfs_path| {
            const rootfs_z = self.allocator.dupeZ(u8, rootfs_path) catch return ContainerError.OutOfMemory;
            defer self.allocator.free(rootfs_z);
            mount.umountLazy(rootfs_z) catch {};

            const container_dir = std.fs.path.dirname(rootfs_path) orelse rootfs_path;
            std.fs.deleteTreeAbsolute(container_dir) catch {};
        }

        // Delete from store
        self.state_store.deleteContainer(container_id) catch return ContainerError.StoreError;
    }

    /// Get container status
    pub fn containerStatus(self: *Self, container_id: []const u8) ContainerError!store.Container {
        var container = self.state_store.loadContainer(container_id) catch return ContainerError.NotFound;

        logging.info("containerStatus: id={s} stored_state={s}", .{ container_id, container.state.toString() });

        // Update state from systemd if running
        if (container.state == .running) {
            const unit_name_z = self.allocator.dupeZ(u8, container.unit_name) catch return ContainerError.OutOfMemory;
            defer self.allocator.free(unit_name_z);

            if (self.systemd_manager.getUnit(unit_name_z)) |unit_path| {
                defer self.allocator.free(unit_path);
                const unit_path_z = self.allocator.dupeZ(u8, unit_path) catch return ContainerError.OutOfMemory;
                defer self.allocator.free(unit_path_z);

                const active_state = self.systemd_manager.getUnitActiveState(unit_path_z) catch .unknown;
                logging.info("containerStatus: systemd active_state={any}", .{active_state});
                if (active_state == .inactive or active_state == .failed) {
                    container.state = .exited;
                    container.finished_at = std.time.timestamp();
                    logging.info("containerStatus: marking as exited (inactive/failed)", .{});
                } else if (container.pid == null) {
                    // Try to get PID if we don't have it
                    container.pid = self.systemd_manager.getServiceMainPID(unit_path_z) catch null;
                }
            } else |err| {
                container.state = .exited;
                container.finished_at = std.time.timestamp();
                logging.info("containerStatus: marking as exited (getUnit failed: {any})", .{err});
            }
        }

        logging.info("containerStatus: returning state={s}", .{container.state.toString()});
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

/// Serialize mounts to JSON for storage
fn serializeMounts(allocator: std.mem.Allocator, mounts: []const Mount) ![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    try buffer.append(allocator, '[');
    for (mounts, 0..) |mnt, i| {
        if (i > 0) try buffer.append(allocator, ',');
        try buffer.appendSlice(allocator, "{\"container_path\":\"");
        try buffer.appendSlice(allocator, mnt.container_path);
        try buffer.appendSlice(allocator, "\",\"host_path\":\"");
        try buffer.appendSlice(allocator, mnt.host_path);
        try buffer.appendSlice(allocator, "\",\"readonly\":");
        try buffer.appendSlice(allocator, if (mnt.readonly) "true" else "false");
        try buffer.appendSlice(allocator, ",\"propagation\":\"");
        try buffer.appendSlice(allocator, switch (mnt.propagation) {
            .private => "private",
            .host_to_container => "host_to_container",
            .bidirectional => "bidirectional",
        });
        try buffer.appendSlice(allocator, "\"}");
    }
    try buffer.append(allocator, ']');

    return buffer.toOwnedSlice(allocator);
}

/// Deserialize mounts from JSON
pub fn deserializeMounts(allocator: std.mem.Allocator, mounts_json: []const u8) ![]Mount {
    var mounts: std.ArrayList(Mount) = .empty;
    errdefer mounts.deinit(allocator);

    // Parse JSON array of mount objects
    // Format: [{"container_path":"...","host_path":"...","readonly":bool,"propagation":"..."}]
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, mounts_json, .{}) catch {
        return &.{};
    };
    defer parsed.deinit();

    if (parsed.value != .array) {
        return &.{};
    }

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;

        const container_path = if (item.object.get("container_path")) |v| blk: {
            if (v == .string) break :blk try allocator.dupe(u8, v.string);
            break :blk null;
        } else null;

        const host_path = if (item.object.get("host_path")) |v| blk: {
            if (v == .string) break :blk try allocator.dupe(u8, v.string);
            break :blk null;
        } else null;

        if (container_path == null or host_path == null) {
            if (container_path) |cp| allocator.free(cp);
            if (host_path) |hp| allocator.free(hp);
            continue;
        }

        const readonly = if (item.object.get("readonly")) |v| v == .bool and v.bool else false;

        const propagation: MountPropagation = if (item.object.get("propagation")) |v| blk: {
            if (v == .string) {
                if (std.mem.eql(u8, v.string, "bidirectional")) break :blk .bidirectional;
                if (std.mem.eql(u8, v.string, "host_to_container")) break :blk .host_to_container;
            }
            break :blk .private;
        } else .private;

        try mounts.append(allocator, Mount{
            .container_path = container_path.?,
            .host_path = host_path.?,
            .readonly = readonly,
            .propagation = propagation,
        });
    }

    return mounts.toOwnedSlice(allocator);
}

/// Container filter for listing
pub const ContainerFilter = struct {
    id: ?[]const u8 = null,
    pod_sandbox_id: ?[]const u8 = null,
    state: ?store.ContainerState = null,
    label_selector: ?std.StringHashMap([]const u8) = null,
};

/// Context for container execution
const ContainerExecContext = struct {
    command: ?[]const u8,
    working_dir: ?[]const u8,
    rootfs_path: ?[]const u8,
    log_path: ?[]const u8,
    // Image rootfs (lower layer for overlay)
    image_rootfs: ?[]const u8 = null,
    // Whether overlay is mounted
    overlay_mounted: bool = false,
    // Security context
    run_as_user: ?i64 = null,
    run_as_group: ?i64 = null,
    privileged: bool = false,
    readonly_rootfs: bool = false,
    // Mounts JSON
    mounts_json: ?[]const u8 = null,
};

/// Thread-local storage for command arguments (to avoid allocations in callback)
threadlocal var exec_argv_buf: [64][*:0]const u8 = undefined;
threadlocal var exec_path_buf: [4096]u8 = undefined;
threadlocal var exec_arg_bufs: [64][256]u8 = undefined;
threadlocal var exec_log_buf: [4096]u8 = undefined;
threadlocal var exec_rootfs_buf: [4096]u8 = undefined;
threadlocal var exec_bind_bufs: [16][512]u8 = undefined;
threadlocal var exec_bind_ptrs: [16][*:0]const u8 = undefined;
threadlocal var exec_env_ptrs: [8][*:0]const u8 = undefined;
threadlocal var exec_user_buf: [32]u8 = undefined;
threadlocal var exec_group_buf: [32]u8 = undefined;

/// Configure container service properties with context
fn configureContainerService(builder: *properties.PropertyBuilder, context: ContainerExecContext) anyerror!void {
    try properties.PodServiceProperties.setDescription(builder, "CRI Container");
    try properties.PodServiceProperties.setSlice(builder, "system.slice");
    try properties.PodServiceProperties.setType(builder, "exec");

    // Set working directory if specified
    if (context.working_dir) |wd| {
        // Copy to null-terminated buffer
        if (wd.len < exec_path_buf.len - 1) {
            @memcpy(exec_path_buf[0..wd.len], wd);
            exec_path_buf[wd.len] = 0;
            try builder.addString("WorkingDirectory", exec_path_buf[0..wd.len :0]);
        }
    }

    // Configure logging to file if log_path is specified
    if (context.log_path) |lp| {
        // Format: file:/path/to/log
        const prefix = "file:";
        if (prefix.len + lp.len < exec_log_buf.len - 1) {
            @memcpy(exec_log_buf[0..prefix.len], prefix);
            @memcpy(exec_log_buf[prefix.len..][0..lp.len], lp);
            exec_log_buf[prefix.len + lp.len] = 0;
            const log_spec = exec_log_buf[0 .. prefix.len + lp.len :0];
            try builder.addString("StandardOutput", log_spec);
            try builder.addString("StandardError", log_spec);
        }
    }

    // Apply security context
    if (!context.privileged) {
        // Non-privileged containers get security hardening
        try builder.addBool("NoNewPrivileges", true);

        // Set user/group if specified (as string representations of UID/GID)
        if (context.run_as_user) |uid| {
            const uid_str = std.fmt.bufPrint(&exec_user_buf, "{d}", .{uid}) catch "0";
            exec_user_buf[uid_str.len] = 0;
            try builder.addString("User", exec_user_buf[0..uid_str.len :0]);
        }
        if (context.run_as_group) |gid| {
            const gid_str = std.fmt.bufPrint(&exec_group_buf, "{d}", .{gid}) catch "0";
            exec_group_buf[gid_str.len] = 0;
            try builder.addString("Group", exec_group_buf[0..gid_str.len :0]);
        }

        // Readonly rootfs protection (ProtectSystem takes string: "true", "full", or "strict")
        if (context.readonly_rootfs) {
            try builder.addString("ProtectSystem", "strict");
        }
    }

    // Enable container isolation when overlay is mounted
    if (context.overlay_mounted) {
        if (context.rootfs_path) |rootfs| {
            // Set RootDirectory to chroot into the container rootfs
            if (rootfs.len < exec_rootfs_buf.len - 1) {
                @memcpy(exec_rootfs_buf[0..rootfs.len], rootfs);
                exec_rootfs_buf[rootfs.len] = 0;
                try builder.addString("RootDirectory", exec_rootfs_buf[0..rootfs.len :0]);
            }

            // Set PATH for command resolution inside container
            exec_env_ptrs[0] = "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
            try builder.addEnvironment(exec_env_ptrs[0..1]);

            // Enable namespace isolation
            try builder.addBool("PrivateMounts", true);
            try builder.addBool("MountAPIVFS", true); // Mount /proc, /sys, /dev automatically
            try builder.addBool("PrivateTmp", true);

            // Enable private devices for non-privileged containers
            if (!context.privileged) {
                try builder.addBool("PrivateDevices", true);
            }
        }
    }

    // Set up BindPaths for volume mounts when overlay is mounted
    if (context.overlay_mounted) {
        if (context.mounts_json) |mounts_json| {
            // Parse mounts JSON and set BindPaths
            // Format is a JSON array of {container_path, host_path, readonly}
            var bind_count: usize = 0;
            var readonly_count: usize = 0;

            // Simple JSON parsing for mounts array
            var mount_iter = std.mem.splitSequence(u8, mounts_json, "},{");
            while (mount_iter.next()) |mount_entry| {
                // Extract host_path and container_path from JSON
                var host_path: ?[]const u8 = null;
                var container_path: ?[]const u8 = null;
                var readonly = false;

                // Parse host_path
                if (std.mem.indexOf(u8, mount_entry, "\"host_path\":\"")) |start| {
                    const path_start = start + 13;
                    if (std.mem.indexOfPos(u8, mount_entry, path_start, "\"")) |end| {
                        host_path = mount_entry[path_start..end];
                    }
                }

                // Parse container_path
                if (std.mem.indexOf(u8, mount_entry, "\"container_path\":\"")) |start| {
                    const path_start = start + 18;
                    if (std.mem.indexOfPos(u8, mount_entry, path_start, "\"")) |end| {
                        container_path = mount_entry[path_start..end];
                    }
                }

                // Parse readonly
                if (std.mem.indexOf(u8, mount_entry, "\"readonly\":true") != null) {
                    readonly = true;
                }

                if (host_path != null and container_path != null) {
                    // Format: host_path:container_path (for BindPaths or BindReadOnlyPaths)
                    const hp = host_path.?;
                    const cp = container_path.?;

                    if (readonly) {
                        if (readonly_count < exec_bind_bufs.len / 2) {
                            const idx = readonly_count + 8; // Use second half of buffers
                            if (hp.len + cp.len + 1 < exec_bind_bufs[idx].len - 1) {
                                var pos: usize = 0;
                                @memcpy(exec_bind_bufs[idx][pos..][0..hp.len], hp);
                                pos += hp.len;
                                exec_bind_bufs[idx][pos] = ':';
                                pos += 1;
                                @memcpy(exec_bind_bufs[idx][pos..][0..cp.len], cp);
                                pos += cp.len;
                                exec_bind_bufs[idx][pos] = 0;
                                exec_bind_ptrs[idx] = exec_bind_bufs[idx][0..pos :0];
                                readonly_count += 1;
                            }
                        }
                    } else {
                        if (bind_count < 8) {
                            if (hp.len + cp.len + 1 < exec_bind_bufs[bind_count].len - 1) {
                                var pos: usize = 0;
                                @memcpy(exec_bind_bufs[bind_count][pos..][0..hp.len], hp);
                                pos += hp.len;
                                exec_bind_bufs[bind_count][pos] = ':';
                                pos += 1;
                                @memcpy(exec_bind_bufs[bind_count][pos..][0..cp.len], cp);
                                pos += cp.len;
                                exec_bind_bufs[bind_count][pos] = 0;
                                exec_bind_ptrs[bind_count] = exec_bind_bufs[bind_count][0..pos :0];
                                bind_count += 1;
                            }
                        }
                    }
                }
            }

            if (bind_count > 0) {
                try builder.addStringArray("BindPaths", exec_bind_ptrs[0..bind_count]);
            }
            if (readonly_count > 0) {
                try builder.addStringArray("BindReadOnlyPaths", exec_bind_ptrs[8..][0..readonly_count]);
            }
        }
    } else {
        _ = exec_bind_bufs;
        _ = exec_bind_ptrs;
    }

    // Parse and set the command
    if (context.command) |cmd| {
        // When overlay is mounted (container isolation), wrap command in shell
        // so PATH can be resolved properly within the container
        if (context.overlay_mounted) {
            // Wrap the entire command in /bin/sh -c "exec <cmd>"
            // This allows the shell to resolve PATH for commands like "top" or "sleep"
            const prefix = "exec ";
            if (prefix.len + cmd.len < exec_arg_bufs[0].len - 1) {
                @memcpy(exec_arg_bufs[0][0..prefix.len], prefix);
                @memcpy(exec_arg_bufs[0][prefix.len..][0..cmd.len], cmd);
                exec_arg_bufs[0][prefix.len + cmd.len] = 0;
                const wrapped_cmd = exec_arg_bufs[0][0 .. prefix.len + cmd.len :0];

                const argv = [_][*:0]const u8{ "/bin/sh", "-c", wrapped_cmd };
                try builder.addExecStart("/bin/sh", &argv, false);
                return;
            }
        }

        // Without overlay isolation, use command directly
        var argv_count: usize = 0;
        var iter = std.mem.splitScalar(u8, cmd, ' ');
        while (iter.next()) |arg| {
            if (arg.len == 0) continue;
            if (argv_count >= exec_arg_bufs.len) break;

            // Copy arg to null-terminated buffer
            if (arg.len < exec_arg_bufs[argv_count].len - 1) {
                @memcpy(exec_arg_bufs[argv_count][0..arg.len], arg);
                exec_arg_bufs[argv_count][arg.len] = 0;
                exec_argv_buf[argv_count] = exec_arg_bufs[argv_count][0..arg.len :0];
                argv_count += 1;
            }
        }

        if (argv_count > 0) {
            const path = exec_argv_buf[0];
            try builder.addExecStart(path, exec_argv_buf[0..argv_count], false);
            return;
        }
    }

    // Fallback to sleep if no command specified
    // Use /bin/sh -c for better portability across container images
    if (context.overlay_mounted) {
        const argv = [_][*:0]const u8{ "/bin/sh", "-c", "exec sleep 3600" };
        try builder.addExecStart("/bin/sh", &argv, false);
    } else {
        const argv = [_][*:0]const u8{ "/bin/sleep", "3600" };
        try builder.addExecStart("/bin/sleep", &argv, false);
    }
}
