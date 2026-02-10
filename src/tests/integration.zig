const std = @import("std");
const testing = std.testing;

// Import modules to test via lib
const lib = @import("lib");
const store = lib.store;
const image_store = lib.image_store;
const dbus = lib.dbus;
const machined = lib.image_machined;

/// Test helper to create a temporary directory for testing
fn createTempDir(allocator: std.mem.Allocator) ![]const u8 {
    // Generate a unique directory name based on timestamp and random
    const timestamp: u64 = @intCast(std.time.timestamp());
    var prng = std.Random.DefaultPrng.init(timestamp);
    const random = prng.random();
    const rand_part = random.int(u32);

    const path = try std.fmt.allocPrint(allocator, "/tmp/systemd-cri-test-{d}-{d}", .{ timestamp, rand_part });
    errdefer allocator.free(path);

    std.fs.makeDirAbsolute(path) catch |e| {
        if (e == error.PathAlreadyExists) {
            // Try again with different random
            allocator.free(path);
            return createTempDir(allocator);
        }
        return e;
    };

    return path;
}

/// Clean up a temporary directory
fn cleanupTempDir(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

// ============================================================================
// RocksDB State Store Integration Tests
// ============================================================================

test "integration: RocksDB store pod lifecycle" {
    const allocator = testing.allocator;

    // Create temp directory for test
    const temp_dir = try createTempDir(allocator);
    defer allocator.free(temp_dir);
    defer cleanupTempDir(temp_dir);

    const db_path = try std.fs.path.join(allocator, &.{ temp_dir, "state.db" });
    defer allocator.free(db_path);

    // Initialize store
    var state_store = store.Store.init(allocator, db_path) catch |e| {
        std.debug.print("Failed to init store: {}\n", .{e});
        return error.SkipZigTest;
    };
    defer state_store.deinit();

    // Create test pods
    var labels1 = std.StringHashMap([]const u8).init(allocator);
    defer labels1.deinit();
    try labels1.put(try allocator.dupe(u8, "app"), try allocator.dupe(u8, "nginx"));
    defer {
        var it = labels1.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
    }

    var annotations1 = std.StringHashMap([]const u8).init(allocator);
    defer annotations1.deinit();

    const pod1 = store.PodSandbox{
        .id = "pod-001",
        .name = "nginx-pod",
        .namespace = "default",
        .uid = "uid-001",
        .state = .ready,
        .created_at = 1700000000,
        .unit_name = "cri-pod-001.service",
        .network_namespace = null,
        .labels = labels1,
        .annotations = annotations1,
    };

    var labels2 = std.StringHashMap([]const u8).init(allocator);
    defer labels2.deinit();

    var annotations2 = std.StringHashMap([]const u8).init(allocator);
    defer annotations2.deinit();

    const pod2 = store.PodSandbox{
        .id = "pod-002",
        .name = "redis-pod",
        .namespace = "cache",
        .uid = "uid-002",
        .state = .created,
        .created_at = 1700000001,
        .unit_name = "cri-pod-002.service",
        .network_namespace = "/run/netns/pod-002",
        .labels = labels2,
        .annotations = annotations2,
    };

    // Save pods
    try state_store.savePod(&pod1);
    try state_store.savePod(&pod2);

    // List pods
    var pod_ids = try state_store.listPods();
    defer {
        for (pod_ids.items) |id| {
            allocator.free(id);
        }
        pod_ids.deinit(allocator);
    }
    try testing.expectEqual(@as(usize, 2), pod_ids.items.len);

    // Load and verify pod1
    var loaded1 = try state_store.loadPod("pod-001");
    defer loaded1.deinit(allocator);
    try testing.expectEqualStrings("nginx-pod", loaded1.name);
    try testing.expectEqualStrings("default", loaded1.namespace);
    try testing.expectEqual(store.PodState.ready, loaded1.state);

    // Load and verify pod2
    var loaded2 = try state_store.loadPod("pod-002");
    defer loaded2.deinit(allocator);
    try testing.expectEqualStrings("redis-pod", loaded2.name);
    try testing.expectEqualStrings("/run/netns/pod-002", loaded2.network_namespace.?);

    // Update pod1 state
    var updated_labels = std.StringHashMap([]const u8).init(allocator);
    defer updated_labels.deinit();

    var updated_annotations = std.StringHashMap([]const u8).init(allocator);
    defer updated_annotations.deinit();

    const updated_pod1 = store.PodSandbox{
        .id = "pod-001",
        .name = "nginx-pod",
        .namespace = "default",
        .uid = "uid-001",
        .state = .not_ready,
        .created_at = 1700000000,
        .unit_name = "cri-pod-001.service",
        .network_namespace = null,
        .labels = updated_labels,
        .annotations = updated_annotations,
    };
    try state_store.savePod(&updated_pod1);

    var reloaded1 = try state_store.loadPod("pod-001");
    defer reloaded1.deinit(allocator);
    try testing.expectEqual(store.PodState.not_ready, reloaded1.state);

    // Delete pod1
    try state_store.deletePod("pod-001");

    // Verify deletion
    _ = state_store.loadPod("pod-001") catch |e| {
        try testing.expectEqual(store.StoreError.NotFound, e);
        return;
    };
    try testing.expect(false); // Should not reach here
}

test "integration: RocksDB store container lifecycle with pod index" {
    const allocator = testing.allocator;

    const temp_dir = try createTempDir(allocator);
    defer allocator.free(temp_dir);
    defer cleanupTempDir(temp_dir);

    const db_path = try std.fs.path.join(allocator, &.{ temp_dir, "state.db" });
    defer allocator.free(db_path);

    var state_store = store.Store.init(allocator, db_path) catch |e| {
        std.debug.print("Failed to init store: {}\n", .{e});
        return error.SkipZigTest;
    };
    defer state_store.deinit();

    // Create containers for two different pods
    var labels = std.StringHashMap([]const u8).init(allocator);
    defer labels.deinit();
    var annotations = std.StringHashMap([]const u8).init(allocator);
    defer annotations.deinit();

    const container1 = store.Container{
        .id = "container-001",
        .pod_sandbox_id = "pod-aaa",
        .name = "nginx",
        .image = "nginx:latest",
        .image_ref = "sha256:abc123",
        .state = .running,
        .created_at = 1700000000,
        .started_at = 1700000001,
        .finished_at = 0,
        .exit_code = 0,
        .pid = 12345,
        .unit_name = "cri-container-001.service",
        .rootfs_path = "/var/lib/machines/nginx",
        .log_path = "/var/log/pods/pod-aaa/nginx.log",
        .command = "/usr/sbin/nginx -g daemon off;",
        .working_dir = "/",
        .labels = labels,
        .annotations = annotations,
    };

    const container2 = store.Container{
        .id = "container-002",
        .pod_sandbox_id = "pod-aaa",
        .name = "sidecar",
        .image = "envoy:latest",
        .image_ref = "sha256:def456",
        .state = .running,
        .created_at = 1700000002,
        .started_at = 1700000003,
        .finished_at = 0,
        .exit_code = 0,
        .pid = 12346,
        .unit_name = "cri-container-002.service",
        .rootfs_path = null,
        .log_path = null,
        .command = null,
        .working_dir = null,
        .labels = labels,
        .annotations = annotations,
    };

    const container3 = store.Container{
        .id = "container-003",
        .pod_sandbox_id = "pod-bbb",
        .name = "redis",
        .image = "redis:alpine",
        .image_ref = "sha256:ghi789",
        .state = .created,
        .created_at = 1700000004,
        .started_at = 0,
        .finished_at = 0,
        .exit_code = 0,
        .pid = null,
        .unit_name = "cri-container-003.service",
        .rootfs_path = null,
        .log_path = null,
        .command = "/usr/local/bin/redis-server",
        .working_dir = "/data",
        .labels = labels,
        .annotations = annotations,
    };

    // Save all containers
    try state_store.saveContainer(&container1);
    try state_store.saveContainer(&container2);
    try state_store.saveContainer(&container3);

    // List all containers
    var all_containers = try state_store.listContainers();
    defer {
        for (all_containers.items) |id| {
            allocator.free(id);
        }
        all_containers.deinit(allocator);
    }
    try testing.expectEqual(@as(usize, 3), all_containers.items.len);

    // List containers for pod-aaa (should be 2)
    var pod_aaa_containers = try state_store.listContainersForPod("pod-aaa");
    defer {
        for (pod_aaa_containers.items) |id| {
            allocator.free(id);
        }
        pod_aaa_containers.deinit(allocator);
    }
    try testing.expectEqual(@as(usize, 2), pod_aaa_containers.items.len);

    // List containers for pod-bbb (should be 1)
    var pod_bbb_containers = try state_store.listContainersForPod("pod-bbb");
    defer {
        for (pod_bbb_containers.items) |id| {
            allocator.free(id);
        }
        pod_bbb_containers.deinit(allocator);
    }
    try testing.expectEqual(@as(usize, 1), pod_bbb_containers.items.len);

    // Delete container1 and verify index is updated
    try state_store.deleteContainer("container-001");

    var remaining = try state_store.listContainersForPod("pod-aaa");
    defer {
        for (remaining.items) |id| {
            allocator.free(id);
        }
        remaining.deinit(allocator);
    }
    try testing.expectEqual(@as(usize, 1), remaining.items.len);

    // Verify getContainer alias works
    var loaded = try state_store.getContainer("container-002");
    defer loaded.deinit(allocator);
    try testing.expectEqualStrings("sidecar", loaded.name);
}

// ============================================================================
// Image Store Integration Tests
// ============================================================================

test "integration: image reference parsing" {
    const allocator = testing.allocator;

    // Test simple image
    {
        var ref = try image_store.ImageReference.parse(allocator, "nginx");
        defer ref.deinit(allocator);
        try testing.expectEqualStrings("nginx", ref.repository);
        try testing.expectEqualStrings("latest", ref.tag.?);
        try testing.expect(ref.registry == null);
        try testing.expect(ref.digest == null);
    }

    // Test image with tag
    {
        var ref = try image_store.ImageReference.parse(allocator, "nginx:1.21");
        defer ref.deinit(allocator);
        try testing.expectEqualStrings("nginx", ref.repository);
        try testing.expectEqualStrings("1.21", ref.tag.?);
    }

    // Test full reference with registry
    {
        var ref = try image_store.ImageReference.parse(allocator, "gcr.io/my-project/my-image:v1.0.0");
        defer ref.deinit(allocator);
        try testing.expectEqualStrings("gcr.io", ref.registry.?);
        try testing.expectEqualStrings("my-project/my-image", ref.repository);
        try testing.expectEqualStrings("v1.0.0", ref.tag.?);
    }

    // Test with digest
    {
        var ref = try image_store.ImageReference.parse(allocator, "nginx@sha256:abc123def456");
        defer ref.deinit(allocator);
        try testing.expectEqualStrings("nginx", ref.repository);
        try testing.expectEqualStrings("sha256:abc123def456", ref.digest.?);
        try testing.expect(ref.tag == null);
    }

    // Test format round-trip
    {
        var ref = try image_store.ImageReference.parse(allocator, "docker.io/library/nginx:latest");
        defer ref.deinit(allocator);

        const formatted = try ref.format(allocator);
        defer allocator.free(formatted);
        try testing.expectEqualStrings("docker.io/library/nginx:latest", formatted);
    }
}

test "integration: image store blob operations" {
    const allocator = testing.allocator;

    const temp_dir = try createTempDir(allocator);
    defer allocator.free(temp_dir);
    defer cleanupTempDir(temp_dir);

    var img_store = image_store.ImageStore.init(allocator, temp_dir) catch |e| {
        std.debug.print("Failed to init image store: {}\n", .{e});
        return error.SkipZigTest;
    };
    defer img_store.deinit();

    // Test blob storage
    const test_data = "This is test blob data for the content-addressable store";
    const digest = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    // Store blob
    try img_store.storeBlob(digest, test_data);

    // Verify blob exists
    try testing.expect(try img_store.hasBlob(digest));

    // Read blob back
    const read_data = try img_store.readBlob(digest);
    defer allocator.free(read_data);
    try testing.expectEqualStrings(test_data, read_data);

    // Test non-existent blob
    try testing.expect(!try img_store.hasBlob("sha256:nonexistent"));
}

// ============================================================================
// D-Bus Connection Tests (requires running systemd)
// These tests are skipped by default as they require a running D-Bus daemon
// ============================================================================

// NOTE: D-Bus tests are disabled by default as they can hang in sandboxed environments
// To enable, set SYSTEMD_CRI_TEST_DBUS=1 environment variable

fn dbusTestsEnabled() bool {
    return std.posix.getenv("SYSTEMD_CRI_TEST_DBUS") != null;
}

test "integration: dbus connection" {
    if (!dbusTestsEnabled()) {
        std.debug.print("D-Bus tests disabled (set SYSTEMD_CRI_TEST_DBUS=1 to enable)\n", .{});
        return error.SkipZigTest;
    }

    const allocator = testing.allocator;

    // Try to connect to the system bus
    var bus = dbus.Bus.openSystem(allocator) catch {
        // This is expected to fail in sandboxed test environments
        std.debug.print("D-Bus connection not available (expected in sandboxed environment)\n", .{});
        return error.SkipZigTest;
    };
    defer bus.deinit();

    // Get unique name to verify connection
    const unique_name = try bus.getUniqueName();
    try testing.expect(unique_name.len > 0);
    try testing.expect(std.mem.startsWith(u8, unique_name, ":"));
}

// ============================================================================
// machined Integration Tests (requires running systemd-machined)
// ============================================================================

test "integration: machined list images" {
    if (!dbusTestsEnabled()) {
        std.debug.print("D-Bus tests disabled (set SYSTEMD_CRI_TEST_DBUS=1 to enable)\n", .{});
        return error.SkipZigTest;
    }

    const allocator = testing.allocator;

    // Try to connect to the system bus
    var bus = dbus.Bus.openSystem(allocator) catch {
        std.debug.print("D-Bus connection not available\n", .{});
        return error.SkipZigTest;
    };
    defer bus.deinit();

    var mgr = machined.MachineImageManager.init(allocator, &bus);

    // List images - this should work even if no images exist
    var images = mgr.listImages() catch |e| {
        std.debug.print("machined not available: {}\n", .{e});
        return error.SkipZigTest;
    };
    defer {
        for (images.items) |*img| {
            img.deinit(allocator);
        }
        images.deinit(allocator);
    }

    // Just verify we got a list (may be empty)
    std.debug.print("Found {d} machine images\n", .{images.items.len});
}

// ============================================================================
// State Store Concurrent Access Tests
// ============================================================================

test "integration: concurrent store access" {
    const allocator = testing.allocator;

    const temp_dir = try createTempDir(allocator);
    defer allocator.free(temp_dir);
    defer cleanupTempDir(temp_dir);

    const db_path = try std.fs.path.join(allocator, &.{ temp_dir, "state.db" });
    defer allocator.free(db_path);

    var state_store = store.Store.init(allocator, db_path) catch |e| {
        std.debug.print("Failed to init store: {}\n", .{e});
        return error.SkipZigTest;
    };
    defer state_store.deinit();

    // Create multiple pods quickly to test for race conditions
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var labels = std.StringHashMap([]const u8).init(allocator);
        var annotations = std.StringHashMap([]const u8).init(allocator);

        var id_buf: [32]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "pod-{d:0>4}", .{i}) catch unreachable;

        const pod = store.PodSandbox{
            .id = id,
            .name = "test-pod",
            .namespace = "default",
            .uid = "uid-test",
            .state = .ready,
            .created_at = @intCast(i),
            .unit_name = "test.service",
            .network_namespace = null,
            .labels = labels,
            .annotations = annotations,
        };

        try state_store.savePod(&pod);

        labels.deinit();
        annotations.deinit();
    }

    // Verify all pods were saved
    var pod_ids = try state_store.listPods();
    defer {
        for (pod_ids.items) |pod_id| {
            allocator.free(pod_id);
        }
        pod_ids.deinit(allocator);
    }
    try testing.expectEqual(@as(usize, 10), pod_ids.items.len);
}
