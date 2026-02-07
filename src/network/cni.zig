const std = @import("std");
const json = std.json;
const logging = @import("../util/logging.zig");

pub const CniError = error{
    PluginNotFound,
    ConfigNotFound,
    InvalidConfig,
    ExecFailed,
    NetworkSetupFailed,
    NetworkTeardownFailed,
    OutOfMemory,
};

/// CNI network configuration
pub const NetworkConfig = struct {
    cni_version: []const u8,
    name: []const u8,
    type: []const u8,
    bridge: ?[]const u8 = null,
    is_gateway: bool = false,
    is_default_gateway: bool = false,
    force_address: bool = false,
    ip_masq: bool = false,
    mtu: ?u32 = null,
    hairpin_mode: bool = false,
    ipam: ?IpamConfig = null,
    dns: ?DnsConfig = null,
};

pub const IpamConfig = struct {
    type: []const u8,
    subnet: ?[]const u8 = null,
    range_start: ?[]const u8 = null,
    range_end: ?[]const u8 = null,
    gateway: ?[]const u8 = null,
    routes: ?[]const Route = null,
};

pub const Route = struct {
    dst: []const u8,
    gw: ?[]const u8 = null,
};

pub const DnsConfig = struct {
    nameservers: []const []const u8 = &.{},
    domain: ?[]const u8 = null,
    search: []const []const u8 = &.{},
    options: []const []const u8 = &.{},
};

/// CNI result from plugin execution
pub const CniResult = struct {
    cni_version: []const u8,
    interfaces: []const Interface = &.{},
    ips: []const IpConfig = &.{},
    routes: []const Route = &.{},
    dns: ?DnsConfig = null,

    pub fn deinit(self: *CniResult, allocator: std.mem.Allocator) void {
        allocator.free(self.cni_version);
        for (self.interfaces) |iface| {
            allocator.free(iface.name);
            if (iface.mac) |mac| allocator.free(mac);
            if (iface.sandbox) |sb| allocator.free(sb);
        }
        allocator.free(self.interfaces);
        for (self.ips) |ip| {
            allocator.free(ip.address);
            if (ip.gateway) |gw| allocator.free(gw);
        }
        allocator.free(self.ips);
    }
};

pub const Interface = struct {
    name: []const u8,
    mac: ?[]const u8 = null,
    sandbox: ?[]const u8 = null,
};

pub const IpConfig = struct {
    interface: ?u32 = null,
    address: []const u8,
    gateway: ?[]const u8 = null,
};

