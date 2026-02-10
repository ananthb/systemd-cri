const std = @import("std");
const json = std.json;

const c = @cImport({
    @cInclude("rocksdb/c.h");
});

pub const StoreError = error{
    NotFound,
    AlreadyExists,
    IoError,
    ParseError,
    OutOfMemory,
    DatabaseError,
};

/// Pod state as persisted to disk
pub const PodState = enum {
    created,
    ready,
    not_ready,
    unknown,

    pub fn toString(self: PodState) []const u8 {
        return switch (self) {
            .created => "SANDBOX_CREATED",
            .ready => "SANDBOX_READY",
            .not_ready => "SANDBOX_NOTREADY",
            .unknown => "SANDBOX_UNKNOWN",
        };
    }

    pub fn fromString(s: []const u8) PodState {
        if (std.mem.eql(u8, s, "SANDBOX_CREATED")) return .created;
        if (std.mem.eql(u8, s, "SANDBOX_READY")) return .ready;
        if (std.mem.eql(u8, s, "SANDBOX_NOTREADY")) return .not_ready;
        return .unknown;
    }
};

/// Container state as persisted to disk
pub const ContainerState = enum {
    created,
    running,
    exited,
    unknown,

    pub fn toString(self: ContainerState) []const u8 {
        return switch (self) {
            .created => "CONTAINER_CREATED",
            .running => "CONTAINER_RUNNING",
            .exited => "CONTAINER_EXITED",
            .unknown => "CONTAINER_UNKNOWN",
        };
    }

    pub fn fromString(s: []const u8) ContainerState {
        if (std.mem.eql(u8, s, "CONTAINER_CREATED")) return .created;
        if (std.mem.eql(u8, s, "CONTAINER_RUNNING")) return .running;
        if (std.mem.eql(u8, s, "CONTAINER_EXITED")) return .exited;
        return .unknown;
    }
};

