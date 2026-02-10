const std = @import("std");
const types = @import("types.zig");
const dbus = @import("../systemd/dbus.zig");
const image_store = @import("../image/store.zig");
const image_pull = @import("../image/pull.zig");
const logging = @import("../util/logging.zig");

/// ImageService implements the CRI ImageService interface
pub const ImageService = struct {
    allocator: std.mem.Allocator,
    store: *image_store.ImageStore,
    puller: image_pull.ImagePuller,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, store: *image_store.ImageStore, bus: ?*dbus.Bus) !Self {
        return Self{
            .allocator = allocator,
            .store = store,
            .puller = try image_pull.ImagePuller.init(allocator, store, bus),
        };
    }

    pub fn deinit(self: *Self) void {
        self.puller.deinit();
    }

    /// List images in the store
    pub fn listImages(self: *Self, filter: ?ImageFilter) !std.ArrayList(types.Image) {
        var images: std.ArrayList(types.Image) = .empty;
        errdefer images.deinit(self.allocator);

        // Get images from the puller (which checks machined and local store)
        var pulled_images = self.puller.listImages() catch {
            return images; // Return empty list on error
        };
        defer {
            for (pulled_images.items) |*img| {
                img.deinit(self.allocator);
            }
            pulled_images.deinit(self.allocator);
        }

        for (pulled_images.items) |img| {
            // Apply filter if provided
            if (filter) |f| {
                if (f.image) |filter_image| {
                    if (!std.mem.eql(u8, img.id, filter_image.image)) {
                        continue;
                    }
                }
            }

            // Create repo_tags array with the image id as the tag
            var repo_tags: std.ArrayList([]const u8) = .empty;
            try repo_tags.append(self.allocator, try self.allocator.dupe(u8, img.id));

            try images.append(self.allocator, types.Image{
                .id = try self.allocator.dupe(u8, img.id),
                .repo_tags = repo_tags.items,
                .repo_digests = &.{},
                .size = img.size,
                .uid = null,
                .username = null,
                .spec = null,
                .pinned = false,
            });
        }

        return images;
    }

    /// Get image status
    pub fn imageStatus(self: *Self, image_spec: *const types.ImageSpec, verbose: bool) !?ImageStatusResponse {
        _ = verbose;

        // Look up image via the puller (which checks machined)
        var img = self.puller.getImageInfo(image_spec.image) catch return null;
        defer img.deinit(self.allocator);

        // Create repo_tags with the original reference
        // Normalize tag: if no tag or digest, add :latest
        var repo_tags: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (repo_tags.items) |t| self.allocator.free(t);
            repo_tags.deinit(self.allocator);
        }

        const image_ref = image_spec.image;
        // Check if reference has a tag (contains ':' after the last '/') or digest (contains '@')
        const has_digest = std.mem.indexOf(u8, image_ref, "@") != null;
        const last_slash = std.mem.lastIndexOf(u8, image_ref, "/");
        const has_tag = if (last_slash) |slash_pos|
            std.mem.indexOf(u8, image_ref[slash_pos..], ":") != null
        else
            std.mem.indexOf(u8, image_ref, ":") != null;

        if (has_digest or has_tag) {
            try repo_tags.append(self.allocator, try self.allocator.dupe(u8, image_ref));
        } else {
            // No tag specified, add :latest
            const tag_with_latest = try std.fmt.allocPrint(self.allocator, "{s}:latest", .{image_ref});
            try repo_tags.append(self.allocator, tag_with_latest);
        }

        return ImageStatusResponse{
            .image = types.Image{
                .id = try self.allocator.dupe(u8, img.id),
                .repo_tags = try repo_tags.toOwnedSlice(self.allocator),
                .repo_digests = &.{},
                .size = img.size,
                .uid = null,
                .username = null,
                .spec = null,
                .pinned = false,
            },
            .info = null,
        };
    }

    /// Pull an image from a registry
    pub fn pullImage(
        self: *Self,
        image_spec: *const types.ImageSpec,
        auth: ?types.AuthConfig,
        sandbox_config: ?*const types.PodSandboxConfig,
    ) ![]const u8 {
        _ = sandbox_config;

        logging.info("PullImage: {s}", .{image_spec.image});

        const pull_auth = if (auth) |a| image_pull.AuthConfig{
            .username = a.username,
            .password = a.password,
            .auth = a.auth,
            .server_address = a.server_address,
            .identity_token = a.identity_token,
            .registry_token = a.registry_token,
        } else null;

        const image_ref = try self.puller.pullImage(image_spec.image, pull_auth);
        return image_ref;
    }

    /// Remove an image from the store
    pub fn removeImage(self: *Self, image_spec: *const types.ImageSpec) !void {
        logging.info("RemoveImage: {s}", .{image_spec.image});
        // Remove from machined via the puller
        self.puller.removeImage(image_spec.image) catch |err| {
            logging.warn("Failed to remove image from machined: {}", .{err});
        };
        // Also try to remove from local store (may not exist)
        self.store.removeImage(image_spec.image) catch {};
    }

    /// Get filesystem info for images
    pub fn imageFsInfo(self: *Self) !std.ArrayList(FilesystemUsage) {
        var result: std.ArrayList(FilesystemUsage) = .empty;
        errdefer result.deinit(self.allocator);

        // Get filesystem stats for the image store
        const stat = std.fs.cwd().statFile(self.store.base_path) catch {
            return result;
        };
        _ = stat;

        // TODO: Calculate actual usage
        try result.append(self.allocator, FilesystemUsage{
            .timestamp = std.time.timestamp() * 1_000_000_000,
            .fs_id = .{
                .mountpoint = try self.allocator.dupe(u8, self.store.base_path),
            },
            .used_bytes = 0,
            .inodes_used = 0,
        });

        return result;
    }
};

/// Image filter for listing
pub const ImageFilter = struct {
    image: ?types.ImageSpec = null,
};

/// Image status response
pub const ImageStatusResponse = struct {
    image: types.Image,
    info: ?std.StringHashMap([]const u8),
};

/// Filesystem usage info
pub const FilesystemUsage = struct {
    timestamp: i64,
    fs_id: FilesystemIdentifier,
    used_bytes: u64,
    inodes_used: u64,
};

pub const FilesystemIdentifier = struct {
    mountpoint: []const u8,
};
