const std = @import("std");
const json = std.json;

/// Create a directory and all parent directories
fn makeDirRecursive(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |e| {
        if (e == error.PathAlreadyExists) return;
        if (e == error.FileNotFound) {
            // Parent doesn't exist, create it first
            const parent = std.fs.path.dirname(path) orelse return e;
            try makeDirRecursive(parent);
            // Now try again
            std.fs.makeDirAbsolute(path) catch |e2| {
                if (e2 != error.PathAlreadyExists) return e2;
            };
            return;
        }
        return e;
    };
}

pub const ImageStoreError = error{
    NotFound,
    AlreadyExists,
    InvalidImage,
    IoError,
    ParseError,
    OutOfMemory,
};

/// Image metadata stored in the image store
pub const ImageMetadata = struct {
    id: []const u8, // Content-addressable ID (sha256:...)
    repo_tags: std.ArrayList([]const u8),
    repo_digests: std.ArrayList([]const u8),
    size: u64,
    created_at: i64,
    config: ?ImageConfig,

    pub fn deinit(self: *ImageMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        for (self.repo_tags.items) |tag| {
            allocator.free(tag);
        }
        self.repo_tags.deinit(allocator);
        for (self.repo_digests.items) |digest| {
            allocator.free(digest);
        }
        self.repo_digests.deinit(allocator);
        if (self.config) |*cfg| {
            cfg.deinit(allocator);
        }
    }
};

/// Image configuration (from OCI image config)
pub const ImageConfig = struct {
    user: ?[]const u8 = null,
    exposed_ports: ?std.StringHashMap(void) = null,
    env: std.ArrayList([]const u8),
    entrypoint: std.ArrayList([]const u8),
    cmd: std.ArrayList([]const u8),
    volumes: ?std.StringHashMap(void) = null,
    working_dir: ?[]const u8 = null,
    labels: ?std.StringHashMap([]const u8) = null,
    stop_signal: ?[]const u8 = null,

    pub fn deinit(self: *ImageConfig, allocator: std.mem.Allocator) void {
        if (self.user) |u| allocator.free(u);
        if (self.exposed_ports) |*ports| ports.deinit();
        for (self.env.items) |e| allocator.free(e);
        self.env.deinit(allocator);
        for (self.entrypoint.items) |e| allocator.free(e);
        self.entrypoint.deinit(allocator);
        for (self.cmd.items) |c| allocator.free(c);
        self.cmd.deinit(allocator);
        if (self.volumes) |*vols| vols.deinit();
        if (self.working_dir) |wd| allocator.free(wd);
        if (self.labels) |*lbls| {
            var it = lbls.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            lbls.deinit();
        }
        if (self.stop_signal) |ss| allocator.free(ss);
    }
};

/// Layer information
pub const Layer = struct {
    digest: []const u8, // sha256:...
    size: u64,
    diff_path: []const u8, // Path to extracted layer

    pub fn deinit(self: *Layer, allocator: std.mem.Allocator) void {
        allocator.free(self.digest);
        allocator.free(self.diff_path);
    }
};

