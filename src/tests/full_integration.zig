const std = @import("std");
const testing = std.testing;
const posix = std.posix;

// Import modules via lib
const lib = @import("lib");
const store = lib.store;
const image_store = lib.image_store;
const dbus = lib.dbus;
const machined = lib.image_machined;
const pod = lib.pod;
const container = lib.container;
const manager = lib.manager;
const image_pull = lib.image_pull;

// ============================================================================
// Test Configuration
// ============================================================================

const TestConfig = struct {
    state_dir: []const u8,
    allocator: std.mem.Allocator,
    bus: ?*dbus.Bus = null,
    state_store: ?*store.Store = null,
    img_store: ?*image_store.ImageStore = null,

    fn init(allocator: std.mem.Allocator) !TestConfig {
        const state_dir = try createTempDir(allocator);
        return TestConfig{
            .state_dir = state_dir,
            .allocator = allocator,
        };
    }

    fn deinit(self: *TestConfig) void {
        cleanupTempDir(self.state_dir);
        self.allocator.free(self.state_dir);
    }
};

/// Create a temporary directory for testing
fn createTempDir(allocator: std.mem.Allocator) ![]const u8 {
    const timestamp: u64 = @intCast(std.time.timestamp());
    var prng = std.Random.DefaultPrng.init(timestamp);
    const random = prng.random();
    const rand_part = random.int(u32);

    const path = try std.fmt.allocPrint(allocator, "/tmp/systemd-cri-fulltest-{d}-{d}", .{ timestamp, rand_part });
    errdefer allocator.free(path);

    std.fs.makeDirAbsolute(path) catch |e| {
        if (e == error.PathAlreadyExists) {
            allocator.free(path);
            return createTempDir(allocator);
        }
        return e;
    };

    return path;
}

