const std = @import("std");
const c = @cImport({
    @cInclude("sys/mount.h");
    @cInclude("errno.h");
    @cInclude("string.h");
});

pub const MountError = error{
    PermissionDenied,
    NotFound,
    InvalidArgument,
    Busy,
    OutOfMemory,
    SystemError,
};

pub const MountFlags = packed struct {
    rdonly: bool = false,
    nosuid: bool = false,
    nodev: bool = false,
    noexec: bool = false,
    synchronous: bool = false,
    remount: bool = false,
    mandlock: bool = false,
    dirsync: bool = false,
    noatime: bool = false,
    nodiratime: bool = false,
    bind: bool = false,
    move: bool = false,
    rec: bool = false,
    silent: bool = false,
    posixacl: bool = false,
    unbindable: bool = false,
    private: bool = false,
    slave: bool = false,
    shared: bool = false,
    relatime: bool = false,
    kernmount: bool = false,
    i_version: bool = false,
    strictatime: bool = false,
    lazytime: bool = false,
    _padding: u8 = 0,

    pub fn toInt(self: MountFlags) c_ulong {
        var flags: c_ulong = 0;
        if (self.rdonly) flags |= c.MS_RDONLY;
        if (self.nosuid) flags |= c.MS_NOSUID;
        if (self.nodev) flags |= c.MS_NODEV;
        if (self.noexec) flags |= c.MS_NOEXEC;
        if (self.synchronous) flags |= c.MS_SYNCHRONOUS;
        if (self.remount) flags |= c.MS_REMOUNT;
        if (self.mandlock) flags |= c.MS_MANDLOCK;
        if (self.dirsync) flags |= c.MS_DIRSYNC;
        if (self.noatime) flags |= c.MS_NOATIME;
        if (self.nodiratime) flags |= c.MS_NODIRATIME;
        if (self.bind) flags |= c.MS_BIND;
        if (self.move) flags |= c.MS_MOVE;
        if (self.rec) flags |= c.MS_REC;
        if (self.silent) flags |= c.MS_SILENT;
        if (self.posixacl) flags |= c.MS_POSIXACL;
        if (self.unbindable) flags |= c.MS_UNBINDABLE;
        if (self.private) flags |= c.MS_PRIVATE;
        if (self.slave) flags |= c.MS_SLAVE;
        if (self.shared) flags |= c.MS_SHARED;
        if (self.relatime) flags |= c.MS_RELATIME;
        if (self.strictatime) flags |= c.MS_STRICTATIME;
        if (self.lazytime) flags |= c.MS_LAZYTIME;
        return flags;
    }
};

/// Mount a filesystem
pub fn mount(
    source: ?[*:0]const u8,
    target: [*:0]const u8,
    fstype: ?[*:0]const u8,
    flags: MountFlags,
    data: ?[*:0]const u8,
) MountError!void {
    const result = c.mount(source, target, fstype, flags.toInt(), data);
    if (result < 0) {
        return mapErrno();
    }
}

/// Unmount a filesystem
pub fn umount(target: [*:0]const u8) MountError!void {
    const result = c.umount(target);
    if (result < 0) {
        return mapErrno();
    }
}

/// Unmount with flags
pub fn umount2(target: [*:0]const u8, flags: i32) MountError!void {
    const result = c.umount2(target, flags);
    if (result < 0) {
        return mapErrno();
    }
}

/// Lazy unmount - detach filesystem but allow existing references
pub fn umountLazy(target: [*:0]const u8) MountError!void {
    return umount2(target, c.MNT_DETACH);
}

/// Force unmount
pub fn umountForce(target: [*:0]const u8) MountError!void {
    return umount2(target, c.MNT_FORCE);
}

/// Bind mount
pub fn bindMount(source: [*:0]const u8, target: [*:0]const u8, readonly: bool) MountError!void {
    // First do the bind mount
    try mount(source, target, null, .{ .bind = true }, null);

    // If readonly, remount with rdonly flag
    if (readonly) {
        try mount(null, target, null, .{ .bind = true, .remount = true, .rdonly = true }, null);
    }
}

/// Make a mount point private (no propagation)
pub fn makePrivate(target: [*:0]const u8) MountError!void {
    try mount(null, target, null, .{ .private = true, .rec = true }, null);
}

/// Make a mount point shared
pub fn makeShared(target: [*:0]const u8) MountError!void {
    try mount(null, target, null, .{ .shared = true, .rec = true }, null);
}

/// Make a mount point slave
pub fn makeSlave(target: [*:0]const u8) MountError!void {
    try mount(null, target, null, .{ .slave = true, .rec = true }, null);
}

fn mapErrno() MountError {
    const errno = std.c._errno().*;
    return switch (errno) {
        c.EACCES, c.EPERM => MountError.PermissionDenied,
        c.ENOENT, c.ENOTDIR => MountError.NotFound,
        c.EINVAL => MountError.InvalidArgument,
        c.EBUSY => MountError.Busy,
        c.ENOMEM => MountError.OutOfMemory,
        else => MountError.SystemError,
    };
}

/// Mount info from /proc/self/mountinfo
pub const MountInfo = struct {
    mount_id: u32,
    parent_id: u32,
    device: []const u8,
    root: []const u8,
    mount_point: []const u8,
    mount_options: []const u8,
    fs_type: []const u8,
    mount_source: []const u8,
    super_options: []const u8,

    pub fn deinit(self: *MountInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.device);
        allocator.free(self.root);
        allocator.free(self.mount_point);
        allocator.free(self.mount_options);
        allocator.free(self.fs_type);
        allocator.free(self.mount_source);
        allocator.free(self.super_options);
    }
};

/// Check if a path is a mount point
pub fn isMountPoint(allocator: std.mem.Allocator, path: []const u8) !bool {
    const file = std.fs.openFileAbsolute("/proc/self/mountinfo", .{}) catch return false;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return false;
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Parse mount point from the line (5th field)
        var fields = std.mem.splitScalar(u8, line, ' ');
        var field_idx: usize = 0;
        while (fields.next()) |field| : (field_idx += 1) {
            if (field_idx == 4) {
                // Unescape mount point
                if (std.mem.eql(u8, field, path)) {
                    return true;
                }
                break;
            }
        }
    }
    return false;
}

test "MountFlags" {
    const flags = MountFlags{ .rdonly = true, .nosuid = true, .bind = true };
    const int_flags = flags.toInt();
    try std.testing.expect(int_flags & c.MS_RDONLY != 0);
    try std.testing.expect(int_flags & c.MS_NOSUID != 0);
    try std.testing.expect(int_flags & c.MS_BIND != 0);
}
