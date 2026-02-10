const std = @import("std");
const store = @import("store.zig");
const machined = @import("machined.zig");
const dbus = @import("../systemd/dbus.zig");
const logging = @import("../util/logging.zig");

pub const PullError = error{
    SkopeoNotFound,
    UmociNotFound,
    PullFailed,
    ExtractFailed,
    InvalidImage,
    AuthFailed,
    NetworkError,
    OutOfMemory,
    ImportFailed,
};

/// Image puller using skopeo, umoci, and systemd-machined
pub const ImagePuller = struct {
    allocator: std.mem.Allocator,
    image_store: *store.ImageStore,
    machined_manager: ?machined.MachineImageManager,
    skopeo_path: []const u8,
    umoci_path: []const u8,
    temp_dir: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, image_store: *store.ImageStore, bus: ?*dbus.Bus) !Self {
        // Find skopeo and umoci binaries
        const skopeo_path = findExecutable(allocator, "skopeo") catch "/usr/bin/skopeo";
        const umoci_path = findExecutable(allocator, "umoci") catch "/usr/bin/umoci";

        // Create temp directory for pulling
        const temp_dir = try std.fs.path.join(allocator, &.{ image_store.base_path, "tmp" });
        std.fs.makeDirAbsolute(temp_dir) catch |e| {
            if (e != error.PathAlreadyExists) {
                allocator.free(temp_dir);
                return error.OutOfMemory;
            }
        };

        return Self{
            .allocator = allocator,
            .image_store = image_store,
            .machined_manager = if (bus) |b| machined.MachineImageManager.init(allocator, b) else null,
            .skopeo_path = skopeo_path,
            .umoci_path = umoci_path,
            .temp_dir = temp_dir,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.temp_dir);
    }

    /// Pull an image from a registry
    /// Returns the image ID (name usable with machinectl/nspawn)
    pub fn pullImage(
        self: *Self,
        image_ref: []const u8,
        auth: ?AuthConfig,
    ) PullError![]const u8 {
        logging.info("Pulling image: {s}", .{image_ref});

        // Parse image reference
        var ref = store.ImageReference.parse(self.allocator, image_ref) catch return PullError.InvalidImage;
        defer ref.deinit(self.allocator);

        // Generate a sanitized name for the machine image
        const machine_name = self.generateMachineName(&ref) catch return PullError.OutOfMemory;
        errdefer self.allocator.free(machine_name);

        // Check if image already exists in machined
        if (self.machined_manager) |*mgr| {
            if (mgr.imageExists(machine_name)) {
                logging.info("Image already exists in machined: {s}", .{machine_name});
                return machine_name;
            }
        }

        // Determine source and destination
        const source = blk: {
            if (ref.registry) |reg| {
                break :blk std.fmt.allocPrint(self.allocator, "docker://{s}/{s}", .{ reg, ref.repository }) catch return PullError.OutOfMemory;
            } else {
                break :blk std.fmt.allocPrint(self.allocator, "docker://docker.io/{s}", .{ref.repository}) catch return PullError.OutOfMemory;
            }
        };
        defer self.allocator.free(source);

        // Add tag or digest
        const full_source = if (ref.digest) |dig|
            std.fmt.allocPrint(self.allocator, "{s}@{s}", .{ source, dig }) catch return PullError.OutOfMemory
        else if (ref.tag) |tag|
            std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ source, tag }) catch return PullError.OutOfMemory
        else
            std.fmt.allocPrint(self.allocator, "{s}:latest", .{source}) catch return PullError.OutOfMemory;
        defer self.allocator.free(full_source);

        // Create OCI directory for skopeo output
        const oci_dir = std.fs.path.join(self.allocator, &.{ self.temp_dir, "oci" }) catch return PullError.OutOfMemory;
        defer self.allocator.free(oci_dir);

        // Clean up any previous attempt
        std.fs.deleteTreeAbsolute(oci_dir) catch {};
        std.fs.makeDirAbsolute(oci_dir) catch return PullError.PullFailed;

        const dest = std.fmt.allocPrint(self.allocator, "oci:{s}:latest", .{oci_dir}) catch return PullError.OutOfMemory;
        defer self.allocator.free(dest);

        // Build skopeo command
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);

        args.append(self.allocator, self.skopeo_path) catch return PullError.OutOfMemory;
        args.append(self.allocator, "copy") catch return PullError.OutOfMemory;
        args.append(self.allocator, "--insecure-policy") catch return PullError.OutOfMemory;

        // Add auth if provided
        if (auth) |a| {
            if (a.username) |user| {
                if (a.password) |pass| {
                    const creds = std.fmt.allocPrint(self.allocator, "--src-creds={s}:{s}", .{ user, pass }) catch return PullError.OutOfMemory;
                    args.append(self.allocator, creds) catch return PullError.OutOfMemory;
                }
            }
        }

        args.append(self.allocator, full_source) catch return PullError.OutOfMemory;
        args.append(self.allocator, dest) catch return PullError.OutOfMemory;

        logging.debug("Running: skopeo copy {s} {s}", .{ full_source, dest });

        // Execute skopeo
        const result = runCommand(self.allocator, args.items) catch return PullError.PullFailed;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.exit_code != 0) {
            logging.err("skopeo failed (exit {d}): {s}", .{ result.exit_code, result.stderr });
            return PullError.PullFailed;
        }

        // Create bundle directory for umoci output
        const bundle_dir = std.fs.path.join(self.allocator, &.{ self.temp_dir, "bundle" }) catch return PullError.OutOfMemory;
        defer self.allocator.free(bundle_dir);

        // Clean up any previous attempt
        std.fs.deleteTreeAbsolute(bundle_dir) catch {};

        // Extract using umoci
        var unpack_args: std.ArrayList([]const u8) = .empty;
        defer unpack_args.deinit(self.allocator);

        unpack_args.append(self.allocator, self.umoci_path) catch return PullError.OutOfMemory;
        unpack_args.append(self.allocator, "unpack") catch return PullError.OutOfMemory;
        unpack_args.append(self.allocator, "--rootless") catch return PullError.OutOfMemory;
        unpack_args.append(self.allocator, "--image") catch return PullError.OutOfMemory;

        const image_arg = std.fmt.allocPrint(self.allocator, "{s}:latest", .{oci_dir}) catch return PullError.OutOfMemory;
        defer self.allocator.free(image_arg);
        unpack_args.append(self.allocator, image_arg) catch return PullError.OutOfMemory;
        unpack_args.append(self.allocator, bundle_dir) catch return PullError.OutOfMemory;

        logging.debug("Running: umoci unpack --rootless --image {s} {s}", .{ image_arg, bundle_dir });

        const unpack_result = runCommand(self.allocator, unpack_args.items) catch return PullError.ExtractFailed;
        defer self.allocator.free(unpack_result.stdout);
        defer self.allocator.free(unpack_result.stderr);

        if (unpack_result.exit_code != 0) {
            logging.err("umoci unpack failed (exit {d}): {s}", .{ unpack_result.exit_code, unpack_result.stderr });
            return PullError.ExtractFailed;
        }

        // The rootfs is in bundle_dir/rootfs
        const rootfs_path = std.fs.path.join(self.allocator, &.{ bundle_dir, "rootfs" }) catch return PullError.OutOfMemory;
        defer self.allocator.free(rootfs_path);

        // Import into systemd-machined (required)
        const mgr = &(self.machined_manager orelse {
            logging.err("systemd-machined not available, cannot store image", .{});
            return PullError.ImportFailed;
        });

        logging.info("Importing into systemd-machined as: {s}", .{machine_name});
        mgr.importFileSystem(rootfs_path, machine_name, true) catch |err| {
            logging.err("Failed to import to machined: {}", .{err});
            return PullError.ImportFailed;
        };

        // Verify the import worked
        if (!mgr.imageExists(machine_name)) {
            logging.err("Image import verification failed: {s}", .{machine_name});
            return PullError.ImportFailed;
        }

        logging.info("Image imported successfully: {s}", .{machine_name});

        // Clean up temp files
        std.fs.deleteTreeAbsolute(oci_dir) catch {};
        std.fs.deleteTreeAbsolute(bundle_dir) catch {};

        return machine_name;
    }

    /// Generate a machine-compatible name from an image reference
    fn generateMachineName(self: *Self, ref: *store.ImageReference) ![]const u8 {
        // Machine names must be valid hostnames (alphanumeric, hyphens, max 64 chars)
        var name_buf: std.ArrayList(u8) = .empty;
        errdefer name_buf.deinit(self.allocator);

        const w = name_buf.writer(self.allocator);

        // Use repository name, replacing invalid chars
        for (ref.repository) |char| {
            if (std.ascii.isAlphanumeric(char)) {
                try w.writeByte(std.ascii.toLower(char));
            } else if (char == '/' or char == '_' or char == '.' or char == '-') {
                try w.writeByte('-');
            }
        }

        // Add tag if not 'latest'
        if (ref.tag) |tag| {
            if (!std.mem.eql(u8, tag, "latest")) {
                try w.writeByte('-');
                for (tag) |char| {
                    if (std.ascii.isAlphanumeric(char)) {
                        try w.writeByte(std.ascii.toLower(char));
                    } else if (char == '.' or char == '_' or char == '-') {
                        try w.writeByte('-');
                    }
                }
            }
        }

        var result = try name_buf.toOwnedSlice(self.allocator);

        // Truncate to 64 chars max
        if (result.len > 64) {
            const truncated = try self.allocator.dupe(u8, result[0..64]);
            self.allocator.free(result);
            result = truncated;
        }

        return result;
    }

    /// Check if an image exists in machined
    pub fn imageExists(self: *Self, image_ref: []const u8) bool {
        const mgr = &(self.machined_manager orelse return false);

        // Parse reference to get machine name
        var ref = store.ImageReference.parse(self.allocator, image_ref) catch return false;
        defer ref.deinit(self.allocator);

        const machine_name = self.generateMachineName(&ref) catch return false;
        defer self.allocator.free(machine_name);

        return mgr.imageExists(machine_name);
    }

    /// Get the rootfs path for an image (from machined)
    pub fn getImageRootfs(self: *Self, image_ref: []const u8) ![]const u8 {
        const mgr = &(self.machined_manager orelse return error.NotFound);

        var ref = store.ImageReference.parse(self.allocator, image_ref) catch return error.InvalidImage;
        defer ref.deinit(self.allocator);

        const machine_name = self.generateMachineName(&ref) catch return error.OutOfMemory;
        defer self.allocator.free(machine_name);

        if (!mgr.imageExists(machine_name)) {
            return error.NotFound;
        }

        // Images are stored in /var/lib/machines/<name>
        return std.fmt.allocPrint(self.allocator, "/var/lib/machines/{s}", .{machine_name});
    }

    /// Remove an image from machined
    /// Accepts either full image reference (registry/name:tag) or machine name directly
    pub fn removeImage(self: *Self, image_ref: []const u8) !void {
        const mgr = &(self.machined_manager orelse return error.NotFound);

        // First try to parse as full image reference
        if (store.ImageReference.parse(self.allocator, image_ref)) |ref_val| {
            var ref = ref_val;
            defer ref.deinit(self.allocator);
            const machine_name = self.generateMachineName(&ref) catch return error.OutOfMemory;
            defer self.allocator.free(machine_name);

            logging.info("Removing image: {s} (machine name: {s})", .{ image_ref, machine_name });
            mgr.removeImage(machine_name) catch |err| {
                if (err != machined.MachineImageError.NotFound) {
                    return error.RemoveFailed;
                }
            };
        } else |_| {
            // If parsing fails, assume image_ref is already a machine name
            logging.info("Removing image by machine name: {s}", .{image_ref});
            mgr.removeImage(image_ref) catch |err| {
                if (err != machined.MachineImageError.NotFound) {
                    return error.RemoveFailed;
                }
            };
        }
    }

    /// Get image info by reference
    /// Converts the reference to a machine name and looks up in machined
    pub fn getImageInfo(self: *Self, image_ref: []const u8) !ImageInfo {
        const mgr = &(self.machined_manager orelse return error.NotFound);

        var ref = store.ImageReference.parse(self.allocator, image_ref) catch return error.InvalidImage;
        defer ref.deinit(self.allocator);

        const machine_name = self.generateMachineName(&ref) catch return error.OutOfMemory;
        defer self.allocator.free(machine_name);

        var img = mgr.getImage(machine_name) catch return error.NotFound;
        defer img.deinit(self.allocator);

        return ImageInfo{
            .id = try self.allocator.dupe(u8, img.name),
            .size = img.disk_usage,
            .created_at = @intCast(img.creation_time / 1_000_000), // usec to sec
        };
    }

    /// List all available images from machined
    pub fn listImages(self: *Self) !std.ArrayList(ImageInfo) {
        var images: std.ArrayList(ImageInfo) = .empty;
        errdefer {
            for (images.items) |*img| {
                img.deinit(self.allocator);
            }
            images.deinit(self.allocator);
        }

        const mgr = &(self.machined_manager orelse return images);

        var machined_images = mgr.listImages() catch return images;
        defer {
            for (machined_images.items) |*img| {
                img.deinit(self.allocator);
            }
            machined_images.deinit(self.allocator);
        }

        for (machined_images.items) |*img| {
            const info = ImageInfo{
                .id = try self.allocator.dupe(u8, img.name),
                .size = img.disk_usage,
                .created_at = @intCast(img.creation_time / 1_000_000), // usec to sec
            };
            try images.append(self.allocator, info);
        }

        return images;
    }
};

/// Image information
pub const ImageInfo = struct {
    id: []const u8,
    size: u64,
    created_at: i64,

    pub fn deinit(self: *ImageInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
    }
};

/// Authentication configuration for registry access
pub const AuthConfig = struct {
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    auth: ?[]const u8 = null,
    server_address: ?[]const u8 = null,
    identity_token: ?[]const u8 = null,
    registry_token: ?[]const u8 = null,
};

/// Command execution result
const CommandResult = struct {
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

fn runCommand(allocator: std.mem.Allocator, args: []const []const u8) !CommandResult {
    var child = std.process.Child.init(args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 10 * 1024 * 1024);
    errdefer allocator.free(stdout);

    const stderr = try child.stderr.?.readToEndAlloc(allocator, 10 * 1024 * 1024);
    errdefer allocator.free(stderr);

    const term = try child.wait();

    return CommandResult{
        .exit_code = switch (term) {
            .Exited => |code| code,
            else => 255,
        },
        .stdout = stdout,
        .stderr = stderr,
    };
}

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