/// Content-addressable image store
pub const ImageStore = struct {
    allocator: std.mem.Allocator,
    base_path: []const u8,
    blobs_path: []const u8,
    layers_path: []const u8,
    manifests_path: []const u8,
    images_db_path: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, base_path: []const u8) !Self {
        const blobs_path = try std.fs.path.join(allocator, &.{ base_path, "images", "blobs", "sha256" });
        errdefer allocator.free(blobs_path);

        const layers_path = try std.fs.path.join(allocator, &.{ base_path, "images", "layers" });
        errdefer allocator.free(layers_path);

        const manifests_path = try std.fs.path.join(allocator, &.{ base_path, "images", "manifests" });
        errdefer allocator.free(manifests_path);

        const images_db_path = try std.fs.path.join(allocator, &.{ base_path, "images", "images.json" });
        errdefer allocator.free(images_db_path);

        // Create directories recursively
        const dirs = [_][]const u8{ blobs_path, layers_path, manifests_path };
        for (dirs) |dir| {
            makeDirRecursive(dir) catch {};
        }

        return Self{
            .allocator = allocator,
            .base_path = try allocator.dupe(u8, base_path),
            .blobs_path = blobs_path,
            .layers_path = layers_path,
            .manifests_path = manifests_path,
            .images_db_path = images_db_path,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.base_path);
        self.allocator.free(self.blobs_path);
        self.allocator.free(self.layers_path);
        self.allocator.free(self.manifests_path);
        self.allocator.free(self.images_db_path);
    }

    /// Get the path to a blob by its digest
    pub fn getBlobPath(self: *Self, digest: []const u8) ![]const u8 {
        // Strip sha256: prefix if present
        const hash = if (std.mem.startsWith(u8, digest, "sha256:"))
            digest[7..]
        else
            digest;

        return std.fs.path.join(self.allocator, &.{ self.blobs_path, hash });
    }

    /// Get the path to an extracted layer
    pub fn getLayerPath(self: *Self, digest: []const u8) ![]const u8 {
        const hash = if (std.mem.startsWith(u8, digest, "sha256:"))
            digest[7..]
        else
            digest;

        return std.fs.path.join(self.allocator, &.{ self.layers_path, hash, "diff" });
    }

    /// Check if a blob exists
    pub fn hasBlob(self: *Self, digest: []const u8) !bool {
        const path = try self.getBlobPath(digest);
        defer self.allocator.free(path);

        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }

    /// Store a blob
    pub fn storeBlob(self: *Self, digest: []const u8, data: []const u8) !void {
        const path = try self.getBlobPath(digest);
        defer self.allocator.free(path);

        const file = std.fs.createFileAbsolute(path, .{}) catch return ImageStoreError.IoError;
        defer file.close();

        file.writeAll(data) catch return ImageStoreError.IoError;
    }

    /// Read a blob
    pub fn readBlob(self: *Self, digest: []const u8) ![]u8 {
        const path = try self.getBlobPath(digest);
        defer self.allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch return ImageStoreError.NotFound;
        defer file.close();

        return file.readToEndAlloc(self.allocator, 100 * 1024 * 1024) catch return ImageStoreError.IoError;
    }

    /// Get layers for an image (returns paths to extracted layer directories)
    pub fn getImageLayers(self: *Self, image_id: []const u8) !std.ArrayList([]const u8) {
        _ = self;
        _ = image_id;
        // TODO: Parse manifest and return layer paths in order
        const layers: std.ArrayList([]const u8) = .empty;
        return layers;
    }

    /// Add a tag to an image
    pub fn tagImage(self: *Self, image_id: []const u8, tag: []const u8) !void {
        _ = self;
        _ = image_id;
        _ = tag;
        // TODO: Update images.json with new tag mapping
    }

    /// Remove an image
    pub fn removeImage(self: *Self, image_ref: []const u8) !void {
        _ = self;
        _ = image_ref;
        // TODO: Remove image and unreferenced layers/blobs
    }

    /// List all images
    pub fn listImages(self: *Self) !std.ArrayList(ImageMetadata) {
        var images: std.ArrayList(ImageMetadata) = .empty;
        errdefer {
            for (images.items) |*img| {
                img.deinit(self.allocator);
            }
            images.deinit(self.allocator);
        }

        // Read images database
        const file = std.fs.openFileAbsolute(self.images_db_path, .{}) catch {
            return images; // Empty list if no database
        };
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch return images;
        defer self.allocator.free(content);

        // TODO: Parse JSON and return image list

        return images;
    }

    /// Get image by reference (tag or digest)
    pub fn getImage(self: *Self, image_ref: []const u8) !ImageMetadata {
        _ = self;
        _ = image_ref;
        return ImageStoreError.NotFound;
    }

    /// Resolve image reference to image ID
    pub fn resolveImageRef(self: *Self, image_ref: []const u8) ![]const u8 {
        // TODO: Look up tag or digest and return image ID
        return self.allocator.dupe(u8, image_ref);
    }
};