/// Pod sandbox metadata stored in state
pub const PodSandbox = struct {
    id: []const u8,
    name: []const u8,
    namespace: []const u8,
    uid: []const u8,
    state: PodState,
    created_at: i64,
    labels: std.StringHashMap([]const u8),
    annotations: std.StringHashMap([]const u8),
    // Systemd unit info
    unit_name: []const u8,
    // Network namespace path (if using CNI)
    network_namespace: ?[]const u8,
    // Pod IP address (assigned by CNI)
    pod_ip: ?[]const u8 = null,
    // Pod gateway
    pod_gateway: ?[]const u8 = null,

    pub fn deinit(self: *PodSandbox, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.namespace);
        allocator.free(self.uid);
        allocator.free(self.unit_name);
        if (self.network_namespace) |ns| {
            allocator.free(ns);
        }
        if (self.pod_ip) |ip| {
            allocator.free(ip);
        }
        if (self.pod_gateway) |gw| {
            allocator.free(gw);
        }

        var label_it = self.labels.iterator();
        while (label_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.labels.deinit();

        var annot_it = self.annotations.iterator();
        while (annot_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.annotations.deinit();
    }
};

/// Container metadata stored in state
pub const Container = struct {
    id: []const u8,
    pod_sandbox_id: []const u8,
    name: []const u8,
    image: []const u8,
    image_ref: []const u8,
    state: ContainerState,
    created_at: i64,
    started_at: i64,
    finished_at: i64,
    exit_code: i32,
    pid: ?u32,
    labels: std.StringHashMap([]const u8),
    annotations: std.StringHashMap([]const u8),
    // Systemd unit info
    unit_name: []const u8,
    // Container rootfs path (merged overlay mount point)
    rootfs_path: ?[]const u8,
    // Image rootfs path (from machined, used as overlay lower layer)
    image_rootfs: ?[]const u8 = null,
    // Log path
    log_path: ?[]const u8,
    // Command to execute (space-separated)
    command: ?[]const u8,
    // Working directory
    working_dir: ?[]const u8,
    // Security context
    run_as_user: ?i64 = null,
    run_as_group: ?i64 = null,
    privileged: bool = false,
    readonly_rootfs: bool = false,
    // Mounts (serialized as JSON array)
    mounts_json: ?[]const u8 = null,

    pub fn deinit(self: *Container, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.pod_sandbox_id);
        allocator.free(self.name);
        allocator.free(self.image);
        allocator.free(self.image_ref);
        allocator.free(self.unit_name);
        if (self.rootfs_path) |p| allocator.free(p);
        if (self.image_rootfs) |p| allocator.free(p);
        if (self.log_path) |p| allocator.free(p);
        if (self.command) |cmd| allocator.free(cmd);
        if (self.working_dir) |wd| allocator.free(wd);
        if (self.mounts_json) |m| allocator.free(m);

        var label_it = self.labels.iterator();
        while (label_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.labels.deinit();

        var annot_it = self.annotations.iterator();
        while (annot_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.annotations.deinit();
    }
};

/// State store for pods and containers using RocksDB
pub const Store = struct {
    allocator: std.mem.Allocator,
    db: *c.rocksdb_t,
    read_opts: *c.rocksdb_readoptions_t,
    write_opts: *c.rocksdb_writeoptions_t,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !Self {
        // Create options
        const options = c.rocksdb_options_create() orelse return StoreError.DatabaseError;
        defer c.rocksdb_options_destroy(options);

        c.rocksdb_options_set_create_if_missing(options, 1);
        c.rocksdb_options_set_compression(options, c.rocksdb_lz4_compression);

        // Ensure parent directory exists
        if (std.fs.path.dirname(db_path)) |parent| {
            std.fs.makeDirAbsolute(parent) catch |e| {
                if (e != error.PathAlreadyExists) return StoreError.IoError;
            };
        }

        // Create null-terminated path
        const path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(path_z);

        // Open database
        var err: [*c]u8 = null;
        const db = c.rocksdb_open(options, path_z.ptr, &err);
        if (err != null) {
            defer c.rocksdb_free(err);
            return StoreError.DatabaseError;
        }
        if (db == null) return StoreError.DatabaseError;

        // Create read/write options
        const read_opts = c.rocksdb_readoptions_create();
        if (read_opts == null) {
            c.rocksdb_close(db);
            return StoreError.DatabaseError;
        }

        const write_opts = c.rocksdb_writeoptions_create();
        if (write_opts == null) {
            c.rocksdb_readoptions_destroy(read_opts);
            c.rocksdb_close(db);
            return StoreError.DatabaseError;
        }

        // Enable sync for durability
        c.rocksdb_writeoptions_set_sync(write_opts, 1);

        return Self{
            .allocator = allocator,
            .db = db.?,
            .read_opts = read_opts.?,
            .write_opts = write_opts.?,
        };
    }

    pub fn deinit(self: *Self) void {
        c.rocksdb_writeoptions_destroy(self.write_opts);
        c.rocksdb_readoptions_destroy(self.read_opts);
        c.rocksdb_close(self.db);
    }

    // Key construction helpers

    fn makePodKey(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "pods/{s}", .{id});
    }

    fn makeContainerKey(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "containers/{s}", .{id});
    }

    fn makePodContainerIndexKey(allocator: std.mem.Allocator, pod_id: []const u8, container_id: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "pod_containers/{s}/{s}", .{ pod_id, container_id });
    }

    // Low-level RocksDB operations

    fn put(self: *Self, key: []const u8, value: []const u8) StoreError!void {
        var err: [*c]u8 = null;
        c.rocksdb_put(
            self.db,
            self.write_opts,
            key.ptr,
            key.len,
            value.ptr,
            value.len,
            &err,
        );
        if (err != null) {
            defer c.rocksdb_free(err);
            return StoreError.DatabaseError;
        }
    }

    fn get(self: *Self, key: []const u8) StoreError![]u8 {
        var val_len: usize = 0;
        var err: [*c]u8 = null;
        const val = c.rocksdb_get(
            self.db,
            self.read_opts,
            key.ptr,
            key.len,
            &val_len,
            &err,
        );
        if (err != null) {
            defer c.rocksdb_free(err);
            return StoreError.DatabaseError;
        }
        if (val == null) {
            return StoreError.NotFound;
        }

        // Copy to Zig-managed memory
        const result = self.allocator.alloc(u8, val_len) catch {
            c.rocksdb_free(val);
            return StoreError.OutOfMemory;
        };
        @memcpy(result, val[0..val_len]);
        c.rocksdb_free(val);

        return result;
    }

    fn delete(self: *Self, key: []const u8) StoreError!void {
        var err: [*c]u8 = null;
        c.rocksdb_delete(
            self.db,
            self.write_opts,
            key.ptr,
            key.len,
            &err,
        );
        if (err != null) {
            defer c.rocksdb_free(err);
            return StoreError.DatabaseError;
        }
    }

    fn listByPrefix(self: *Self, prefix: []const u8) StoreError!std.ArrayList([]const u8) {
        var keys: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (keys.items) |key| {
                self.allocator.free(key);
            }
            keys.deinit(self.allocator);
        }

        const iter = c.rocksdb_create_iterator(self.db, self.read_opts) orelse {
            return StoreError.DatabaseError;
        };
        defer c.rocksdb_iter_destroy(iter);

        // Seek to prefix
        c.rocksdb_iter_seek(iter, prefix.ptr, prefix.len);

        while (c.rocksdb_iter_valid(iter) != 0) {
            var key_len: usize = 0;
            const key_ptr = c.rocksdb_iter_key(iter, &key_len);
            if (key_ptr == null) break;

            const key = key_ptr[0..key_len];

            // Check if still within prefix
            if (!std.mem.startsWith(u8, key, prefix)) break;

            // Extract ID from key (after prefix)
            const id = key[prefix.len..];
            const id_copy = self.allocator.dupe(u8, id) catch return StoreError.OutOfMemory;
            keys.append(self.allocator, id_copy) catch {
                self.allocator.free(id_copy);
                return StoreError.OutOfMemory;
            };

            c.rocksdb_iter_next(iter);
        }

        return keys;
    }

    // Pod operations

    /// Save a pod to the store
    pub fn savePod(self: *Self, pod: *const PodSandbox) StoreError!void {
        const key = makePodKey(self.allocator, pod.id) catch return StoreError.OutOfMemory;
        defer self.allocator.free(key);

        const json_content = self.buildPodJson(pod) catch return StoreError.OutOfMemory;
        defer self.allocator.free(json_content);

        try self.put(key, json_content);
    }

    /// Load a pod from the store
    pub fn loadPod(self: *Self, id: []const u8) StoreError!PodSandbox {
        const key = makePodKey(self.allocator, id) catch return StoreError.OutOfMemory;
        defer self.allocator.free(key);

        const content = try self.get(key);
        defer self.allocator.free(content);

        return self.parsePodJson(content) catch return StoreError.ParseError;
    }

    /// Delete a pod from the store
    pub fn deletePod(self: *Self, id: []const u8) StoreError!void {
        const key = makePodKey(self.allocator, id) catch return StoreError.OutOfMemory;
        defer self.allocator.free(key);

        // First check if pod exists
        const existing = self.get(key) catch |e| {
            if (e == StoreError.NotFound) return StoreError.NotFound;
            return e;
        };
        self.allocator.free(existing);

        try self.delete(key);

        // Also delete pod_containers index entries for this pod
        const index_prefix = std.fmt.allocPrint(self.allocator, "pod_containers/{s}/", .{id}) catch return StoreError.OutOfMemory;
        defer self.allocator.free(index_prefix);

        var container_ids = try self.listByPrefix(index_prefix);
        defer {
            for (container_ids.items) |cid| {
                self.allocator.free(cid);
            }
            container_ids.deinit(self.allocator);
        }

        for (container_ids.items) |container_id| {
            const index_key = makePodContainerIndexKey(self.allocator, id, container_id) catch continue;
            defer self.allocator.free(index_key);
            self.delete(index_key) catch {};
        }
    }

    /// List all pod IDs
    pub fn listPods(self: *Self) StoreError!std.ArrayList([]const u8) {
        return self.listByPrefix("pods/");
    }

    // Container operations

    /// Save a container to the store
    pub fn saveContainer(self: *Self, container: *const Container) StoreError!void {
        const key = makeContainerKey(self.allocator, container.id) catch return StoreError.OutOfMemory;
        defer self.allocator.free(key);

        const json_content = self.buildContainerJson(container) catch return StoreError.OutOfMemory;
        defer self.allocator.free(json_content);

        try self.put(key, json_content);

        // Also create pod_containers index entry
        const index_key = makePodContainerIndexKey(self.allocator, container.pod_sandbox_id, container.id) catch return StoreError.OutOfMemory;
        defer self.allocator.free(index_key);

        try self.put(index_key, "");
    }

    /// Alias for loadContainer (for exec module compatibility)
    pub fn getContainer(self: *Self, id: []const u8) StoreError!Container {
        return self.loadContainer(id);
    }

    /// Load a container from the store
    pub fn loadContainer(self: *Self, id: []const u8) StoreError!Container {
        const key = makeContainerKey(self.allocator, id) catch return StoreError.OutOfMemory;
        defer self.allocator.free(key);

        const content = try self.get(key);
        defer self.allocator.free(content);

        return self.parseContainerJson(content) catch return StoreError.ParseError;
    }

    /// Delete a container from the store
    pub fn deleteContainer(self: *Self, id: []const u8) StoreError!void {
        const key = makeContainerKey(self.allocator, id) catch return StoreError.OutOfMemory;
        defer self.allocator.free(key);

        // Load container to get pod_sandbox_id for index cleanup
        var container = self.loadContainer(id) catch |e| {
            if (e == StoreError.NotFound) return StoreError.NotFound;
            return e;
        };
        defer container.deinit(self.allocator);

        try self.delete(key);

        // Also delete pod_containers index entry
        const index_key = makePodContainerIndexKey(self.allocator, container.pod_sandbox_id, id) catch return StoreError.OutOfMemory;
        defer self.allocator.free(index_key);
        self.delete(index_key) catch {};
    }

    /// List all container IDs
    pub fn listContainers(self: *Self) StoreError!std.ArrayList([]const u8) {
        return self.listByPrefix("containers/");
    }

    /// List containers for a specific pod (using index)
    pub fn listContainersForPod(self: *Self, pod_id: []const u8) StoreError!std.ArrayList([]const u8) {
        const prefix = std.fmt.allocPrint(self.allocator, "pod_containers/{s}/", .{pod_id}) catch return StoreError.OutOfMemory;
        defer self.allocator.free(prefix);

        return self.listByPrefix(prefix);
    }

    // JSON serialization helpers

    fn buildPodJson(self: *Self, pod: *const PodSandbox) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(self.allocator);

        const w = list.writer(self.allocator);

        try w.writeAll("{");
        try w.print("\"id\":\"{s}\",", .{pod.id});
        try w.print("\"name\":\"{s}\",", .{pod.name});
        try w.print("\"namespace\":\"{s}\",", .{pod.namespace});
        try w.print("\"uid\":\"{s}\",", .{pod.uid});
        try w.print("\"state\":\"{s}\",", .{pod.state.toString()});
        try w.print("\"created_at\":{d},", .{pod.created_at});
        try w.print("\"unit_name\":\"{s}\",", .{pod.unit_name});

        if (pod.network_namespace) |ns| {
            try w.print("\"network_namespace\":\"{s}\",", .{ns});
        } else {
            try w.writeAll("\"network_namespace\":null,");
        }

        if (pod.pod_ip) |ip| {
            try w.print("\"pod_ip\":\"{s}\",", .{ip});
        } else {
            try w.writeAll("\"pod_ip\":null,");
        }

        if (pod.pod_gateway) |gw| {
            try w.print("\"pod_gateway\":\"{s}\",", .{gw});
        } else {
            try w.writeAll("\"pod_gateway\":null,");
        }

        // Labels
        try w.writeAll("\"labels\":{");
        var first = true;
        var label_it = pod.labels.iterator();
        while (label_it.next()) |entry| {
            if (!first) try w.writeAll(",");
            try w.print("\"{s}\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
            first = false;
        }
        try w.writeAll("},");

        // Annotations
        try w.writeAll("\"annotations\":{");
        first = true;
        var annot_it = pod.annotations.iterator();
        while (annot_it.next()) |entry| {
            if (!first) try w.writeAll(",");
            try w.print("\"{s}\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
            first = false;
        }
        try w.writeAll("}");

        try w.writeAll("}");

        return list.toOwnedSlice(self.allocator);
    }

    fn parsePodJson(self: *Self, content: []const u8) !PodSandbox {
        const parsed = json.parseFromSlice(json.Value, self.allocator, content, .{}) catch return error.ParseError;
        defer parsed.deinit();

        const root = parsed.value.object;

        var labels = std.StringHashMap([]const u8).init(self.allocator);
        var annotations = std.StringHashMap([]const u8).init(self.allocator);

        if (root.get("labels")) |labels_val| {
            if (labels_val == .object) {
                var it = labels_val.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* == .string) {
                        const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                        const val = try self.allocator.dupe(u8, entry.value_ptr.*.string);
                        try labels.put(key, val);
                    }
                }
            }
        }

        if (root.get("annotations")) |annot_val| {
            if (annot_val == .object) {
                var it = annot_val.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* == .string) {
                        const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                        const val = try self.allocator.dupe(u8, entry.value_ptr.*.string);
                        try annotations.put(key, val);
                    }
                }
            }
        }

        const network_namespace = if (root.get("network_namespace")) |ns_val| blk: {
            if (ns_val == .string) {
                break :blk try self.allocator.dupe(u8, ns_val.string);
            }
            break :blk null;
        } else null;

        const pod_ip = if (root.get("pod_ip")) |ip_val| blk: {
            if (ip_val == .string) {
                break :blk try self.allocator.dupe(u8, ip_val.string);
            }
            break :blk null;
        } else null;

        const pod_gateway = if (root.get("pod_gateway")) |gw_val| blk: {
            if (gw_val == .string) {
                break :blk try self.allocator.dupe(u8, gw_val.string);
            }
            break :blk null;
        } else null;

        return PodSandbox{
            .id = try self.allocator.dupe(u8, root.get("id").?.string),
            .name = try self.allocator.dupe(u8, root.get("name").?.string),
            .namespace = try self.allocator.dupe(u8, root.get("namespace").?.string),
            .uid = try self.allocator.dupe(u8, root.get("uid").?.string),
            .state = PodState.fromString(root.get("state").?.string),
            .created_at = root.get("created_at").?.integer,
            .unit_name = try self.allocator.dupe(u8, root.get("unit_name").?.string),
            .network_namespace = network_namespace,
            .pod_ip = pod_ip,
            .pod_gateway = pod_gateway,
            .labels = labels,
            .annotations = annotations,
        };
    }

    fn buildContainerJson(self: *Self, container: *const Container) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(self.allocator);

        const w = list.writer(self.allocator);

        try w.writeAll("{");
        try w.print("\"id\":\"{s}\",", .{container.id});
        try w.print("\"pod_sandbox_id\":\"{s}\",", .{container.pod_sandbox_id});
        try w.print("\"name\":\"{s}\",", .{container.name});
        try w.print("\"image\":\"{s}\",", .{container.image});
        try w.print("\"image_ref\":\"{s}\",", .{container.image_ref});
        try w.print("\"state\":\"{s}\",", .{container.state.toString()});
        try w.print("\"created_at\":{d},", .{container.created_at});
        try w.print("\"started_at\":{d},", .{container.started_at});
        try w.print("\"finished_at\":{d},", .{container.finished_at});
        try w.print("\"exit_code\":{d},", .{container.exit_code});
        if (container.pid) |pid| {
            try w.print("\"pid\":{d},", .{pid});
        } else {
            try w.writeAll("\"pid\":null,");
        }
        try w.print("\"unit_name\":\"{s}\",", .{container.unit_name});

        if (container.rootfs_path) |p| {
            try w.print("\"rootfs_path\":\"{s}\",", .{p});
        } else {
            try w.writeAll("\"rootfs_path\":null,");
        }

        if (container.image_rootfs) |p| {
            try w.print("\"image_rootfs\":\"{s}\",", .{p});
        } else {
            try w.writeAll("\"image_rootfs\":null,");
        }

        if (container.log_path) |p| {
            try w.print("\"log_path\":\"{s}\",", .{p});
        } else {
            try w.writeAll("\"log_path\":null,");
        }

        // Labels
        try w.writeAll("\"labels\":{");
        var first = true;
        var label_it = container.labels.iterator();
        while (label_it.next()) |entry| {
            if (!first) try w.writeAll(",");
            try w.print("\"{s}\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
            first = false;
        }
        try w.writeAll("},");

        // Annotations
        try w.writeAll("\"annotations\":{");
        first = true;
        var annot_it = container.annotations.iterator();
        while (annot_it.next()) |entry| {
            if (!first) try w.writeAll(",");
            try w.print("\"{s}\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
            first = false;
        }
        try w.writeAll("},");

        // Command
        if (container.command) |cmd| {
            try w.print("\"command\":\"{s}\",", .{cmd});
        } else {
            try w.writeAll("\"command\":null,");
        }

        // Working directory
        if (container.working_dir) |wd| {
            try w.print("\"working_dir\":\"{s}\",", .{wd});
        } else {
            try w.writeAll("\"working_dir\":null,");
        }

        // Security context
        if (container.run_as_user) |uid| {
            try w.print("\"run_as_user\":{d},", .{uid});
        } else {
            try w.writeAll("\"run_as_user\":null,");
        }

        if (container.run_as_group) |gid| {
            try w.print("\"run_as_group\":{d},", .{gid});
        } else {
            try w.writeAll("\"run_as_group\":null,");
        }

        try w.print("\"privileged\":{},", .{container.privileged});
        try w.print("\"readonly_rootfs\":{},", .{container.readonly_rootfs});

        // Mounts JSON (stored as escaped string)
        if (container.mounts_json) |mj| {
            try w.writeAll("\"mounts_json\":\"");
            // Escape JSON special characters
            for (mj) |ch| {
                switch (ch) {
                    '"' => try w.writeAll("\\\""),
                    '\\' => try w.writeAll("\\\\"),
                    '\n' => try w.writeAll("\\n"),
                    '\r' => try w.writeAll("\\r"),
                    '\t' => try w.writeAll("\\t"),
                    else => try w.writeByte(ch),
                }
            }
            try w.writeAll("\"");
        } else {
            try w.writeAll("\"mounts_json\":null");
        }

        try w.writeAll("}");

        return list.toOwnedSlice(self.allocator);
    }

    fn parseContainerJson(self: *Self, content: []const u8) !Container {
        const parsed = json.parseFromSlice(json.Value, self.allocator, content, .{}) catch return error.ParseError;
        defer parsed.deinit();

        const root = parsed.value.object;

        var labels = std.StringHashMap([]const u8).init(self.allocator);
        var annotations = std.StringHashMap([]const u8).init(self.allocator);

        if (root.get("labels")) |labels_val| {
            if (labels_val == .object) {
                var it = labels_val.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* == .string) {
                        const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                        const val = try self.allocator.dupe(u8, entry.value_ptr.*.string);
                        try labels.put(key, val);
                    }
                }
            }
        }

        if (root.get("annotations")) |annot_val| {
            if (annot_val == .object) {
                var it = annot_val.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* == .string) {
                        const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                        const val = try self.allocator.dupe(u8, entry.value_ptr.*.string);
                        try annotations.put(key, val);
                    }
                }
            }
        }

        const rootfs_path = if (root.get("rootfs_path")) |val| blk: {
            if (val == .string) break :blk try self.allocator.dupe(u8, val.string);
            break :blk null;
        } else null;

        const image_rootfs = if (root.get("image_rootfs")) |val| blk: {
            if (val == .string) break :blk try self.allocator.dupe(u8, val.string);
            break :blk null;
        } else null;

        const log_path = if (root.get("log_path")) |val| blk: {
            if (val == .string) break :blk try self.allocator.dupe(u8, val.string);
            break :blk null;
        } else null;

        const command = if (root.get("command")) |val| blk: {
            if (val == .string) break :blk try self.allocator.dupe(u8, val.string);
            break :blk null;
        } else null;

        const working_dir = if (root.get("working_dir")) |val| blk: {
            if (val == .string) break :blk try self.allocator.dupe(u8, val.string);
            break :blk null;
        } else null;

        // Security context
        const run_as_user: ?i64 = if (root.get("run_as_user")) |val| blk: {
            if (val == .integer) break :blk val.integer;
            break :blk null;
        } else null;

        const run_as_group: ?i64 = if (root.get("run_as_group")) |val| blk: {
            if (val == .integer) break :blk val.integer;
            break :blk null;
        } else null;

        const privileged = if (root.get("privileged")) |val| val == .bool and val.bool else false;
        const readonly_rootfs = if (root.get("readonly_rootfs")) |val| val == .bool and val.bool else false;

        const mounts_json = if (root.get("mounts_json")) |val| blk: {
            if (val == .string) break :blk try self.allocator.dupe(u8, val.string);
            break :blk null;
        } else null;

        return Container{
            .id = try self.allocator.dupe(u8, root.get("id").?.string),
            .pod_sandbox_id = try self.allocator.dupe(u8, root.get("pod_sandbox_id").?.string),
            .name = try self.allocator.dupe(u8, root.get("name").?.string),
            .image = try self.allocator.dupe(u8, root.get("image").?.string),
            .image_ref = try self.allocator.dupe(u8, root.get("image_ref").?.string),
            .state = ContainerState.fromString(root.get("state").?.string),
            .created_at = root.get("created_at").?.integer,
            .started_at = root.get("started_at").?.integer,
            .finished_at = root.get("finished_at").?.integer,
            .exit_code = @intCast(root.get("exit_code").?.integer),
            .pid = if (root.get("pid")) |pid_val| blk: {
                if (pid_val == .integer) break :blk @intCast(pid_val.integer);
                break :blk null;
            } else null,
            .unit_name = try self.allocator.dupe(u8, root.get("unit_name").?.string),
            .rootfs_path = rootfs_path,
            .image_rootfs = image_rootfs,
            .log_path = log_path,
            .command = command,
            .working_dir = working_dir,
            .labels = labels,
            .annotations = annotations,
            .run_as_user = run_as_user,
            .run_as_group = run_as_group,
            .privileged = privileged,
            .readonly_rootfs = readonly_rootfs,
            .mounts_json = mounts_json,
        };
    }
};

