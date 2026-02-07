const std = @import("std");
const mount = @import("mount.zig");

pub const OverlayError = error{
    CreateFailed,
    MountFailed,
    UnmountFailed,
    InvalidPath,
    OutOfMemory,
};

/// Configuration for an overlay filesystem
pub const OverlayConfig = struct {
    /// Lower directories (read-only layers, bottom to top)
    lower_dirs: []const []const u8,
    /// Upper directory (writable layer)
    upper_dir: []const u8,
    /// Work directory (required by overlayfs)
    work_dir: []const u8,
    /// Merged directory (mount point)
    merged_dir: []const u8,
};

/// Overlay filesystem manager
pub const Overlay = struct {
    allocator: std.mem.Allocator,
    config: OverlayConfig,
    mounted: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: OverlayConfig) Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .mounted = false,
        };
    }

    /// Create the directory structure for the overlay
    pub fn prepare(self: *Self) OverlayError!void {
        // Create upper, work, and merged directories
        const dirs = [_][]const u8{
            self.config.upper_dir,
            self.config.work_dir,
            self.config.merged_dir,
        };

        for (dirs) |dir| {
            std.fs.makeDirAbsolute(dir) catch |e| {
                if (e != error.PathAlreadyExists) {
                    return OverlayError.CreateFailed;
                }
            };
        }
    }

    /// Mount the overlay filesystem
    pub fn mountOverlay(self: *Self) OverlayError!void {
        if (self.mounted) return;

        // Build the mount options string
        // Format: lowerdir=dir1:dir2:...,upperdir=...,workdir=...
        var options_list: std.ArrayList(u8) = .empty;
        defer options_list.deinit(self.allocator);

        const w = options_list.writer(self.allocator);

        // Lower dirs (colon-separated, first is bottom)
        w.writeAll("lowerdir=") catch return OverlayError.OutOfMemory;
        for (self.config.lower_dirs, 0..) |dir, i| {
            if (i > 0) w.writeAll(":") catch return OverlayError.OutOfMemory;
            w.writeAll(dir) catch return OverlayError.OutOfMemory;
        }

        w.print(",upperdir={s},workdir={s}", .{
            self.config.upper_dir,
            self.config.work_dir,
        }) catch return OverlayError.OutOfMemory;

        // Null-terminate for C
        options_list.append(self.allocator, 0) catch return OverlayError.OutOfMemory;

        const options_z: [*:0]const u8 = @ptrCast(options_list.items.ptr);
        const merged_z = self.allocator.dupeZ(u8, self.config.merged_dir) catch return OverlayError.OutOfMemory;
        defer self.allocator.free(merged_z);

        mount.mount("overlay", merged_z, "overlay", .{}, options_z) catch {
            return OverlayError.MountFailed;
        };

        self.mounted = true;
    }

    /// Unmount the overlay filesystem
    pub fn unmount(self: *Self) OverlayError!void {
        if (!self.mounted) return;

        const merged_z = self.allocator.dupeZ(u8, self.config.merged_dir) catch return OverlayError.OutOfMemory;
        defer self.allocator.free(merged_z);

        mount.umount(merged_z) catch {
            // Try lazy unmount as fallback
            mount.umountLazy(merged_z) catch {
                return OverlayError.UnmountFailed;
            };
        };

        self.mounted = false;
    }

    /// Clean up the overlay directories
    pub fn cleanup(self: *Self) void {
        if (self.mounted) {
            self.unmount() catch {};
        }

        // Remove directories in reverse order
        std.fs.deleteTreeAbsolute(self.config.merged_dir) catch {};
        std.fs.deleteTreeAbsolute(self.config.work_dir) catch {};
        std.fs.deleteTreeAbsolute(self.config.upper_dir) catch {};
    }
};

/// Create a container rootfs using overlayfs
pub const ContainerRootfs = struct {
    allocator: std.mem.Allocator,
    base_path: []const u8,
    container_id: []const u8,
    overlay: ?Overlay,

    // Paths
    upper_path: []const u8,
    work_path: []const u8,
    merged_path: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, base_path: []const u8, container_id: []const u8) !Self {
        const container_path = try std.fs.path.join(allocator, &.{ base_path, "containers", container_id });
        errdefer allocator.free(container_path);

        const upper_path = try std.fs.path.join(allocator, &.{ container_path, "upper" });
        errdefer allocator.free(upper_path);

        const work_path = try std.fs.path.join(allocator, &.{ container_path, "work" });
        errdefer allocator.free(work_path);

        const merged_path = try std.fs.path.join(allocator, &.{ container_path, "rootfs" });
        errdefer allocator.free(merged_path);

        // Create base container directory
        std.fs.makeDirAbsolute(container_path) catch |e| {
            if (e != error.PathAlreadyExists) return e;
        };

        allocator.free(container_path);

        return Self{
            .allocator = allocator,
            .base_path = try allocator.dupe(u8, base_path),
            .container_id = try allocator.dupe(u8, container_id),
            .overlay = null,
            .upper_path = upper_path,
            .work_path = work_path,
            .merged_path = merged_path,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.overlay) |*overlay| {
            overlay.unmount() catch {};
        }
        self.allocator.free(self.base_path);
        self.allocator.free(self.container_id);
        self.allocator.free(self.upper_path);
        self.allocator.free(self.work_path);
        self.allocator.free(self.merged_path);
    }

    /// Setup the rootfs with given image layers
    pub fn setup(self: *Self, image_layers: []const []const u8) !void {
        self.overlay = Overlay.init(self.allocator, .{
            .lower_dirs = image_layers,
            .upper_dir = self.upper_path,
            .work_dir = self.work_path,
            .merged_dir = self.merged_path,
        });

        try self.overlay.?.prepare();
        try self.overlay.?.mountOverlay();
    }

    /// Get the path to the merged rootfs
    pub fn getRootfsPath(self: *const Self) []const u8 {
        return self.merged_path;
    }

    /// Cleanup the rootfs
    pub fn cleanup(self: *Self) void {
        if (self.overlay) |*overlay| {
            overlay.cleanup();
            self.overlay = null;
        }
    }
};

/// Default paths
pub const DEFAULT_BASE_PATH = "/var/lib/systemd-cri";

test "OverlayConfig" {
    const config = OverlayConfig{
        .lower_dirs = &.{ "/layer1", "/layer2" },
        .upper_dir = "/upper",
        .work_dir = "/work",
        .merged_dir = "/merged",
    };
    try std.testing.expectEqual(@as(usize, 2), config.lower_dirs.len);
}