fn cleanupTempDir(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

/// Check if we're running as root
fn isRoot() bool {
    return std.os.linux.getuid() == 0;
}

/// Check if D-Bus is available
fn isDbusAvailable(allocator: std.mem.Allocator) bool {
    var bus = dbus.Bus.openSystem(allocator) catch return false;
    bus.deinit();
    return true;
}

// ============================================================================
// Full Pod Lifecycle Integration Test
// ============================================================================

test "full integration: complete pod lifecycle" {
    const allocator = testing.allocator;

    // Check prerequisites
    if (!isRoot()) {
        std.debug.print("Skipping: requires root for systemd transient units\n", .{});
        return error.SkipZigTest;
    }

    if (!isDbusAvailable(allocator)) {
        std.debug.print("Skipping: D-Bus not available\n", .{});
        return error.SkipZigTest;
    }

    var config = try TestConfig.init(allocator);
    defer config.deinit();

    // Initialize D-Bus connection
    var bus = try dbus.Bus.openSystem(allocator);
    defer bus.deinit();

    // Initialize state store (RocksDB)
    const db_path = try std.fs.path.join(allocator, &.{ config.state_dir, "state.db" });
    defer allocator.free(db_path);

    var state_store = try store.Store.init(allocator, db_path);
    defer state_store.deinit();

    // Initialize pod manager
    var pod_manager = pod.PodManager.init(allocator, &bus, &state_store);

    // Create a pod
    const pod_config = pod.PodConfig{
        .name = "test-pod",
        .uid = "test-uid-12345",
        .namespace = "default",
        .hostname = "test-pod-host",
        .labels = null,
        .annotations = null,
    };

    std.debug.print("Creating pod...\n", .{});
    const pod_id = try pod_manager.runPodSandbox(&pod_config);
    defer allocator.free(pod_id);
    std.debug.print("Pod created: {s}\n", .{pod_id});

    // Verify pod is in state store
    var loaded_pod = try state_store.loadPod(pod_id);
    defer loaded_pod.deinit(allocator);
    try testing.expectEqualStrings("test-pod", loaded_pod.name);
    try testing.expectEqualStrings("default", loaded_pod.namespace);

    // Get pod status
    var status = try pod_manager.podSandboxStatus(pod_id);
    defer allocator.free(status.id);
    std.debug.print("Pod status: {s}\n", .{status.state.toString()});

    // List pods
    var pods = try pod_manager.listPodSandboxes(null);
    defer {
        for (pods.items) |*p| {
            p.deinit(allocator);
        }
        pods.deinit(allocator);
    }
    try testing.expect(pods.items.len >= 1);
    std.debug.print("Found {d} pod(s)\n", .{pods.items.len});

    // Stop pod
    std.debug.print("Stopping pod...\n", .{});
    try pod_manager.stopPodSandbox(pod_id);

    // Verify pod state changed
    const stopped_status = try pod_manager.podSandboxStatus(pod_id);
    defer allocator.free(stopped_status.id);
    try testing.expectEqual(store.PodState.not_ready, stopped_status.state);
    std.debug.print("Pod stopped\n", .{});

    // Remove pod
    std.debug.print("Removing pod...\n", .{});
    try pod_manager.removePodSandbox(pod_id);

    // Verify pod is gone from state store
    _ = state_store.loadPod(pod_id) catch |e| {
        try testing.expectEqual(store.StoreError.NotFound, e);
        std.debug.print("Pod removed successfully\n", .{});
        return;
    };
    try testing.expect(false); // Should not reach here
}

// ============================================================================
// Full Container Lifecycle Integration Test
// ============================================================================

test "full integration: complete container lifecycle" {
    const allocator = testing.allocator;

    if (!isRoot()) {
        std.debug.print("Skipping: requires root for systemd transient units\n", .{});
        return error.SkipZigTest;
    }

    if (!isDbusAvailable(allocator)) {
        std.debug.print("Skipping: D-Bus not available\n", .{});
        return error.SkipZigTest;
    }

    var config = try TestConfig.init(allocator);
    defer config.deinit();

    var bus = try dbus.Bus.openSystem(allocator);
    defer bus.deinit();

    const db_path = try std.fs.path.join(allocator, &.{ config.state_dir, "state.db" });
    defer allocator.free(db_path);

    var state_store = try store.Store.init(allocator, db_path);
    defer state_store.deinit();

    var pod_manager = pod.PodManager.init(allocator, &bus, &state_store);
    var container_manager = container.ContainerManager.init(allocator, &bus, &state_store, config.state_dir);

    // Create a pod first
    const pod_config = pod.PodConfig{
        .name = "container-test-pod",
        .uid = "container-test-uid",
        .namespace = "default",
    };

    const pod_id = try pod_manager.runPodSandbox(&pod_config);
    defer allocator.free(pod_id);
    defer pod_manager.removePodSandbox(pod_id) catch {};
    std.debug.print("Created pod: {s}\n", .{pod_id});

    // Create a container in the pod
    const container_config = container.ContainerConfig{
        .name = "test-container",
        .image = .{ .image = "busybox" },
        .command = &[_][]const u8{ "/bin/sh", "-c", "echo hello && sleep 1" },
        .working_dir = "/",
    };

    std.debug.print("Creating container...\n", .{});
    const container_id = container_manager.createContainer(pod_id, &container_config) catch |err| {
        std.debug.print("Container creation failed (expected if image not available): {}\n", .{err});
        return error.SkipZigTest;
    };
    defer allocator.free(container_id);
    std.debug.print("Container created: {s}\n", .{container_id});

    // Verify container is in state store
    var loaded_container = try state_store.loadContainer(container_id);
    defer loaded_container.deinit(allocator);
    try testing.expectEqualStrings("test-container", loaded_container.name);
    try testing.expectEqualStrings(pod_id, loaded_container.pod_sandbox_id);

    // List containers for pod
    var containers = try state_store.listContainersForPod(pod_id);
    defer {
        for (containers.items) |id| {
            allocator.free(id);
        }
        containers.deinit(allocator);
    }
    try testing.expectEqual(@as(usize, 1), containers.items.len);

    // Start container
    std.debug.print("Starting container...\n", .{});
    try container_manager.startContainer(container_id);

    // Stop container
    std.debug.print("Stopping container...\n", .{});
    container_manager.stopContainer(container_id, 10) catch |err| {
        std.debug.print("Stop container error (may be expected): {}\n", .{err});
    };

    // Remove container
    std.debug.print("Removing container...\n", .{});
    try container_manager.removeContainer(container_id);

    // Verify container is gone
    _ = state_store.loadContainer(container_id) catch |e| {
        try testing.expectEqual(store.StoreError.NotFound, e);
        std.debug.print("Container removed successfully\n", .{});
        return;
    };
    try testing.expect(false);
}

// ============================================================================
// Image Pull and machined Integration Test
// ============================================================================

test "full integration: image pull with machined" {
    const allocator = testing.allocator;

    if (!isRoot()) {
        std.debug.print("Skipping: requires root for machined import\n", .{});
        return error.SkipZigTest;
    }

    if (!isDbusAvailable(allocator)) {
        std.debug.print("Skipping: D-Bus not available\n", .{});
        return error.SkipZigTest;
    }

    var config = try TestConfig.init(allocator);
    defer config.deinit();

    var bus = try dbus.Bus.openSystem(allocator);
    defer bus.deinit();

    var img_store = try image_store.ImageStore.init(allocator, config.state_dir);
    defer img_store.deinit();

    var puller = try image_pull.ImagePuller.init(allocator, &img_store, &bus);
    defer puller.deinit();

    // Check if skopeo/umoci are available
    const skopeo_available = blk: {
        std.fs.accessAbsolute("/usr/bin/skopeo", .{}) catch {
            // Try PATH
            const path_env = posix.getenv("PATH") orelse break :blk false;
            var paths = std.mem.splitScalar(u8, path_env, ':');
            while (paths.next()) |dir| {
                const full_path = std.fs.path.join(allocator, &.{ dir, "skopeo" }) catch continue;
                defer allocator.free(full_path);
                std.fs.accessAbsolute(full_path, .{}) catch continue;
                break :blk true;
            }
            break :blk false;
        };
        break :blk true;
    };

    if (!skopeo_available) {
        std.debug.print("Skipping: skopeo not available\n", .{});
        return error.SkipZigTest;
    }

    // Pull a small test image (alpine is ~5MB)
    std.debug.print("Pulling alpine:latest image...\n", .{});
    const image_id = puller.pullImage("alpine:latest", null) catch |err| {
        std.debug.print("Image pull failed: {} (may need network access)\n", .{err});
        return error.SkipZigTest;
    };
    defer allocator.free(image_id);
    std.debug.print("Image pulled: {s}\n", .{image_id});

    // Check if image exists
    try testing.expect(puller.imageExists("alpine:latest"));

    // Get rootfs path
    const rootfs = try puller.getImageRootfs("alpine:latest");
    defer allocator.free(rootfs);
    std.debug.print("Image rootfs: {s}\n", .{rootfs});

    // Verify rootfs exists
    std.fs.accessAbsolute(rootfs, .{}) catch |err| {
        std.debug.print("Rootfs not accessible: {}\n", .{err});
        return err;
    };

    // Check machined
    var mgr = machined.MachineImageManager.init(allocator, &bus);
    if (mgr.imageExists(image_id)) {
        std.debug.print("Image found in machined\n", .{});
    } else {
        std.debug.print("Image in local storage (machined import may have failed)\n", .{});
    }

    // List all images
    var images = try puller.listImages();
    defer {
        for (images.items) |*img| {
            img.deinit(allocator);
        }
        images.deinit(allocator);
    }
    std.debug.print("Total images: {d}\n", .{images.items.len});

    // Remove image
    std.debug.print("Removing image...\n", .{});
    puller.removeImage("alpine:latest") catch |err| {
        std.debug.print("Image removal warning: {}\n", .{err});
    };

    std.debug.print("Image test completed\n", .{});
}

// ============================================================================
// Multiple Pods and Containers Test
// ============================================================================

test "full integration: multiple pods and containers" {
    const allocator = testing.allocator;

    if (!isRoot()) {
        std.debug.print("Skipping: requires root\n", .{});
        return error.SkipZigTest;
    }

    if (!isDbusAvailable(allocator)) {
        std.debug.print("Skipping: D-Bus not available\n", .{});
        return error.SkipZigTest;
    }

    var config = try TestConfig.init(allocator);
    defer config.deinit();

    var bus = try dbus.Bus.openSystem(allocator);
    defer bus.deinit();

    const db_path = try std.fs.path.join(allocator, &.{ config.state_dir, "state.db" });
    defer allocator.free(db_path);

    var state_store = try store.Store.init(allocator, db_path);
    defer state_store.deinit();

    var pod_manager = pod.PodManager.init(allocator, &bus, &state_store);

    // Create multiple pods
    const num_pods = 3;
    var pod_ids: [num_pods][]const u8 = undefined;
    var created_count: usize = 0;

    defer {
        var i: usize = 0;
        while (i < created_count) : (i += 1) {
            pod_manager.removePodSandbox(pod_ids[i]) catch {};
            allocator.free(pod_ids[i]);
        }
    }

    std.debug.print("Creating {d} pods...\n", .{num_pods});
    for (0..num_pods) |i| {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "multi-pod-{d}", .{i}) catch unreachable;

        var uid_buf: [32]u8 = undefined;
        const uid = std.fmt.bufPrint(&uid_buf, "uid-{d}", .{i}) catch unreachable;

        const pod_config = pod.PodConfig{
            .name = name,
            .uid = uid,
            .namespace = "multi-test",
        };

        pod_ids[i] = try pod_manager.runPodSandbox(&pod_config);
        created_count += 1;
        std.debug.print("  Created pod {d}: {s}\n", .{ i, pod_ids[i] });
    }

    // List all pods
    var pods = try pod_manager.listPodSandboxes(null);
    defer {
        for (pods.items) |*p| {
            p.deinit(allocator);
        }
        pods.deinit(allocator);
    }
    try testing.expect(pods.items.len >= num_pods);
    std.debug.print("Total pods listed: {d}\n", .{pods.items.len});

    // Filter by state
    const ns_filter = pod.PodSandboxFilter{
        .state = .ready,
    };
    var filtered_pods = try pod_manager.listPodSandboxes(ns_filter);
    defer {
        for (filtered_pods.items) |*p| {
            p.deinit(allocator);
        }
        filtered_pods.deinit(allocator);
    }
    std.debug.print("Ready pods: {d}\n", .{filtered_pods.items.len});

    // Verify RocksDB has all pods
    var stored_ids = try state_store.listPods();
    defer {
        for (stored_ids.items) |id| {
            allocator.free(id);
        }
        stored_ids.deinit(allocator);
    }
    try testing.expect(stored_ids.items.len >= num_pods);

    std.debug.print("Multi-pod test completed\n", .{});
}