/// Default state directory
pub const DEFAULT_STATE_DIR = "/var/lib/systemd-cri";

/// Default database path
pub const DEFAULT_DB_PATH = "/var/lib/systemd-cri/state.db";

test "Store basic operations" {
    const allocator = std.testing.allocator;

    var store = Store.init(allocator, "/tmp/systemd-cri-test-rocksdb") catch |e| {
        std.debug.print("Failed to init store: {}\n", .{e});
        return error.SkipZigTest;
    };
    defer store.deinit();

    // Create a test pod
    var labels = std.StringHashMap([]const u8).init(allocator);
    defer labels.deinit();
    var annotations = std.StringHashMap([]const u8).init(allocator);
    defer annotations.deinit();

    const pod = PodSandbox{
        .id = "test-pod-123",
        .name = "test-pod",
        .namespace = "default",
        .uid = "uid-456",
        .state = .ready,
        .created_at = 1234567890,
        .unit_name = "cri-pod-test-pod-123.service",
        .network_namespace = null,
        .labels = labels,
        .annotations = annotations,
    };

    // Save
    try store.savePod(&pod);

    // Load
    var loaded = try store.loadPod("test-pod-123");
    defer loaded.deinit(allocator);

    try std.testing.expectEqualStrings("test-pod-123", loaded.id);
    try std.testing.expectEqualStrings("test-pod", loaded.name);
    try std.testing.expectEqual(PodState.ready, loaded.state);

    // List
    var pod_ids = try store.listPods();
    defer {
        for (pod_ids.items) |id| {
            allocator.free(id);
        }
        pod_ids.deinit(allocator);
    }
    try std.testing.expect(pod_ids.items.len >= 1);

    // Delete
    try store.deletePod("test-pod-123");

    // Verify deleted
    _ = store.loadPod("test-pod-123") catch |e| {
        try std.testing.expectEqual(StoreError.NotFound, e);
        return;
    };
    try std.testing.expect(false); // Should not reach here
}

