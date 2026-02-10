const std = @import("std");
const dbus = @import("dbus.zig");
const properties = @import("properties.zig");
const c = dbus.raw;

pub const ManagerError = error{
    ConnectionFailed,
    CallFailed,
    UnitNotFound,
    InvalidState,
    OutOfMemory,
};

/// Unit state as reported by systemd
pub const UnitState = enum {
    active,
    reloading,
    inactive,
    failed,
    activating,
    deactivating,
    unknown,

    pub fn fromString(s: []const u8) UnitState {
        if (std.mem.eql(u8, s, "active")) return .active;
        if (std.mem.eql(u8, s, "reloading")) return .reloading;
        if (std.mem.eql(u8, s, "inactive")) return .inactive;
        if (std.mem.eql(u8, s, "failed")) return .failed;
        if (std.mem.eql(u8, s, "activating")) return .activating;
        if (std.mem.eql(u8, s, "deactivating")) return .deactivating;
        return .unknown;
    }
};

/// Unit substate provides more detail
pub const UnitSubState = enum {
    dead,
    running,
    exited,
    waiting,
    start_pre,
    start,
    start_post,
    stop,
    stop_sigterm,
    stop_sigkill,
    stop_post,
    final_sigterm,
    final_sigkill,
    failed,
    auto_restart,
    unknown,

    pub fn fromString(s: []const u8) UnitSubState {
        if (std.mem.eql(u8, s, "dead")) return .dead;
        if (std.mem.eql(u8, s, "running")) return .running;
        if (std.mem.eql(u8, s, "exited")) return .exited;
        if (std.mem.eql(u8, s, "waiting")) return .waiting;
        if (std.mem.eql(u8, s, "start-pre")) return .start_pre;
        if (std.mem.eql(u8, s, "start")) return .start;
        if (std.mem.eql(u8, s, "start-post")) return .start_post;
        if (std.mem.eql(u8, s, "stop")) return .stop;
        if (std.mem.eql(u8, s, "stop-sigterm")) return .stop_sigterm;
        if (std.mem.eql(u8, s, "stop-sigkill")) return .stop_sigkill;
        if (std.mem.eql(u8, s, "stop-post")) return .stop_post;
        if (std.mem.eql(u8, s, "final-sigterm")) return .final_sigterm;
        if (std.mem.eql(u8, s, "final-sigkill")) return .final_sigkill;
        if (std.mem.eql(u8, s, "failed")) return .failed;
        if (std.mem.eql(u8, s, "auto-restart")) return .auto_restart;
        return .unknown;
    }
};

/// Information about a systemd unit
pub const UnitInfo = struct {
    name: []const u8,
    description: []const u8,
    load_state: []const u8,
    active_state: UnitState,
    sub_state: UnitSubState,
    object_path: []const u8,

    pub fn deinit(self: *UnitInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.load_state);
        allocator.free(self.object_path);
    }
};

const SYSTEMD_DEST = "org.freedesktop.systemd1";
const SYSTEMD_PATH = "/org/freedesktop/systemd1";
const MANAGER_IFACE = "org.freedesktop.systemd1.Manager";
const UNIT_IFACE = "org.freedesktop.systemd1.Unit";
const SERVICE_IFACE = "org.freedesktop.systemd1.Service";