/// CNI plugin executor
pub const Cni = struct {
    allocator: std.mem.Allocator,
    plugin_dirs: []const []const u8,
    config_dir: []const u8,
    default_network: ?[]const u8,

    const Self = @This();

    pub const DEFAULT_PLUGIN_DIRS = &[_][]const u8{
        "/opt/cni/bin",
        "/usr/lib/cni",
        "/usr/libexec/cni",
    };
    pub const DEFAULT_CONFIG_DIR = "/etc/cni/net.d";

    pub fn init(allocator: std.mem.Allocator, config: ?CniConfig) Self {
        const cfg = config orelse CniConfig{};
        return Self{
            .allocator = allocator,
            .plugin_dirs = cfg.plugin_dirs orelse DEFAULT_PLUGIN_DIRS,
            .config_dir = cfg.config_dir orelse DEFAULT_CONFIG_DIR,
            .default_network = cfg.default_network,
        };
    }

    /// Load network configuration from config directory
    pub fn loadNetworkConfig(self: *Self, name: ?[]const u8) !NetworkConfig {
        const network_name = name orelse self.default_network orelse {
            // Find first config file
            var dir = std.fs.openDirAbsolute(self.config_dir, .{ .iterate = true }) catch {
                return CniError.ConfigNotFound;
            };
            defer dir.close();

            var iter = dir.iterate();
            while (iter.next() catch return CniError.ConfigNotFound) |entry| {
                if (entry.kind != .file) continue;
                if (std.mem.endsWith(u8, entry.name, ".conf") or
                    std.mem.endsWith(u8, entry.name, ".conflist") or
                    std.mem.endsWith(u8, entry.name, ".json"))
                {
                    const path = std.fs.path.join(self.allocator, &.{ self.config_dir, entry.name }) catch return CniError.OutOfMemory;
                    defer self.allocator.free(path);
                    return self.parseConfigFile(path);
                }
            }
            return CniError.ConfigNotFound;
        };

        // Find config file for network
        const config_path = std.fs.path.join(self.allocator, &.{ self.config_dir, network_name }) catch return CniError.OutOfMemory;
        defer self.allocator.free(config_path);

        return self.parseConfigFile(config_path);
    }

    fn parseConfigFile(self: *Self, path: []const u8) !NetworkConfig {
        const file = std.fs.openFileAbsolute(path, .{}) catch return CniError.ConfigNotFound;
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 1024 * 1024) catch return CniError.ConfigNotFound;
        defer self.allocator.free(content);

        // TODO: Parse JSON config - for now just read and free the content
        if (content.len == 0) {
            return CniError.InvalidConfig;
        }
        return CniError.InvalidConfig;
    }

    /// Find a CNI plugin binary
    pub fn findPlugin(self: *Self, plugin_type: []const u8) ![]const u8 {
        for (self.plugin_dirs) |dir| {
            const path = std.fs.path.join(self.allocator, &.{ dir, plugin_type }) catch continue;
            errdefer self.allocator.free(path);

            std.fs.accessAbsolute(path, .{}) catch {
                self.allocator.free(path);
                continue;
            };

            return path;
        }
        return CniError.PluginNotFound;
    }

    /// Setup network for a pod
    pub fn setupNetwork(
        self: *Self,
        pod_id: []const u8,
        netns_path: []const u8,
        ifname: []const u8,
        config: *const NetworkConfig,
    ) !CniResult {
        logging.info("Setting up network for pod {s}", .{pod_id});

        const plugin_path = try self.findPlugin(config.type);
        defer self.allocator.free(plugin_path);

        // Build CNI_ARGS
        const cni_args = std.fmt.allocPrint(
            self.allocator,
            "IgnoreUnknown=1;K8S_POD_NAMESPACE=default;K8S_POD_NAME={s};K8S_POD_INFRA_CONTAINER_ID={s}",
            .{ pod_id, pod_id },
        ) catch return CniError.OutOfMemory;
        defer self.allocator.free(cni_args);

        // Build config JSON
        var config_json: std.ArrayList(u8) = .empty;
        defer config_json.deinit(self.allocator);

        const w = config_json.writer(self.allocator);
        try w.writeAll("{");
        try w.print("\"cniVersion\":\"{s}\",", .{config.cni_version});
        try w.print("\"name\":\"{s}\",", .{config.name});
        try w.print("\"type\":\"{s}\"", .{config.type});
        if (config.bridge) |bridge| {
            try w.print(",\"bridge\":\"{s}\"", .{bridge});
        }
        if (config.is_gateway) {
            try w.writeAll(",\"isGateway\":true");
        }
        if (config.ip_masq) {
            try w.writeAll(",\"ipMasq\":true");
        }
        try w.writeAll("}");

        // Execute plugin
        const result = try self.execPlugin(
            plugin_path,
            "ADD",
            pod_id,
            netns_path,
            ifname,
            cni_args,
            config_json.items,
        );

        return result;
    }

    /// Teardown network for a pod
    pub fn teardownNetwork(
        self: *Self,
        pod_id: []const u8,
        netns_path: []const u8,
        ifname: []const u8,
        config: *const NetworkConfig,
    ) !void {
        logging.info("Tearing down network for pod {s}", .{pod_id});

        const plugin_path = self.findPlugin(config.type) catch return;
        defer self.allocator.free(plugin_path);

        // Build minimal config
        var config_json: std.ArrayList(u8) = .empty;
        defer config_json.deinit(self.allocator);

        const w = config_json.writer(self.allocator);
        try w.print("{{\"cniVersion\":\"{s}\",\"name\":\"{s}\",\"type\":\"{s}\"}}", .{
            config.cni_version,
            config.name,
            config.type,
        });

        _ = self.execPlugin(
            plugin_path,
            "DEL",
            pod_id,
            netns_path,
            ifname,
            "",
            config_json.items,
        ) catch {};
    }

    fn execPlugin(
        self: *Self,
        plugin_path: []const u8,
        command: []const u8,
        container_id: []const u8,
        netns: []const u8,
        ifname: []const u8,
        cni_args: []const u8,
        config: []const u8,
    ) !CniResult {
        // Set up environment
        var env_map = std.process.EnvMap.init(self.allocator);
        defer env_map.deinit();

        try env_map.put("CNI_COMMAND", command);
        try env_map.put("CNI_CONTAINERID", container_id);
        try env_map.put("CNI_NETNS", netns);
        try env_map.put("CNI_IFNAME", ifname);
        try env_map.put("CNI_ARGS", cni_args);
        try env_map.put("CNI_PATH", std.mem.join(self.allocator, ":", self.plugin_dirs) catch return CniError.OutOfMemory);

        var child = std.process.Child.init(&.{plugin_path}, self.allocator);
        child.env_map = &env_map;
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        // Write config to stdin
        try child.stdin.?.writeAll(config);
        child.stdin.?.close();
        child.stdin = null;

        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(stdout);

        const stderr = try child.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(stderr);

        const term = try child.wait();
        const exit_code = switch (term) {
            .Exited => |code| code,
            else => 255,
        };

        if (exit_code != 0) {
            logging.err("CNI plugin failed: {s}", .{stderr});
            return CniError.ExecFailed;
        }

        // Parse result
        // TODO: Parse JSON result
        return CniResult{
            .cni_version = try self.allocator.dupe(u8, "1.0.0"),
            .interfaces = &.{},
            .ips = &.{},
            .routes = &.{},
            .dns = null,
        };
    }
};

/// CNI configuration
pub const CniConfig = struct {
    plugin_dirs: ?[]const []const u8 = null,
    config_dir: ?[]const u8 = null,
    default_network: ?[]const u8 = null,
};

/// Create a network namespace
pub fn createNetns(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const netns_path = std.fmt.allocPrint(allocator, "/var/run/netns/{s}", .{name}) catch return error.OutOfMemory;
    errdefer allocator.free(netns_path);

    // Create parent directory
    std.fs.makeDirAbsolute("/var/run/netns") catch |e| {
        if (e != error.PathAlreadyExists) return e;
    };

    // Create namespace using ip netns add
    var child = std.process.Child.init(&.{ "ip", "netns", "add", name }, allocator);
    try child.spawn();
    const term = try child.wait();

    if (term != .Exited or term.Exited != 0) {
        return error.CreateFailed;
    }

    return netns_path;
}

/// Delete a network namespace
pub fn deleteNetns(name: []const u8) void {
    var child = std.process.Child.init(&.{ "ip", "netns", "delete", name }, std.heap.page_allocator);
    child.spawn() catch return;
    _ = child.wait() catch {};
}