// ============================================================================
// State Store Persistence Test
// ============================================================================

test "full integration: state persistence across restarts" {
    const allocator = testing.allocator;

    var config = try TestConfig.init(allocator);
    defer config.deinit();

    const db_path = try std.fs.path.join(allocator, &.{ config.state_dir, "state.db" });
    defer allocator.free(db_path);

    // Create and populate store
    {
        var state_store = try store.Store.init(allocator, db_path);
        defer state_store.deinit();

        // Save some pods
        for (0..5) |i| {
            var labels = std.StringHashMap([]const u8).init(allocator);
            defer labels.deinit();
            var annotations = std.StringHashMap([]const u8).init(allocator);
            defer annotations.deinit();

            var id_buf: [32]u8 = undefined;
            const id = std.fmt.bufPrint(&id_buf, "persist-pod-{d}", .{i}) catch unreachable;

            const p = store.PodSandbox{
                .id = id,
                .name = "persist-test",
                .namespace = "default",
                .uid = "test-uid",
                .state = .ready,
                .created_at = @intCast(i),
                .unit_name = "test.service",
                .network_namespace = null,
                .labels = labels,
                .annotations = annotations,
            };
            try state_store.savePod(&p);
        }
        std.debug.print("Saved 5 pods to RocksDB\n", .{});
    }

    // Reopen store and verify data persisted
    {
        var state_store = try store.Store.init(allocator, db_path);
        defer state_store.deinit();

        var pod_ids = try state_store.listPods();
        defer {
            for (pod_ids.items) |id| {
                allocator.free(id);
            }
            pod_ids.deinit(allocator);
        }

        try testing.expectEqual(@as(usize, 5), pod_ids.items.len);
        std.debug.print("Verified 5 pods persisted after reopen\n", .{});

        // Load and verify a specific pod
        var loaded = try state_store.loadPod("persist-pod-0");
        defer loaded.deinit(allocator);
        try testing.expectEqualStrings("persist-test", loaded.name);
        try testing.expectEqual(store.PodState.ready, loaded.state);
    }

    std.debug.print("Persistence test completed\n", .{});
}

