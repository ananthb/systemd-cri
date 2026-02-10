const std = @import("std");
const json = std.json;
const posix = std.posix;
const logging = @import("../util/logging.zig");

pub const CniError = error{
    PluginNotFound,
    ConfigNotFound,
    InvalidConfig,
    ExecFailed,
    NetworkSetupFailed,
    NetworkTeardownFailed,
    OutOfMemory,
    NamespaceError,
    ParseError,
};

/// CNI network configuration
pub const NetworkConfig = struct {
    cni_version: []const u8,
    name: []const u8,
    plugin_type: []const u8,
    bridge: ?[]const u8 = null,
    is_gateway: bool = false,
    is_default_gateway: bool = false,
    force_address: bool = false,
    ip_masq: bool = false,
    mtu: ?u32 = null,
    hairpin_mode: bool = false,
    ipam: ?IpamConfig = null,
    dns: ?DnsConfig = null,

    pub fn deinit(self: *NetworkConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.cni_version);
        allocator.free(self.name);
        allocator.free(self.plugin_type);
        if (self.bridge) |b| allocator.free(b);
        if (self.ipam) |*ipam| ipam.deinit(allocator);
        if (self.dns) |*dns| dns.deinit(allocator);
    }
};

pub const IpamConfig = struct {
    ipam_type: []const u8,
    subnet: ?[]const u8 = null,
    range_start: ?[]const u8 = null,
    range_end: ?[]const u8 = null,
    gateway: ?[]const u8 = null,
    routes: []Route = &.{},

    pub fn deinit(self: *IpamConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.ipam_type);
        if (self.subnet) |s| allocator.free(s);
        if (self.range_start) |rs| allocator.free(rs);
        if (self.range_end) |re| allocator.free(re);
        if (self.gateway) |g| allocator.free(g);
        for (self.routes) |*r| r.deinit(allocator);
        if (self.routes.len > 0) allocator.free(self.routes);
    }
};

pub const Route = struct {
    dst: []const u8,
    gw: ?[]const u8 = null,

    pub fn deinit(self: *Route, allocator: std.mem.Allocator) void {
        allocator.free(self.dst);
        if (self.gw) |g| allocator.free(g);
    }
};

pub const DnsConfig = struct {
    nameservers: [][]const u8 = &.{},
    domain: ?[]const u8 = null,
    search: [][]const u8 = &.{},
    options: [][]const u8 = &.{},

    pub fn deinit(self: *DnsConfig, allocator: std.mem.Allocator) void {
        for (self.nameservers) |ns| allocator.free(ns);
        if (self.nameservers.len > 0) allocator.free(self.nameservers);
        if (self.domain) |d| allocator.free(d);
        for (self.search) |s| allocator.free(s);
        if (self.search.len > 0) allocator.free(self.search);
        for (self.options) |o| allocator.free(o);
        if (self.options.len > 0) allocator.free(self.options);
    }
};

/// CNI result from plugin execution
pub const CniResult = struct {
    cni_version: []const u8,
    interfaces: []Interface = &.{},
    ips: []IpConfig = &.{},
    routes: []Route = &.{},
    dns: ?DnsConfig = null,

    pub fn deinit(self: *CniResult, allocator: std.mem.Allocator) void {
        allocator.free(self.cni_version);
        for (self.interfaces) |*iface| iface.deinit(allocator);
        if (self.interfaces.len > 0) allocator.free(self.interfaces);
        for (self.ips) |*ip| ip.deinit(allocator);
        if (self.ips.len > 0) allocator.free(self.ips);
        for (self.routes) |*r| r.deinit(allocator);
        if (self.routes.len > 0) allocator.free(self.routes);
        if (self.dns) |*dns| dns.deinit(allocator);
    }

    /// Get the first IP address from the result
    pub fn getIp(self: *const CniResult) ?[]const u8 {
        if (self.ips.len > 0) {
            return self.ips[0].address;
        }
        return null;
    }

    /// Get the first gateway from the result
    pub fn getGateway(self: *const CniResult) ?[]const u8 {
        if (self.ips.len > 0) {
            return self.ips[0].gateway;
        }
        return null;
    }
};

pub const Interface = struct {
    name: []const u8,
    mac: ?[]const u8 = null,
    sandbox: ?[]const u8 = null,

    pub fn deinit(self: *Interface, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.mac) |m| allocator.free(m);
        if (self.sandbox) |s| allocator.free(s);
    }
};

