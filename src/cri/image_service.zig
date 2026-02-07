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

        var stored_images = try self.store.listImages();
        defer {
            for (stored_images.items) |*img| {
                img.deinit(self.allocator);
            }
            stored_images.deinit(self.allocator);
        }

        for (stored_images.items) |img| {
            // Apply filter if provided
            if (filter) |f| {
                if (f.image) |filter_image| {
                    var matches = false;
                    for (img.repo_tags.items) |tag| {
                        if (std.mem.eql(u8, tag, filter_image.image)) {
                            matches = true;
                            break;
                        }
                    }
                    if (!matches) continue;
                }
            }

            var repo_tags: std.ArrayList([]const u8) = .empty;
            for (img.repo_tags.items) |tag| {
                try repo_tags.append(self.allocator, try self.allocator.dupe(u8, tag));
            }

            var repo_digests: std.ArrayList([]const u8) = .empty;
            for (img.repo_digests.items) |digest| {
                try repo_digests.append(self.allocator, try self.allocator.dupe(u8, digest));
            }

            try images.append(self.allocator, types.Image{
                .id = try self.allocator.dupe(u8, img.id),
                .repo_tags = repo_tags.items,
                .repo_digests = repo_digests.items,
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

        var img = self.store.getImage(image_spec.image) catch return null;
        defer img.deinit(self.allocator);

        var repo_tags: std.ArrayList([]const u8) = .empty;
        for (img.repo_tags.items) |tag| {
            try repo_tags.append(self.allocator, try self.allocator.dupe(u8, tag));
        }

        var repo_digests: std.ArrayList([]const u8) = .empty;
        for (img.repo_digests.items) |digest| {
            try repo_digests.append(self.allocator, try self.allocator.dupe(u8, digest));
        }

        return ImageStatusResponse{
            .image = types.Image{
                .id = try self.allocator.dupe(u8, img.id),
                .repo_tags = repo_tags.items,
                .repo_digests = repo_digests.items,
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
        try self.store.removeImage(image_spec.image);
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