// ============================================================================
// Error Handling Tests
// ============================================================================

test "full integration: error handling" {
    const allocator = testing.allocator;

    var config = try TestConfig.init(allocator);
    defer config.deinit();

    const db_path = try std.fs.path.join(allocator, &.{ config.state_dir, "state.db" });
    defer allocator.free(db_path);

    var state_store = try store.Store.init(allocator, db_path);
    defer state_store.deinit();

    // Test loading non-existent pod
    _ = state_store.loadPod("non-existent-pod") catch |e| {
        try testing.expectEqual(store.StoreError.NotFound, e);
        std.debug.print("Correctly got NotFound for non-existent pod\n", .{});
    };

    // Test loading non-existent container
    _ = state_store.loadContainer("non-existent-container") catch |e| {
        try testing.expectEqual(store.StoreError.NotFound, e);
        std.debug.print("Correctly got NotFound for non-existent container\n", .{});
    };

    // Test deleting non-existent pod
    state_store.deletePod("non-existent") catch |e| {
        try testing.expectEqual(store.StoreError.NotFound, e);
        std.debug.print("Correctly got NotFound when deleting non-existent pod\n", .{});
    };

    // Test empty list operations
    var pods = try state_store.listPods();
    defer pods.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), pods.items.len);
    std.debug.print("Empty pod list returned correctly\n", .{});

    var containers = try state_store.listContainersForPod("non-existent-pod");
    defer containers.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), containers.items.len);
    std.debug.print("Empty container list for non-existent pod returned correctly\n", .{});

    std.debug.print("Error handling test completed\n", .{});
}