/// Parse an image reference into its components
pub const ImageReference = struct {
    registry: ?[]const u8,
    repository: []const u8,
    tag: ?[]const u8,
    digest: ?[]const u8,

    pub fn parse(allocator: std.mem.Allocator, ref: []const u8) !ImageReference {
        var result = ImageReference{
            .registry = null,
            .repository = undefined,
            .tag = null,
            .digest = null,
        };

        var remaining = ref;

        // Check for digest
        if (std.mem.indexOf(u8, remaining, "@")) |idx| {
            result.digest = try allocator.dupe(u8, remaining[idx + 1 ..]);
            remaining = remaining[0..idx];
        }

        // Check for tag
        if (std.mem.lastIndexOf(u8, remaining, ":")) |idx| {
            // Make sure it's not a port number (registry:port/repo)
            if (std.mem.indexOf(u8, remaining[idx..], "/") == null) {
                result.tag = try allocator.dupe(u8, remaining[idx + 1 ..]);
                remaining = remaining[0..idx];
            }
        }

        // Check for registry (contains . or : or is localhost)
        if (std.mem.indexOf(u8, remaining, "/")) |idx| {
            const first_part = remaining[0..idx];
            if (std.mem.indexOf(u8, first_part, ".") != null or
                std.mem.indexOf(u8, first_part, ":") != null or
                std.mem.eql(u8, first_part, "localhost"))
            {
                result.registry = try allocator.dupe(u8, first_part);
                remaining = remaining[idx + 1 ..];
            }
        }

        result.repository = try allocator.dupe(u8, remaining);

        // Default tag if none specified
        if (result.tag == null and result.digest == null) {
            result.tag = try allocator.dupe(u8, "latest");
        }

        return result;
    }

    pub fn deinit(self: *ImageReference, allocator: std.mem.Allocator) void {
        if (self.registry) |r| allocator.free(r);
        allocator.free(self.repository);
        if (self.tag) |t| allocator.free(t);
        if (self.digest) |d| allocator.free(d);
    }

    /// Format the reference back to a string
    pub fn format(self: *const ImageReference, allocator: std.mem.Allocator) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);

        const w = list.writer(allocator);

        if (self.registry) |reg| {
            try w.writeAll(reg);
            try w.writeAll("/");
        }
        try w.writeAll(self.repository);
        if (self.digest) |dig| {
            try w.writeAll("@");
            try w.writeAll(dig);
        } else if (self.tag) |tag| {
            try w.writeAll(":");
            try w.writeAll(tag);
        }

        return list.toOwnedSlice(allocator);
    }
};

test "ImageReference.parse" {
    const allocator = std.testing.allocator;

    // Simple image
    {
        var ref = try ImageReference.parse(allocator, "nginx");
        defer ref.deinit(allocator);
        try std.testing.expectEqualStrings("nginx", ref.repository);
        try std.testing.expectEqualStrings("latest", ref.tag.?);
        try std.testing.expect(ref.registry == null);
    }

    // Image with tag
    {
        var ref = try ImageReference.parse(allocator, "nginx:1.19");
        defer ref.deinit(allocator);
        try std.testing.expectEqualStrings("nginx", ref.repository);
        try std.testing.expectEqualStrings("1.19", ref.tag.?);
    }

    // Full reference
    {
        var ref = try ImageReference.parse(allocator, "docker.io/library/nginx:latest");
        defer ref.deinit(allocator);
        try std.testing.expectEqualStrings("docker.io", ref.registry.?);
        try std.testing.expectEqualStrings("library/nginx", ref.repository);
        try std.testing.expectEqualStrings("latest", ref.tag.?);
    }
}
