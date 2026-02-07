const std = @import("std");
const dbus = @import("dbus.zig");
const c = dbus.raw;

pub const PropertyError = error{
    AppendFailed,
    OutOfMemory,
};

/// Helper for building D-Bus property arrays for StartTransientUnit
pub const PropertyBuilder = struct {
    msg: *c.sd_bus_message,

    const Self = @This();

    /// Start building properties (opens the array container)
    pub fn begin(msg: *c.sd_bus_message) PropertyError!Self {
        // Properties are sent as a(sv) - array of (string, variant)
        const r = c.sd_bus_message_open_container(msg, 'a', "(sv)");
        if (r < 0) {
            return PropertyError.AppendFailed;
        }
        return Self{ .msg = msg };
    }

    /// Finish building properties (closes the array container)
    pub fn end(self: *Self) PropertyError!void {
        const r = c.sd_bus_message_close_container(self.msg);
        if (r < 0) {
            return PropertyError.AppendFailed;
        }
    }

    /// Add a string property
    pub fn addString(self: *Self, name: [*:0]const u8, value: [*:0]const u8) PropertyError!void {
        var r = c.sd_bus_message_open_container(self.msg, 'r', "sv");
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_append(self.msg, "s", name);
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_open_container(self.msg, 'v', "s");
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_append(self.msg, "s", value);
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_close_container(self.msg);
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_close_container(self.msg);
        if (r < 0) return PropertyError.AppendFailed;
    }

    /// Add a boolean property
    pub fn addBool(self: *Self, name: [*:0]const u8, value: bool) PropertyError!void {
        var r = c.sd_bus_message_open_container(self.msg, 'r', "sv");
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_append(self.msg, "s", name);
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_open_container(self.msg, 'v', "b");
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_append(self.msg, "b", @as(c_int, if (value) 1 else 0));
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_close_container(self.msg);
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_close_container(self.msg);
        if (r < 0) return PropertyError.AppendFailed;
    }

    /// Add a uint32 property
    pub fn addUint32(self: *Self, name: [*:0]const u8, value: u32) PropertyError!void {
        var r = c.sd_bus_message_open_container(self.msg, 'r', "sv");
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_append(self.msg, "s", name);
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_open_container(self.msg, 'v', "u");
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_append(self.msg, "u", value);
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_close_container(self.msg);
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_close_container(self.msg);
        if (r < 0) return PropertyError.AppendFailed;
    }

    /// Add a uint64 property
    pub fn addUint64(self: *Self, name: [*:0]const u8, value: u64) PropertyError!void {
        var r = c.sd_bus_message_open_container(self.msg, 'r', "sv");
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_append(self.msg, "s", name);
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_open_container(self.msg, 'v', "t");
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_append(self.msg, "t", value);
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_close_container(self.msg);
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_close_container(self.msg);
        if (r < 0) return PropertyError.AppendFailed;
    }

    /// Add a string array property
    pub fn addStringArray(self: *Self, name: [*:0]const u8, values: []const [*:0]const u8) PropertyError!void {
        var r = c.sd_bus_message_open_container(self.msg, 'r', "sv");
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_append(self.msg, "s", name);
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_open_container(self.msg, 'v', "as");
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_open_container(self.msg, 'a', "s");
        if (r < 0) return PropertyError.AppendFailed;

        for (values) |value| {
            r = c.sd_bus_message_append(self.msg, "s", value);
            if (r < 0) return PropertyError.AppendFailed;
        }

        r = c.sd_bus_message_close_container(self.msg);
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_close_container(self.msg);
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_close_container(self.msg);
        if (r < 0) return PropertyError.AppendFailed;
    }

    /// Add ExecStart property for a service
    /// Format: a(sasb) - array of (path, argv, ignore_failure)
    pub fn addExecStart(self: *Self, path: [*:0]const u8, argv: []const [*:0]const u8, ignore_failure: bool) PropertyError!void {
        var r = c.sd_bus_message_open_container(self.msg, 'r', "sv");
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_append(self.msg, "s", "ExecStart");
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_open_container(self.msg, 'v', "a(sasb)");
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_open_container(self.msg, 'a', "(sasb)");
        if (r < 0) return PropertyError.AppendFailed;

        // One exec entry
        r = c.sd_bus_message_open_container(self.msg, 'r', "sasb");
        if (r < 0) return PropertyError.AppendFailed;

        // Path
        r = c.sd_bus_message_append(self.msg, "s", path);
        if (r < 0) return PropertyError.AppendFailed;

        // Argv array
        r = c.sd_bus_message_open_container(self.msg, 'a', "s");
        if (r < 0) return PropertyError.AppendFailed;

        for (argv) |arg| {
            r = c.sd_bus_message_append(self.msg, "s", arg);
            if (r < 0) return PropertyError.AppendFailed;
        }

        r = c.sd_bus_message_close_container(self.msg);
        if (r < 0) return PropertyError.AppendFailed;

        // Ignore failure flag
        r = c.sd_bus_message_append(self.msg, "b", @as(c_int, if (ignore_failure) 1 else 0));
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_close_container(self.msg);
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_close_container(self.msg);
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_close_container(self.msg);
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_close_container(self.msg);
        if (r < 0) return PropertyError.AppendFailed;
    }

    /// Add Environment property
    /// Format: as - array of "KEY=VALUE" strings
    pub fn addEnvironment(self: *Self, env_vars: []const [*:0]const u8) PropertyError!void {
        return self.addStringArray("Environment", env_vars);
    }
};