/// Wrapper for systemd1.Manager D-Bus interface
pub const Manager = struct {
    bus: *dbus.Bus,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(bus: *dbus.Bus, allocator: std.mem.Allocator) Self {
        return Self{
            .bus = bus,
            .allocator = allocator,
        };
    }

    /// Start a transient service unit with context
    /// Returns the job object path
    pub fn startTransientServiceWithContext(
        self: *Self,
        name: [*:0]const u8,
        mode: [*:0]const u8,
        context: anytype,
        comptime configureFn: fn (*properties.PropertyBuilder, @TypeOf(context)) anyerror!void,
    ) ManagerError![]const u8 {
        // Create method call message
        const msg = self.bus.callMethodRaw(
            SYSTEMD_DEST,
            SYSTEMD_PATH,
            MANAGER_IFACE,
            "StartTransientUnit",
        ) catch return ManagerError.CallFailed;
        defer _ = c.sd_bus_message_unref(msg);

        // Append unit name
        var r = c.sd_bus_message_append(msg, "s", name);
        if (r < 0) return ManagerError.CallFailed;

        // Append mode (e.g., "fail", "replace")
        r = c.sd_bus_message_append(msg, "s", mode);
        if (r < 0) return ManagerError.CallFailed;

        // Build properties
        var builder = properties.PropertyBuilder.begin(msg) catch return ManagerError.CallFailed;
        configureFn(&builder, context) catch return ManagerError.CallFailed;
        builder.end() catch return ManagerError.CallFailed;

        // Append empty auxiliary units array
        properties.appendEmptyAuxUnits(msg) catch return ManagerError.CallFailed;

        // Call the method
        var err = dbus.Error.init();
        defer err.deinit();

        var reply = self.bus.callMessage(msg, &err) catch {
            if (err.getMessage()) |error_msg| {
                std.log.err("StartTransientUnit failed: {s}", .{error_msg});
            }
            return ManagerError.CallFailed;
        };
        defer reply.deinit();

        // Read the job path from reply
        const job_path = reply.readObjectPath() catch return ManagerError.CallFailed;
        return self.allocator.dupe(u8, job_path) catch return ManagerError.OutOfMemory;
    }

    /// Start a transient service unit
    /// Returns the job object path
    pub fn startTransientService(
        self: *Self,
        name: [*:0]const u8,
        mode: [*:0]const u8,
        configureFn: *const fn (*properties.PropertyBuilder) anyerror!void,
    ) ManagerError![]const u8 {
        // Create method call message
        const msg = self.bus.callMethodRaw(
            SYSTEMD_DEST,
            SYSTEMD_PATH,
            MANAGER_IFACE,
            "StartTransientUnit",
        ) catch return ManagerError.CallFailed;
        defer _ = c.sd_bus_message_unref(msg);

        // Append unit name
        var r = c.sd_bus_message_append(msg, "s", name);
        if (r < 0) return ManagerError.CallFailed;

        // Append mode (e.g., "fail", "replace")
        r = c.sd_bus_message_append(msg, "s", mode);
        if (r < 0) return ManagerError.CallFailed;

        // Build properties
        var builder = properties.PropertyBuilder.begin(msg) catch return ManagerError.CallFailed;
        configureFn(&builder) catch return ManagerError.CallFailed;
        builder.end() catch return ManagerError.CallFailed;

        // Append empty auxiliary units array
        properties.appendEmptyAuxUnits(msg) catch return ManagerError.CallFailed;

        // Call the method
        var err = dbus.Error.init();
        defer err.deinit();

        var reply = self.bus.callMessage(msg, &err) catch {
            if (err.getMessage()) |error_msg| {
                std.log.err("StartTransientUnit failed: {s}", .{error_msg});
            }
            return ManagerError.CallFailed;
        };
        defer reply.deinit();

        // Read the job path from reply
        const job_path = reply.readObjectPath() catch return ManagerError.CallFailed;
        return self.allocator.dupe(u8, job_path) catch return ManagerError.OutOfMemory;
    }

    /// Stop a unit
    pub fn stopUnit(self: *Self, name: [*:0]const u8, mode: [*:0]const u8) ManagerError![]const u8 {
        var err = dbus.Error.init();
        defer err.deinit();

        var reply = dbus.Message.init();
        defer reply.deinit();

        self.bus.call(
            SYSTEMD_DEST,
            SYSTEMD_PATH,
            MANAGER_IFACE,
            "StopUnit",
            &err,
            &reply,
            "ss",
        ) catch {
            // Need to actually append the arguments - use raw method instead
            _ = name;
            _ = mode;
            return ManagerError.CallFailed;
        };

        const job_path = reply.readObjectPath() catch return ManagerError.CallFailed;
        return self.allocator.dupe(u8, job_path) catch return ManagerError.OutOfMemory;
    }

    /// Stop a unit (using raw message building)
    pub fn stopUnitRaw(self: *Self, name: [*:0]const u8, mode: [*:0]const u8) ManagerError![]const u8 {
        const msg = self.bus.callMethodRaw(
            SYSTEMD_DEST,
            SYSTEMD_PATH,
            MANAGER_IFACE,
            "StopUnit",
        ) catch return ManagerError.CallFailed;
        defer _ = c.sd_bus_message_unref(msg);

        const r = c.sd_bus_message_append(msg, "ss", name, mode);
        if (r < 0) return ManagerError.CallFailed;

        var err = dbus.Error.init();
        defer err.deinit();

        var reply = self.bus.callMessage(msg, &err) catch {
            if (err.getMessage()) |error_msg| {
                std.log.err("StopUnit failed: {s}", .{error_msg});
            }
            return ManagerError.CallFailed;
        };
        defer reply.deinit();

        const job_path = reply.readObjectPath() catch return ManagerError.CallFailed;
        return self.allocator.dupe(u8, job_path) catch return ManagerError.OutOfMemory;
    }

    /// Get the object path for a unit
    pub fn getUnit(self: *Self, name: [*:0]const u8) ManagerError![]const u8 {
        const msg = self.bus.callMethodRaw(
            SYSTEMD_DEST,
            SYSTEMD_PATH,
            MANAGER_IFACE,
            "GetUnit",
        ) catch return ManagerError.CallFailed;
        defer _ = c.sd_bus_message_unref(msg);

        const r = c.sd_bus_message_append(msg, "s", name);
        if (r < 0) return ManagerError.CallFailed;

        var err = dbus.Error.init();
        defer err.deinit();

        var reply = self.bus.callMessage(msg, &err) catch {
            if (err.getName()) |error_name| {
                if (std.mem.eql(u8, error_name, "org.freedesktop.systemd1.NoSuchUnit")) {
                    return ManagerError.UnitNotFound;
                }
            }
            return ManagerError.CallFailed;
        };
        defer reply.deinit();

        const unit_path = reply.readObjectPath() catch return ManagerError.CallFailed;
        return self.allocator.dupe(u8, unit_path) catch return ManagerError.OutOfMemory;
    }

    /// Reset a failed unit
    pub fn resetFailedUnit(self: *Self, name: [*:0]const u8) ManagerError!void {
        const msg = self.bus.callMethodRaw(
            SYSTEMD_DEST,
            SYSTEMD_PATH,
            MANAGER_IFACE,
            "ResetFailedUnit",
        ) catch return ManagerError.CallFailed;
        defer _ = c.sd_bus_message_unref(msg);

        const r = c.sd_bus_message_append(msg, "s", name);
        if (r < 0) return ManagerError.CallFailed;

        var err = dbus.Error.init();
        defer err.deinit();

        var reply = self.bus.callMessage(msg, &err) catch {
            return ManagerError.CallFailed;
        };
        defer reply.deinit();
    }

    /// Get the active state of a unit
    pub fn getUnitActiveState(self: *Self, unit_path: [*:0]const u8) ManagerError!UnitState {
        var err = dbus.Error.init();
        defer err.deinit();

        var reply = self.bus.getProperty(
            SYSTEMD_DEST,
            unit_path,
            UNIT_IFACE,
            "ActiveState",
            &err,
            "s",
        ) catch return ManagerError.CallFailed;
        defer reply.deinit();

        // Enter variant
        reply.enterContainer('v', "s") catch return ManagerError.CallFailed;

        const state_str = reply.readString() catch return ManagerError.CallFailed;
        return UnitState.fromString(state_str);
    }

    /// Get the sub state of a unit
    pub fn getUnitSubState(self: *Self, unit_path: [*:0]const u8) ManagerError!UnitSubState {
        var err = dbus.Error.init();
        defer err.deinit();

        var reply = self.bus.getProperty(
            SYSTEMD_DEST,
            unit_path,
            UNIT_IFACE,
            "SubState",
            &err,
            "s",
        ) catch return ManagerError.CallFailed;
        defer reply.deinit();

        // Enter variant
        reply.enterContainer('v', "s") catch return ManagerError.CallFailed;

        const state_str = reply.readString() catch return ManagerError.CallFailed;
        return UnitSubState.fromString(state_str);
    }

    /// Get the main PID of a service by calling systemctl show
    pub fn getServiceMainPID(self: *Self, unit_path: [*:0]const u8) ManagerError!u32 {
        // Extract unit name from path (e.g., /org/freedesktop/systemd1/unit/cri_2dcontainer_2dxxx_2eservice)
        const path_str = std.mem.span(unit_path);

        // Find the last '/' to get the unit name part
        var unit_name_encoded: []const u8 = path_str;
        if (std.mem.lastIndexOf(u8, path_str, "/")) |idx| {
            unit_name_encoded = path_str[idx + 1 ..];
        }

        // Decode the unit name (replace _2d with -, _2e with .)
        var unit_name_buf: [256]u8 = undefined;
        var unit_name_len: usize = 0;
        var i: usize = 0;
        while (i < unit_name_encoded.len) {
            if (i + 2 < unit_name_encoded.len and unit_name_encoded[i] == '_' and unit_name_encoded[i + 1] == '2') {
                if (unit_name_encoded[i + 2] == 'd') {
                    unit_name_buf[unit_name_len] = '-';
                    unit_name_len += 1;
                    i += 3;
                    continue;
                } else if (unit_name_encoded[i + 2] == 'e') {
                    unit_name_buf[unit_name_len] = '.';
                    unit_name_len += 1;
                    i += 3;
                    continue;
                }
            }
            unit_name_buf[unit_name_len] = unit_name_encoded[i];
            unit_name_len += 1;
            i += 1;
        }

        if (unit_name_len == 0) return ManagerError.UnitNotFound;

        // Run systemctl show --property=MainPID <unit_name>
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{
                "systemctl",
                "show",
                "--property=MainPID",
                unit_name_buf[0..unit_name_len],
            },
        }) catch return ManagerError.CallFailed;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        // Parse the output: "MainPID=12345\n"
        const output = result.stdout;
        if (std.mem.startsWith(u8, output, "MainPID=")) {
            const pid_str = std.mem.trim(u8, output[8..], " \n\r");
            const pid = std.fmt.parseInt(u32, pid_str, 10) catch return ManagerError.CallFailed;
            if (pid == 0) return ManagerError.CallFailed;
            return pid;
        }

        return ManagerError.CallFailed;
    }

    /// List all units matching a pattern
    pub fn listUnitsByPatterns(
        self: *Self,
        states: []const [*:0]const u8,
        patterns: []const [*:0]const u8,
    ) ManagerError!std.ArrayList(UnitInfo) {
        const msg = self.bus.callMethodRaw(
            SYSTEMD_DEST,
            SYSTEMD_PATH,
            MANAGER_IFACE,
            "ListUnitsByPatterns",
        ) catch return ManagerError.CallFailed;
        defer _ = c.sd_bus_message_unref(msg);

        // States array
        var r = c.sd_bus_message_open_container(msg, 'a', "s");
        if (r < 0) return ManagerError.CallFailed;
        for (states) |state| {
            r = c.sd_bus_message_append(msg, "s", state);
            if (r < 0) return ManagerError.CallFailed;
        }
        r = c.sd_bus_message_close_container(msg);
        if (r < 0) return ManagerError.CallFailed;

        // Patterns array
        r = c.sd_bus_message_open_container(msg, 'a', "s");
        if (r < 0) return ManagerError.CallFailed;
        for (patterns) |pattern| {
            r = c.sd_bus_message_append(msg, "s", pattern);
            if (r < 0) return ManagerError.CallFailed;
        }
        r = c.sd_bus_message_close_container(msg);
        if (r < 0) return ManagerError.CallFailed;

        var err = dbus.Error.init();
        defer err.deinit();

        var reply = self.bus.callMessage(msg, &err) catch return ManagerError.CallFailed;
        defer reply.deinit();

        var units = std.ArrayList(UnitInfo).init(self.allocator);
        errdefer {
            for (units.items) |*unit| {
                unit.deinit(self.allocator);
            }
            units.deinit();
        }

        // Parse reply: a(ssssssouso)
        // name, description, load_state, active_state, sub_state, following, unit_path, job_id, job_type, job_path
        reply.enterContainer('a', "(ssssssouso)") catch return ManagerError.CallFailed;

        while (reply.peekType()) |t| {
            if (t != 'r') break;

            reply.enterContainer('r', "ssssssouso") catch break;

            const name = reply.readString() catch break;
            const description = reply.readString() catch break;
            const load_state = reply.readString() catch break;
            const active_state_str = reply.readString() catch break;
            const sub_state_str = reply.readString() catch break;

            // Skip: following
            _ = reply.skip("s") catch break;

            const object_path = reply.readObjectPath() catch break;

            // Skip: job_id, job_type, job_path
            _ = reply.skip("uso") catch break;

            reply.exitContainer() catch break;

            const unit_info = UnitInfo{
                .name = self.allocator.dupe(u8, name) catch return ManagerError.OutOfMemory,
                .description = self.allocator.dupe(u8, description) catch return ManagerError.OutOfMemory,
                .load_state = self.allocator.dupe(u8, load_state) catch return ManagerError.OutOfMemory,
                .active_state = UnitState.fromString(active_state_str),
                .sub_state = UnitSubState.fromString(sub_state_str),
                .object_path = self.allocator.dupe(u8, object_path) catch return ManagerError.OutOfMemory,
            };

            units.append(unit_info) catch return ManagerError.OutOfMemory;
        }

        return units;
    }
};

/// Generate a pod service unit name
pub fn podServiceName(id: []const u8, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "cri-pod-{s}.service", .{id}) catch return error.BufferTooSmall;
}

/// Generate a container service unit name
pub fn containerScopeName(id: []const u8, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "cri-container-{s}.service", .{id}) catch return error.BufferTooSmall;
}