pub const IpConfig = struct {
    interface: ?u32 = null,
    address: []const u8,
    gateway: ?[]const u8 = null,

    pub fn deinit(self: *IpConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.address);
        if (self.gateway) |g| allocator.free(g);
    }
};

/// CNI plugin executor
pub const Cni = struct {
    allocator: std.mem.Allocator,
    plugin_dirs: []const []const u8,
    config_dir: []const u8,
    default_network: ?[]const u8,
    cached_config: ?NetworkConfig = null,

    const Self = @This();

    pub const DEFAULT_PLUGIN_DIRS = &[_][]const u8{
        "/opt/cni/bin",
        "/usr/lib/cni",
        "/usr/libexec/cni",
    };
    pub const DEFAULT_CONFIG_DIR = "/etc/cni/net.d";
    pub const DEFAULT_NETWORK_NAME = "cri-bridge";

    pub fn init(allocator: std.mem.Allocator, config: ?CniConfig) Self {
        const cfg = config orelse CniConfig{};
        return Self{
            .allocator = allocator,
            .plugin_dirs = cfg.plugin_dirs orelse DEFAULT_PLUGIN_DIRS,
            .config_dir = cfg.config_dir orelse DEFAULT_CONFIG_DIR,
            .default_network = cfg.default_network,
            .cached_config = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.cached_config) |*cfg| {
            cfg.deinit(self.allocator);
        }
    }

    /// Ensure default CNI configuration exists
    pub fn ensureDefaultConfig(self: *Self) !void {
        // Create config directory if needed
        std.fs.makeDirAbsolute(self.config_dir) catch |e| {
            if (e != error.PathAlreadyExists) return e;
        };

        // Check if any config exists
        var dir = std.fs.openDirAbsolute(self.config_dir, .{ .iterate = true }) catch {
            try self.writeDefaultConfig();
            return;
        };
        defer dir.close();

        var has_config = false;
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.endsWith(u8, entry.name, ".conf") or
                std.mem.endsWith(u8, entry.name, ".conflist") or
                std.mem.endsWith(u8, entry.name, ".json"))
            {
                has_config = true;
                break;
            }
        }

        if (!has_config) {
            try self.writeDefaultConfig();
        }
    }

    fn writeDefaultConfig(self: *Self) !void {
        const config_path = try std.fs.path.join(self.allocator, &.{ self.config_dir, "10-cri-bridge.conf" });
        defer self.allocator.free(config_path);

        const default_config =
            \\{
            \\  "cniVersion": "1.0.0",
            \\  "name": "cri-bridge",
            \\  "type": "bridge",
            \\  "bridge": "cni0",
            \\  "isGateway": true,
            \\  "ipMasq": true,
            \\  "hairpinMode": true,
            \\  "ipam": {
            \\    "type": "host-local",
            \\    "subnet": "10.88.0.0/16",
            \\    "routes": [
            \\      { "dst": "0.0.0.0/0" }
            \\    ]
            \\  }
            \\}
        ;

        const file = std.fs.createFileAbsolute(config_path, .{}) catch |e| {
            logging.warn("Failed to create default CNI config: {}", .{e});
            return;
        };
        defer file.close();

        file.writeAll(default_config) catch |e| {
            logging.warn("Failed to write default CNI config: {}", .{e});
        };

        logging.info("Created default CNI config at {s}", .{config_path});
    }

    /// Load network configuration from config directory
    pub fn loadNetworkConfig(self: *Self, name: ?[]const u8) !NetworkConfig {
        const network_name = name orelse self.default_network;

        var dir = std.fs.openDirAbsolute(self.config_dir, .{ .iterate = true }) catch {
            return CniError.ConfigNotFound;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch return CniError.ConfigNotFound) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".conf") and
                !std.mem.endsWith(u8, entry.name, ".conflist") and
                !std.mem.endsWith(u8, entry.name, ".json")) continue;

            const path = try std.fs.path.join(self.allocator, &.{ self.config_dir, entry.name });
            defer self.allocator.free(path);

            const config = self.parseConfigFile(path) catch continue;

            // If looking for specific network, check name matches
            if (network_name) |n| {
                if (!std.mem.eql(u8, config.name, n)) {
                    var cfg = config;
                    cfg.deinit(self.allocator);
                    continue;
                }
            }

            return config;
        }

        return CniError.ConfigNotFound;
    }

    fn parseConfigFile(self: *Self, path: []const u8) !NetworkConfig {
        const file = std.fs.openFileAbsolute(path, .{}) catch return CniError.ConfigNotFound;
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 1024 * 1024) catch return CniError.ConfigNotFound;
        defer self.allocator.free(content);

        return self.parseConfigJson(content);
    }

    fn parseConfigJson(self: *Self, content: []const u8) !NetworkConfig {
        const parsed = json.parseFromSlice(json.Value, self.allocator, content, .{}) catch return CniError.InvalidConfig;
        defer parsed.deinit();

        const root = parsed.value.object;

        const cni_version = if (root.get("cniVersion")) |v|
            if (v == .string) try self.allocator.dupe(u8, v.string) else return CniError.InvalidConfig
        else
            return CniError.InvalidConfig;
        errdefer self.allocator.free(cni_version);

        const name = if (root.get("name")) |v|
            if (v == .string) try self.allocator.dupe(u8, v.string) else return CniError.InvalidConfig
        else
            return CniError.InvalidConfig;
        errdefer self.allocator.free(name);

        // Check if this is a conflist (has "plugins" array) or a single plugin config (has "type")
        const plugin_obj: json.ObjectMap = if (root.get("plugins")) |plugins_val| blk: {
            // This is a conflist format - use the first plugin
            if (plugins_val != .array or plugins_val.array.items.len == 0) {
                return CniError.InvalidConfig;
            }
            const first_plugin = plugins_val.array.items[0];
            if (first_plugin != .object) {
                return CniError.InvalidConfig;
            }
            break :blk first_plugin.object;
        } else blk: {
            // This is a single plugin config
            break :blk root;
        };

        const plugin_type = if (plugin_obj.get("type")) |v|
            if (v == .string) try self.allocator.dupe(u8, v.string) else return CniError.InvalidConfig
        else
            return CniError.InvalidConfig;
        errdefer self.allocator.free(plugin_type);

        var config = NetworkConfig{
            .cni_version = cni_version,
            .name = name,
            .plugin_type = plugin_type,
        };

        // Optional fields from the plugin object
        if (plugin_obj.get("bridge")) |b| {
            if (b == .string) {
                config.bridge = try self.allocator.dupe(u8, b.string);
            }
        }

        if (plugin_obj.get("isGateway")) |g| {
            if (g == .bool) config.is_gateway = g.bool;
        }

        if (plugin_obj.get("ipMasq")) |m| {
            if (m == .bool) config.ip_masq = m.bool;
        }

        if (plugin_obj.get("hairpinMode")) |h| {
            if (h == .bool) config.hairpin_mode = h.bool;
        }

        if (plugin_obj.get("mtu")) |m| {
            if (m == .integer) config.mtu = @intCast(m.integer);
        }

        // Parse IPAM from plugin object
        if (plugin_obj.get("ipam")) |ipam_val| {
            if (ipam_val == .object) {
                const ipam_obj = ipam_val.object;
                const ipam_type = if (ipam_obj.get("type")) |v|
                    if (v == .string) try self.allocator.dupe(u8, v.string) else return CniError.InvalidConfig
                else
                    return CniError.InvalidConfig;

                var ipam = IpamConfig{
                    .ipam_type = ipam_type,
                };

                // Handle subnet - could be direct or inside "ranges" array (conflist style)
                if (ipam_obj.get("subnet")) |s| {
                    if (s == .string) ipam.subnet = try self.allocator.dupe(u8, s.string);
                } else if (ipam_obj.get("ranges")) |ranges_val| {
                    // Conflist IPAM format: "ranges": [[{"subnet": "..."}]]
                    if (ranges_val == .array and ranges_val.array.items.len > 0) {
                        const first_range = ranges_val.array.items[0];
                        if (first_range == .array and first_range.array.items.len > 0) {
                            const range_item = first_range.array.items[0];
                            if (range_item == .object) {
                                if (range_item.object.get("subnet")) |s| {
                                    if (s == .string) ipam.subnet = try self.allocator.dupe(u8, s.string);
                                }
                                if (range_item.object.get("gateway")) |g| {
                                    if (g == .string) ipam.gateway = try self.allocator.dupe(u8, g.string);
                                }
                            }
                        }
                    }
                }

                if (ipam_obj.get("gateway")) |g| {
                    if (g == .string and ipam.gateway == null) {
                        ipam.gateway = try self.allocator.dupe(u8, g.string);
                    }
                }
                if (ipam_obj.get("rangeStart")) |rs| {
                    if (rs == .string) ipam.range_start = try self.allocator.dupe(u8, rs.string);
                }
                if (ipam_obj.get("rangeEnd")) |re| {
                    if (re == .string) ipam.range_end = try self.allocator.dupe(u8, re.string);
                }

                // Parse routes
                if (ipam_obj.get("routes")) |routes_val| {
                    if (routes_val == .array) {
                        var routes = try self.allocator.alloc(Route, routes_val.array.items.len);
                        var route_count: usize = 0;

                        for (routes_val.array.items) |route_item| {
                            if (route_item == .object) {
                                const route_obj = route_item.object;
                                if (route_obj.get("dst")) |dst| {
                                    if (dst == .string) {
                                        routes[route_count] = Route{
                                            .dst = try self.allocator.dupe(u8, dst.string),
                                            .gw = if (route_obj.get("gw")) |gw| blk: {
                                                if (gw == .string) break :blk try self.allocator.dupe(u8, gw.string);
                                                break :blk null;
                                            } else null,
                                        };
                                        route_count += 1;
                                    }
                                }
                            }
                        }

                        if (route_count < routes.len) {
                            ipam.routes = try self.allocator.realloc(routes, route_count);
                        } else {
                            ipam.routes = routes;
                        }
                    }
                }

                config.ipam = ipam;
            }
        }

        return config;
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

    /// Check if CNI plugins are available
    pub fn hasPlugins(self: *Self) bool {
        const plugin_path = self.findPlugin("bridge") catch return false;
        self.allocator.free(plugin_path);
        return true;
    }

    /// Setup network for a pod
    pub fn setupNetwork(
        self: *Self,
        pod_id: []const u8,
        pod_name: []const u8,
        pod_namespace: []const u8,
        netns_path: []const u8,
        ifname: []const u8,
        config: *const NetworkConfig,
    ) !CniResult {
        logging.info("Setting up network for pod {s} in namespace {s}", .{ pod_id, netns_path });

        const plugin_path = try self.findPlugin(config.plugin_type);
        defer self.allocator.free(plugin_path);

        // Build CNI_ARGS
        const cni_args = try std.fmt.allocPrint(
            self.allocator,
            "IgnoreUnknown=1;K8S_POD_NAMESPACE={s};K8S_POD_NAME={s};K8S_POD_INFRA_CONTAINER_ID={s}",
            .{ pod_namespace, pod_name, pod_id },
        );
        defer self.allocator.free(cni_args);

        // Build config JSON
        const config_json = try self.buildConfigJson(config);
        defer self.allocator.free(config_json);

        // Execute plugin
        const result = try self.execPlugin(
            plugin_path,
            "ADD",
            pod_id,
            netns_path,
            ifname,
            cni_args,
            config_json,
        );

        return result;
    }

    /// Teardown network for a pod
    pub fn teardownNetwork(
        self: *Self,
        pod_id: []const u8,
        pod_name: []const u8,
        pod_namespace: []const u8,
        netns_path: []const u8,
        ifname: []const u8,
        config: *const NetworkConfig,
    ) void {
        logging.info("Tearing down network for pod {s}", .{pod_id});

        const plugin_path = self.findPlugin(config.plugin_type) catch return;
        defer self.allocator.free(plugin_path);

        // Build CNI_ARGS
        const cni_args = std.fmt.allocPrint(
            self.allocator,
            "IgnoreUnknown=1;K8S_POD_NAMESPACE={s};K8S_POD_NAME={s};K8S_POD_INFRA_CONTAINER_ID={s}",
            .{ pod_namespace, pod_name, pod_id },
        ) catch return;
        defer self.allocator.free(cni_args);

        // Build config JSON
        const config_json = self.buildConfigJson(config) catch return;
        defer self.allocator.free(config_json);

        _ = self.execPlugin(
            plugin_path,
            "DEL",
            pod_id,
            netns_path,
            ifname,
            cni_args,
            config_json,
        ) catch {};
    }

    fn buildConfigJson(self: *Self, config: *const NetworkConfig) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(self.allocator);

        const w = list.writer(self.allocator);

        try w.writeAll("{");
        try w.print("\"cniVersion\":\"{s}\",", .{config.cni_version});
        try w.print("\"name\":\"{s}\",", .{config.name});
        try w.print("\"type\":\"{s}\"", .{config.plugin_type});

        if (config.bridge) |bridge| {
            try w.print(",\"bridge\":\"{s}\"", .{bridge});
        }
        if (config.is_gateway) {
            try w.writeAll(",\"isGateway\":true");
        }
        if (config.ip_masq) {
            try w.writeAll(",\"ipMasq\":true");
        }
        if (config.hairpin_mode) {
            try w.writeAll(",\"hairpinMode\":true");
        }
        if (config.mtu) |mtu| {
            try w.print(",\"mtu\":{d}", .{mtu});
        }

        // IPAM config
        if (config.ipam) |ipam| {
            try w.writeAll(",\"ipam\":{");
            try w.print("\"type\":\"{s}\"", .{ipam.ipam_type});
            if (ipam.subnet) |subnet| {
                try w.print(",\"subnet\":\"{s}\"", .{subnet});
            }
            if (ipam.gateway) |gateway| {
                try w.print(",\"gateway\":\"{s}\"", .{gateway});
            }
            if (ipam.range_start) |rs| {
                try w.print(",\"rangeStart\":\"{s}\"", .{rs});
            }
            if (ipam.range_end) |re| {
                try w.print(",\"rangeEnd\":\"{s}\"", .{re});
            }
            if (ipam.routes.len > 0) {
                try w.writeAll(",\"routes\":[");
                for (ipam.routes, 0..) |route, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.print("{{\"dst\":\"{s}\"", .{route.dst});
                    if (route.gw) |gw| {
                        try w.print(",\"gw\":\"{s}\"", .{gw});
                    }
                    try w.writeAll("}");
                }
                try w.writeAll("]");
            }
            try w.writeAll("}");
        }

        try w.writeAll("}");

        return list.toOwnedSlice(self.allocator);
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
        logging.debug("Executing CNI plugin: {s} {s}", .{ plugin_path, command });
        logging.debug("CNI config: {s}", .{config});

        // Build CNI_PATH
        const cni_path = try std.mem.join(self.allocator, ":", self.plugin_dirs);
        defer self.allocator.free(cni_path);

        // Set up environment - inherit parent env and add CNI variables
        var env_map = std.process.EnvMap.init(self.allocator);
        defer env_map.deinit();

        // Copy essential parent environment variables
        if (std.posix.getenv("PATH")) |path| {
            try env_map.put("PATH", path);
        }
        if (std.posix.getenv("HOME")) |home| {
            try env_map.put("HOME", home);
        }
        if (std.posix.getenv("USER")) |user| {
            try env_map.put("USER", user);
        }

        // Set CNI-specific environment variables
        try env_map.put("CNI_COMMAND", command);
        try env_map.put("CNI_CONTAINERID", container_id);
        try env_map.put("CNI_NETNS", netns);
        try env_map.put("CNI_IFNAME", ifname);
        try env_map.put("CNI_ARGS", cni_args);
        try env_map.put("CNI_PATH", cni_path);

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
            logging.err("CNI plugin {s} failed with code {d}: {s}", .{ command, exit_code, stderr });
            return CniError.ExecFailed;
        }

        logging.debug("CNI plugin output: {s}", .{stdout});

        // Parse result for ADD command
        if (std.mem.eql(u8, command, "ADD")) {
            return self.parseResult(stdout);
        }

        return CniResult{
            .cni_version = try self.allocator.dupe(u8, "1.0.0"),
        };
    }

    fn parseResult(self: *Self, content: []const u8) !CniResult {
        if (content.len == 0) {
            return CniResult{
                .cni_version = try self.allocator.dupe(u8, "1.0.0"),
            };
        }

        const parsed = json.parseFromSlice(json.Value, self.allocator, content, .{}) catch {
            logging.warn("Failed to parse CNI result JSON", .{});
            return CniResult{
                .cni_version = try self.allocator.dupe(u8, "1.0.0"),
            };
        };
        defer parsed.deinit();

        const root = parsed.value.object;

        var result = CniResult{
            .cni_version = if (root.get("cniVersion")) |v|
                if (v == .string) try self.allocator.dupe(u8, v.string) else try self.allocator.dupe(u8, "1.0.0")
            else
                try self.allocator.dupe(u8, "1.0.0"),
        };

        // Parse interfaces
        if (root.get("interfaces")) |ifaces_val| {
            if (ifaces_val == .array) {
                var ifaces = try self.allocator.alloc(Interface, ifaces_val.array.items.len);
                var iface_count: usize = 0;

                for (ifaces_val.array.items) |iface_item| {
                    if (iface_item == .object) {
                        const iface_obj = iface_item.object;
                        if (iface_obj.get("name")) |name| {
                            if (name == .string) {
                                ifaces[iface_count] = Interface{
                                    .name = try self.allocator.dupe(u8, name.string),
                                    .mac = if (iface_obj.get("mac")) |m| blk: {
                                        if (m == .string) break :blk try self.allocator.dupe(u8, m.string);
                                        break :blk null;
                                    } else null,
                                    .sandbox = if (iface_obj.get("sandbox")) |s| blk: {
                                        if (s == .string) break :blk try self.allocator.dupe(u8, s.string);
                                        break :blk null;
                                    } else null,
                                };
                                iface_count += 1;
                            }
                        }
                    }
                }

                if (iface_count > 0) {
                    result.interfaces = if (iface_count < ifaces.len)
                        try self.allocator.realloc(ifaces, iface_count)
                    else
                        ifaces;
                } else {
                    self.allocator.free(ifaces);
                }
            }
        }

        // Parse IPs
        if (root.get("ips")) |ips_val| {
            if (ips_val == .array) {
                var ips = try self.allocator.alloc(IpConfig, ips_val.array.items.len);
                var ip_count: usize = 0;

                for (ips_val.array.items) |ip_item| {
                    if (ip_item == .object) {
                        const ip_obj = ip_item.object;
                        if (ip_obj.get("address")) |addr| {
                            if (addr == .string) {
                                ips[ip_count] = IpConfig{
                                    .address = try self.allocator.dupe(u8, addr.string),
                                    .gateway = if (ip_obj.get("gateway")) |g| blk: {
                                        if (g == .string) break :blk try self.allocator.dupe(u8, g.string);
                                        break :blk null;
                                    } else null,
                                    .interface = if (ip_obj.get("interface")) |i| blk: {
                                        if (i == .integer) break :blk @intCast(i.integer);
                                        break :blk null;
                                    } else null,
                                };
                                ip_count += 1;
                            }
                        }
                    }
                }

                if (ip_count > 0) {
                    result.ips = if (ip_count < ips.len)
                        try self.allocator.realloc(ips, ip_count)
                    else
                        ips;
                } else {
                    self.allocator.free(ips);
                }
            }
        }

        return result;
    }
};