/// Common property presets for pod services
pub const PodServiceProperties = struct {
    /// Set the slice for the service (for resource control hierarchy)
    pub fn setSlice(builder: *PropertyBuilder, slice: [*:0]const u8) PropertyError!void {
        try builder.addString("Slice", slice);
    }

    /// Set the description
    pub fn setDescription(builder: *PropertyBuilder, description: [*:0]const u8) PropertyError!void {
        try builder.addString("Description", description);
    }

    /// Make the service remain after exit (Type=oneshot behavior for pause container)
    pub fn setRemainAfterExit(builder: *PropertyBuilder, value: bool) PropertyError!void {
        try builder.addBool("RemainAfterExit", value);
    }

    /// Set memory limit in bytes
    pub fn setMemoryLimit(builder: *PropertyBuilder, bytes: u64) PropertyError!void {
        try builder.addUint64("MemoryMax", bytes);
    }

    /// Set CPU quota (in microseconds per second, e.g., 100000 = 10%)
    pub fn setCPUQuota(builder: *PropertyBuilder, quota_us: u64) PropertyError!void {
        try builder.addUint64("CPUQuotaPerSecUSec", quota_us);
    }

    /// Set the service type
    pub fn setType(builder: *PropertyBuilder, service_type: [*:0]const u8) PropertyError!void {
        try builder.addString("Type", service_type);
    }

    /// Add a bind mount
    /// Format: a(ssbt) for BindPaths - array of (source, dest, ignore_errors, flags)
    pub fn addBindMount(builder: *PropertyBuilder, source: [*:0]const u8, dest: [*:0]const u8, read_only: bool) PropertyError!void {
        const msg = builder.msg;
        var r = c.sd_bus_message_open_container(msg, 'r', "sv");
        if (r < 0) return PropertyError.AppendFailed;

        const prop_name: [*:0]const u8 = if (read_only) "BindReadOnlyPaths" else "BindPaths";
        r = c.sd_bus_message_append(msg, "s", prop_name);
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_open_container(msg, 'v', "a(ssbt)");
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_open_container(msg, 'a', "(ssbt)");
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_open_container(msg, 'r', "ssbt");
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_append(msg, "s", source);
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_append(msg, "s", dest);
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_append(msg, "b", @as(c_int, 0)); // ignore_errors = false
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_append(msg, "t", @as(u64, 0)); // flags = 0
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_close_container(msg);
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_close_container(msg);
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_close_container(msg);
        if (r < 0) return PropertyError.AppendFailed;

        r = c.sd_bus_message_close_container(msg);
        if (r < 0) return PropertyError.AppendFailed;
    }
};

/// Append an empty auxiliary units array (required for StartTransientUnit)
pub fn appendEmptyAuxUnits(msg: *c.sd_bus_message) PropertyError!void {
    // Auxiliary units: a(sa(sv)) - empty array
    const r = c.sd_bus_message_open_container(msg, 'a', "(sa(sv))");
    if (r < 0) return PropertyError.AppendFailed;
    const r2 = c.sd_bus_message_close_container(msg);
    if (r2 < 0) return PropertyError.AppendFailed;
}
