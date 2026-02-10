const std = @import("std");
const dbus = @import("../systemd/dbus.zig");
const logging = @import("../util/logging.zig");

pub const MachineImageError = error{
    NotFound,
    AlreadyExists,
    ImportFailed,
    RemoveFailed,
    CloneFailed,
    DbusError,
    OutOfMemory,
};

/// Image information from systemd-machined
pub const MachineImage = struct {
    name: []const u8,
    image_type: ImageType,
    read_only: bool,
    creation_time: u64, // usec since epoch
    modification_time: u64,
    disk_usage: u64, // bytes
    object_path: []const u8,

    pub fn deinit(self: *MachineImage, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.object_path);
    }
};

pub const ImageType = enum {
    directory,
    subvolume,
    raw,
    block,
    unknown,

    pub fn fromString(s: []const u8) ImageType {
        if (std.mem.eql(u8, s, "directory")) return .directory;
        if (std.mem.eql(u8, s, "subvolume")) return .subvolume;
        if (std.mem.eql(u8, s, "raw")) return .raw;
        if (std.mem.eql(u8, s, "block")) return .block;
        return .unknown;
    }
};

/// Manager for systemd-machined image operations
pub const MachineImageManager = struct {
    allocator: std.mem.Allocator,
    bus: *dbus.Bus,

    const Self = @This();

    // D-Bus destinations
    const MACHINE1_DEST: [*:0]const u8 = "org.freedesktop.machine1";
    const MACHINE1_PATH: [*:0]const u8 = "/org/freedesktop/machine1";
    const MACHINE1_IFACE: [*:0]const u8 = "org.freedesktop.machine1.Manager";

    const IMPORT1_DEST: [*:0]const u8 = "org.freedesktop.import1";
    const IMPORT1_PATH: [*:0]const u8 = "/org/freedesktop/import1";
    const IMPORT1_IFACE: [*:0]const u8 = "org.freedesktop.import1.Manager";

    pub fn init(allocator: std.mem.Allocator, bus: *dbus.Bus) Self {
        return Self{
            .allocator = allocator,
            .bus = bus,
        };
    }

    /// List all images in /var/lib/machines
    pub fn listImages(self: *Self) MachineImageError!std.ArrayList(MachineImage) {
        var images: std.ArrayList(MachineImage) = .empty;
        errdefer {
            for (images.items) |*img| {
                img.deinit(self.allocator);
            }
            images.deinit(self.allocator);
        }

        var err = dbus.Error.init();
        defer err.deinit();

        var reply = dbus.Message.init();
        defer reply.deinit();

        // Call org.freedesktop.machine1.Manager.ListImages
        self.bus.call(
            MACHINE1_DEST,
            MACHINE1_PATH,
            MACHINE1_IFACE,
            "ListImages",
            &err,
            &reply,
            null,
        ) catch {
            if (err.getMessage()) |msg| {
                logging.err("ListImages failed: {s}", .{msg});
            }
            return MachineImageError.DbusError;
        };

        // ListImages returns a(ssbttto):
        // - s: name
        // - s: type
        // - b: read-only
        // - t: creation time (usec)
        // - t: modification time (usec)
        // - t: disk usage (bytes)
        // - o: object path

        // Enter the array
        reply.enterContainer('a', "(ssbttto)") catch return MachineImageError.DbusError;

        while (true) {
            // Try to enter a struct
            reply.enterContainer('r', "ssbttto") catch break;

            const name = reply.readString() catch continue;
            const type_str = reply.readString() catch continue;

            // Read bool - need to use raw API
            var read_only: c_int = 0;
            if (dbus.raw.sd_bus_message_read(reply.inner, "b", &read_only) < 0) continue;

            // Read timestamps and size
            var creation_time: u64 = 0;
            var modification_time: u64 = 0;
            var disk_usage: u64 = 0;
            if (dbus.raw.sd_bus_message_read(reply.inner, "ttt", &creation_time, &modification_time, &disk_usage) < 0) continue;

            const object_path = reply.readObjectPath() catch continue;

            reply.exitContainer() catch continue;

            const image = MachineImage{
                .name = self.allocator.dupe(u8, name) catch return MachineImageError.OutOfMemory,
                .image_type = ImageType.fromString(type_str),
                .read_only = read_only != 0,
                .creation_time = creation_time,
                .modification_time = modification_time,
                .disk_usage = disk_usage,
                .object_path = self.allocator.dupe(u8, object_path) catch return MachineImageError.OutOfMemory,
            };
            images.append(self.allocator, image) catch return MachineImageError.OutOfMemory;
        }

        reply.exitContainer() catch {};

        return images;
    }

    /// Get an image by name
    pub fn getImage(self: *Self, name: []const u8) MachineImageError!MachineImage {
        const name_z = self.allocator.dupeZ(u8, name) catch return MachineImageError.OutOfMemory;
        defer self.allocator.free(name_z);

        var err = dbus.Error.init();
        defer err.deinit();

        // Build message with string argument
        const msg = self.bus.callMethodRaw(
            MACHINE1_DEST,
            MACHINE1_PATH,
            MACHINE1_IFACE,
            "GetImage",
        ) catch return MachineImageError.DbusError;
        defer _ = dbus.raw.sd_bus_message_unref(msg);

        if (dbus.raw.sd_bus_message_append(msg, "s", name_z.ptr) < 0) {
            return MachineImageError.DbusError;
        }

        var reply = self.bus.callMessage(msg, &err) catch {
            if (err.getName()) |ename| {
                if (std.mem.indexOf(u8, ename, "NoSuchImage") != null) {
                    return MachineImageError.NotFound;
                }
            }
            return MachineImageError.DbusError;
        };
        defer reply.deinit();

        const object_path = reply.readObjectPath() catch return MachineImageError.DbusError;

        // Get image properties from the object path
        return self.getImageFromPath(object_path);
    }

    fn getImageFromPath(self: *Self, object_path: []const u8) MachineImageError!MachineImage {
        const path_z = self.allocator.dupeZ(u8, object_path) catch return MachineImageError.OutOfMemory;
        defer self.allocator.free(path_z);

        var err = dbus.Error.init();
        defer err.deinit();

        // Get Name property
        var name_reply = self.bus.getProperty(
            MACHINE1_DEST,
            path_z,
            "org.freedesktop.machine1.Image",
            "Name",
            &err,
            "s",
        ) catch return MachineImageError.DbusError;
        defer name_reply.deinit();
        const name = name_reply.readString() catch return MachineImageError.DbusError;

        // Get Type property
        err.deinit();
        err = dbus.Error.init();
        var type_reply = self.bus.getProperty(
            MACHINE1_DEST,
            path_z,
            "org.freedesktop.machine1.Image",
            "Type",
            &err,
            "s",
        ) catch return MachineImageError.DbusError;
        defer type_reply.deinit();
        const type_str = type_reply.readString() catch return MachineImageError.DbusError;

        // Get ReadOnly property
        err.deinit();
        err = dbus.Error.init();
        var ro_reply = self.bus.getProperty(
            MACHINE1_DEST,
            path_z,
            "org.freedesktop.machine1.Image",
            "ReadOnly",
            &err,
            "b",
        ) catch return MachineImageError.DbusError;
        defer ro_reply.deinit();
        var read_only: c_int = 0;
        if (dbus.raw.sd_bus_message_read(ro_reply.inner, "b", &read_only) < 0) {
            return MachineImageError.DbusError;
        }

        // Get timestamps and usage - these may fail on some image types
        var creation_time: u64 = 0;
        var modification_time: u64 = 0;
        var disk_usage: u64 = 0;

        // Get CreationTimestamp property
        blk: {
            err.deinit();
            err = dbus.Error.init();
            var ts_reply = self.bus.getProperty(
                MACHINE1_DEST,
                path_z,
                "org.freedesktop.machine1.Image",
                "CreationTimestamp",
                &err,
                "t",
            ) catch break :blk;
            defer ts_reply.deinit();
            var ts: u64 = 0;
            if (dbus.raw.sd_bus_message_read(ts_reply.inner, "t", &ts) >= 0) {
                creation_time = ts;
            }
        }

        // Get ModificationTimestamp property
        blk: {
            err.deinit();
            err = dbus.Error.init();
            var ts_reply = self.bus.getProperty(
                MACHINE1_DEST,
                path_z,
                "org.freedesktop.machine1.Image",
                "ModificationTimestamp",
                &err,
                "t",
            ) catch break :blk;
            defer ts_reply.deinit();
            var ts: u64 = 0;
            if (dbus.raw.sd_bus_message_read(ts_reply.inner, "t", &ts) >= 0) {
                modification_time = ts;
            }
        }

        // Get Usage property (disk usage in bytes)
        blk: {
            err.deinit();
            err = dbus.Error.init();
            var usage_reply = self.bus.getProperty(
                MACHINE1_DEST,
                path_z,
                "org.freedesktop.machine1.Image",
                "Usage",
                &err,
                "t",
            ) catch break :blk;
            defer usage_reply.deinit();
            var usage: u64 = 0;
            if (dbus.raw.sd_bus_message_read(usage_reply.inner, "t", &usage) >= 0) {
                disk_usage = usage;
            }
        }

        return MachineImage{
            .name = self.allocator.dupe(u8, name) catch return MachineImageError.OutOfMemory,
            .image_type = ImageType.fromString(type_str),
            .read_only = read_only != 0,
            .creation_time = creation_time,
            .modification_time = modification_time,
            .disk_usage = disk_usage,
            .object_path = self.allocator.dupe(u8, object_path) catch return MachineImageError.OutOfMemory,
        };
    }

    /// Remove an image
    pub fn removeImage(self: *Self, name: []const u8) MachineImageError!void {
        const name_z = self.allocator.dupeZ(u8, name) catch return MachineImageError.OutOfMemory;
        defer self.allocator.free(name_z);

        logging.info("Removing machine image: {s}", .{name});

        var err = dbus.Error.init();
        defer err.deinit();

        const msg = self.bus.callMethodRaw(
            MACHINE1_DEST,
            MACHINE1_PATH,
            MACHINE1_IFACE,
            "RemoveImage",
        ) catch return MachineImageError.DbusError;
        defer _ = dbus.raw.sd_bus_message_unref(msg);

        if (dbus.raw.sd_bus_message_append(msg, "s", name_z.ptr) < 0) {
            return MachineImageError.DbusError;
        }

        var reply = self.bus.callMessage(msg, &err) catch {
            if (err.getMessage()) |emsg| {
                logging.err("RemoveImage failed: {s}", .{emsg});
            }
            return MachineImageError.RemoveFailed;
        };
        reply.deinit();
    }

    /// Clone an image (creates a writable copy)
    pub fn cloneImage(self: *Self, source: []const u8, dest: []const u8, read_only: bool) MachineImageError!void {
        const source_z = self.allocator.dupeZ(u8, source) catch return MachineImageError.OutOfMemory;
        defer self.allocator.free(source_z);

        const dest_z = self.allocator.dupeZ(u8, dest) catch return MachineImageError.OutOfMemory;
        defer self.allocator.free(dest_z);

        logging.info("Cloning machine image: {s} -> {s}", .{ source, dest });

        var err = dbus.Error.init();
        defer err.deinit();

        const msg = self.bus.callMethodRaw(
            MACHINE1_DEST,
            MACHINE1_PATH,
            MACHINE1_IFACE,
            "CloneImage",
        ) catch return MachineImageError.DbusError;
        defer _ = dbus.raw.sd_bus_message_unref(msg);

        const ro_int: c_int = if (read_only) 1 else 0;
        if (dbus.raw.sd_bus_message_append(msg, "ssb", source_z.ptr, dest_z.ptr, ro_int) < 0) {
            return MachineImageError.DbusError;
        }

        var reply = self.bus.callMessage(msg, &err) catch {
            if (err.getMessage()) |emsg| {
                logging.err("CloneImage failed: {s}", .{emsg});
            }
            return MachineImageError.CloneFailed;
        };
        reply.deinit();
    }

    /// Import a filesystem directory as an image
    /// Uses org.freedesktop.import1.Manager.ImportFileSystem and polls for completion
    pub fn importFileSystem(self: *Self, path: []const u8, name: []const u8, read_only: bool) MachineImageError!void {
        logging.info("Importing filesystem as image: {s} -> {s}", .{ path, name });

        // Open the directory as a file descriptor
        const path_z = self.allocator.dupeZ(u8, path) catch return MachineImageError.OutOfMemory;
        defer self.allocator.free(path_z);

        const dir_fd = std.posix.open(path_z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) catch {
            logging.err("Failed to open directory: {s}", .{path});
            return MachineImageError.ImportFailed;
        };
        defer std.posix.close(dir_fd);

        const name_z = self.allocator.dupeZ(u8, name) catch return MachineImageError.OutOfMemory;
        defer self.allocator.free(name_z);

        var err = dbus.Error.init();
        defer err.deinit();

        // Call ImportFileSystem(h fd, s local_name, b force, b read_only) -> (u transfer_id, o transfer_path)
        const msg = self.bus.callMethodRaw(
            IMPORT1_DEST,
            IMPORT1_PATH,
            IMPORT1_IFACE,
            "ImportFileSystem",
        ) catch return MachineImageError.DbusError;
        defer _ = dbus.raw.sd_bus_message_unref(msg);

        const force_int: c_int = 1;
        const ro_int: c_int = if (read_only) 1 else 0;

        if (dbus.raw.sd_bus_message_append(msg, "hsbb", dir_fd, name_z.ptr, force_int, ro_int) < 0) {
            return MachineImageError.DbusError;
        }

        var reply = self.bus.callMessage(msg, &err) catch {
            if (err.getMessage()) |emsg| {
                logging.err("ImportFileSystem failed: {s}", .{emsg});
            }
            return MachineImageError.ImportFailed;
        };
        defer reply.deinit();

        // Get transfer ID and path
        var transfer_id: u32 = 0;
        if (dbus.raw.sd_bus_message_read(reply.inner, "u", &transfer_id) < 0) {
            return MachineImageError.DbusError;
        }

        const transfer_path = reply.readObjectPath() catch return MachineImageError.DbusError;
        logging.debug("Import started, transfer ID: {d}, path: {s}", .{ transfer_id, transfer_path });

        // Poll for completion - check if the image exists
        // The import is usually fast for filesystem imports, but we poll to be safe
        const max_attempts = 300; // 30 seconds max (100ms per attempt)
        var attempts: u32 = 0;

        while (attempts < max_attempts) : (attempts += 1) {
            // Check if image now exists
            if (self.imageExists(name)) {
                logging.debug("Import completed successfully after {d} attempts", .{attempts});
                return;
            }

            // Check if transfer is still running by querying its progress
            if (!self.isTransferActive(transfer_path)) {
                // Transfer finished but image doesn't exist - check one more time
                std.Thread.sleep(50 * std.time.ns_per_ms);
                if (self.imageExists(name)) {
                    logging.debug("Import completed successfully", .{});
                    return;
                }
                logging.err("Import transfer completed but image not found", .{});
                return MachineImageError.ImportFailed;
            }

            // Wait before next poll
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }

        logging.err("Import timed out after {d} attempts", .{max_attempts});
        return MachineImageError.ImportFailed;
    }

    /// Check if a transfer is still active
    fn isTransferActive(self: *Self, transfer_path: []const u8) bool {
        const path_z = self.allocator.dupeZ(u8, transfer_path) catch return false;
        defer self.allocator.free(path_z);

        var err = dbus.Error.init();
        defer err.deinit();

        // Try to get the Progress property - if the transfer is gone, this will fail
        var reply = self.bus.getProperty(
            IMPORT1_DEST,
            path_z,
            "org.freedesktop.import1.Transfer",
            "Progress",
            &err,
            "d",
        ) catch {
            // Transfer object no longer exists - transfer is complete
            return false;
        };
        defer reply.deinit();

        // Transfer still exists
        return true;
    }

    /// Mark an image as read-only
    pub fn markImageReadOnly(self: *Self, name: []const u8, read_only: bool) MachineImageError!void {
        const name_z = self.allocator.dupeZ(u8, name) catch return MachineImageError.OutOfMemory;
        defer self.allocator.free(name_z);

        var err = dbus.Error.init();
        defer err.deinit();

        const msg = self.bus.callMethodRaw(
            MACHINE1_DEST,
            MACHINE1_PATH,
            MACHINE1_IFACE,
            "MarkImageReadOnly",
        ) catch return MachineImageError.DbusError;
        defer _ = dbus.raw.sd_bus_message_unref(msg);

        const ro_int: c_int = if (read_only) 1 else 0;
        if (dbus.raw.sd_bus_message_append(msg, "sb", name_z.ptr, ro_int) < 0) {
            return MachineImageError.DbusError;
        }

        var reply = self.bus.callMessage(msg, &err) catch return MachineImageError.DbusError;
        reply.deinit();
    }

    /// Get the path where images are stored
    pub fn getImagesPath(self: *Self) MachineImageError![]const u8 {
        var err = dbus.Error.init();
        defer err.deinit();

        var reply = self.bus.getProperty(
            MACHINE1_DEST,
            MACHINE1_PATH,
            MACHINE1_IFACE,
            "PoolPath",
            &err,
            "s",
        ) catch return MachineImageError.DbusError;
        defer reply.deinit();

        const path = reply.readString() catch return MachineImageError.DbusError;
        return self.allocator.dupe(u8, path) catch return MachineImageError.OutOfMemory;
    }

    /// Check if an image exists
    pub fn imageExists(self: *Self, name: []const u8) bool {
        _ = self.getImage(name) catch return false;
        return true;
    }
};

/// Default machine images path
pub const DEFAULT_IMAGES_PATH = "/var/lib/machines";