/// CNI configuration
pub const CniConfig = struct {
    plugin_dirs: ?[]const []const u8 = null,
    config_dir: ?[]const u8 = null,
    default_network: ?[]const u8 = null,
};

/// Create a network namespace for a pod
pub fn createNetns(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const netns_path = try std.fmt.allocPrint(allocator, "/var/run/netns/{s}", .{name});
    errdefer allocator.free(netns_path);

    // Create parent directory
    std.fs.makeDirAbsolute("/var/run/netns") catch |e| {
        if (e != error.PathAlreadyExists) return e;
    };

    // Create namespace using ip netns add
    var child = std.process.Child.init(&.{ "ip", "netns", "add", name }, allocator);
    child.spawn() catch return CniError.NamespaceError;
    const term = child.wait() catch return CniError.NamespaceError;

    if (term != .Exited or term.Exited != 0) {
        allocator.free(netns_path);
        return CniError.NamespaceError;
    }

    logging.debug("Created network namespace: {s}", .{netns_path});
    return netns_path;
}

/// Delete a network namespace
pub fn deleteNetns(allocator: std.mem.Allocator, name: []const u8) void {
    var child = std.process.Child.init(&.{ "ip", "netns", "delete", name }, allocator);
    child.spawn() catch return;
    _ = child.wait() catch {};
    logging.debug("Deleted network namespace: {s}", .{name});
}

/// Get the network namespace path from a name
pub fn getNetnsPath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "/var/run/netns/{s}", .{name});
}

/// Check if a network namespace exists
pub fn netnsExists(name: []const u8) bool {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/var/run/netns/{s}", .{name}) catch return false;
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}