test "Container operations with pod index" {
    const allocator = std.testing.allocator;

    var store = Store.init(allocator, "/tmp/systemd-cri-test-containers") catch |e| {
        std.debug.print("Failed to init store: {}\n", .{e});
        return error.SkipZigTest;
    };
    defer store.deinit();

    // Create test containers
    var labels = std.StringHashMap([]const u8).init(allocator);
    defer labels.deinit();
    var annotations = std.StringHashMap([]const u8).init(allocator);
    defer annotations.deinit();

    const container1 = Container{
        .id = "container-1",
        .pod_sandbox_id = "pod-abc",
        .name = "test-container-1",
        .image = "nginx:latest",
        .image_ref = "sha256:abc123",
        .state = .running,
        .created_at = 1234567890,
        .started_at = 1234567891,
        .finished_at = 0,
        .exit_code = 0,
        .pid = 1234,
        .unit_name = "cri-container-1.service",
        .rootfs_path = null,
        .log_path = null,
        .command = null,
        .working_dir = null,
        .labels = labels,
        .annotations = annotations,
    };

    const container2 = Container{
        .id = "container-2",
        .pod_sandbox_id = "pod-abc",
        .name = "test-container-2",
        .image = "redis:latest",
        .image_ref = "sha256:def456",
        .state = .running,
        .created_at = 1234567892,
        .started_at = 1234567893,
        .finished_at = 0,
        .exit_code = 0,
        .pid = 1235,
        .unit_name = "cri-container-2.service",
        .rootfs_path = null,
        .log_path = null,
        .command = null,
        .working_dir = null,
        .labels = labels,
        .annotations = annotations,
    };

    // Save both containers
    try store.saveContainer(&container1);
    try store.saveContainer(&container2);

    // List containers for pod
    var pod_containers = try store.listContainersForPod("pod-abc");
    defer {
        for (pod_containers.items) |id| {
            allocator.free(id);
        }
        pod_containers.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 2), pod_containers.items.len);

    // Delete containers
    try store.deleteContainer("container-1");
    try store.deleteContainer("container-2");

    // Verify index is cleaned up
    var remaining = try store.listContainersForPod("pod-abc");
    defer {
        for (remaining.items) |id| {
            allocator.free(id);
        }
        remaining.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 0), remaining.items.len);
}
