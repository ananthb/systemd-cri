const std = @import("std");
const posix = std.posix;

const Config = struct {
    socket_path: []const u8 = "/tmp/systemd-cri-test.sock",
    state_dir: []const u8 = "/tmp/systemd-cri-test-state",
    streaming_port: u16 = 10011,
    metrics_port: u16 = 9091,
    timeout_sec: u32 = 300,
    quick_mode: bool = false,
    verbose: bool = false,
    focus: ?[]const u8 = null,
    skip: ?[]const u8 = null,
};

const Color = struct {
    const red = "\x1b[0;31m";
    const green = "\x1b[0;32m";
    const yellow = "\x1b[1;33m";
    const blue = "\x1b[0;34m";
    const reset = "\x1b[0m";
};

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.green ++ "[critest]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
}

fn warn(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.yellow ++ "[critest]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
}

fn err(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.red ++ "[critest]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
}

fn info(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.blue ++ "[critest]" ++ Color.reset ++ " " ++ fmt ++ "\n", args);
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config = Config{};

    // Parse command line arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // Skip program name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--quick")) {
            config.quick_mode = true;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            config.verbose = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return 0;
        }
    }

    // Check environment variables
    if (std.posix.getenv("VERBOSE")) |_| {
        config.verbose = true;
    }
    if (std.posix.getenv("CRITEST_FOCUS")) |focus| {
        config.focus = focus;
    }
    if (std.posix.getenv("CRITEST_SKIP")) |skip| {
        config.skip = skip;
    }

    info("cri-tools test runner for systemd-cri", .{});
    info("======================================", .{});

    // Check prerequisites
    if (!checkDbus(allocator)) {
        return 1;
    }

    const is_root = std.os.linux.geteuid() == 0;
    if (!is_root) {
        warn("Not running as root - some tests will fail", .{});
        warn("Pod/Container lifecycle tests require root for systemd integration", .{});
    }

    // Check for critest
    if (!commandExists(allocator, "critest")) {
        err("critest not found. Install cri-tools or run in nix develop", .{});
        return 1;
    }

    // Find or build binary
    const binary = try findBinary(allocator);
    defer allocator.free(binary);
    log("Using binary: {s}", .{binary});

    // Start server
    var server_process = startServer(allocator, binary, &config) catch |e| {
        err("Failed to start server: {}", .{e});
        return 1;
    };
    defer {
        cleanup(&server_process, &config);
    }

    // Wait for socket
    if (!waitForSocket(config.socket_path, 30)) {
        err("Timeout waiting for socket", .{});
        return 1;
    }
    log("Socket is ready", .{});

    // Small delay to ensure server is fully ready
    std.Thread.sleep(500 * std.time.ns_per_ms);

    // Verify connectivity
    if (!verifyConnectivity(allocator, &config)) {
        err("Failed to connect to systemd-cri", .{});
        return 1;
    }
    log("Connection successful", .{});

    // Run tests
    const exit_code = if (config.quick_mode) blk: {
        break :blk runQuickTests(allocator, &config);
    } else if (!is_root) blk: {
        warn("Running without root - only runtime info tests will pass", .{});
        warn("For full test suite, run as root: sudo zig build critest", .{});
        break :blk runQuickTests(allocator, &config);
    } else blk: {
        break :blk runFullTests(allocator, &config);
    };

    if (exit_code == 0) {
        log("All tests passed!", .{});
    } else {
        err("Some tests failed (exit code: {d})", .{exit_code});
    }

    return exit_code;
}

fn printUsage() void {
    std.debug.print(
        \\Usage: critest-runner [OPTIONS]
        \\
        \\Run cri-tools validation tests against systemd-cri.
        \\
        \\Options:
        \\  --quick     Run quick sanity tests only (runtime info)
        \\  --verbose   Enable verbose output
        \\  --help      Show this help message
        \\
        \\Environment Variables:
        \\  CRITEST_FOCUS   Ginkgo focus pattern for specific tests
        \\  CRITEST_SKIP    Ginkgo skip pattern to exclude tests
        \\  VERBOSE         Enable verbose output (any value)
        \\
        \\Requirements:
        \\  - Root privileges (for full tests)
        \\  - D-Bus system bus available
        \\  - cri-tools (critest) installed
        \\
    , .{});
}

fn checkDbus(allocator: std.mem.Allocator) bool {
    const args = [_][]const u8{
        "dbus-send",
        "--system",
        "--dest=org.freedesktop.DBus",
        "--type=method_call",
        "--print-reply",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus.ListNames",
    };

    var child = std.process.Child.init(&args, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch {
        err("D-Bus system bus is not available", .{});
        return false;
    };

    const term = child.wait() catch {
        err("D-Bus check failed", .{});
        return false;
    };

    if (term.Exited != 0) {
        err("D-Bus system bus is not available", .{});
        return false;
    }

    return true;
}

fn commandExists(allocator: std.mem.Allocator, cmd: []const u8) bool {
    const args = [_][]const u8{ "which", cmd };

    var child = std.process.Child.init(&args, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return false;
    const term = child.wait() catch return false;

    return term.Exited == 0;
}

fn findBinary(allocator: std.mem.Allocator) ![]const u8 {
    // Check for pre-built binary
    if (std.fs.cwd().access("zig-out/bin/systemd-cri", .{})) |_| {
        return allocator.dupe(u8, "zig-out/bin/systemd-cri");
    } else |_| {}

    // Try PATH
    if (std.process.getEnvVarOwned(allocator, "PATH")) |path| {
        defer allocator.free(path);
        var it = std.mem.splitScalar(u8, path, ':');
        while (it.next()) |dir| {
            const full_path = try std.fs.path.join(allocator, &.{ dir, "systemd-cri" });
            defer allocator.free(full_path);
            if (std.fs.cwd().access(full_path, .{})) |_| {
                return allocator.dupe(u8, full_path);
            } else |_| {}
        }
    } else |_| {}

    // Build it
    log("Building systemd-cri...", .{});
    const build_args = [_][]const u8{ "zig", "build", "-Doptimize=ReleaseSafe" };

    var child = std.process.Child.init(&build_args, allocator);
    child.spawn() catch return error.BuildFailed;
    const term = child.wait() catch return error.BuildFailed;

    if (term.Exited != 0) {
        return error.BuildFailed;
    }

    return allocator.dupe(u8, "zig-out/bin/systemd-cri");
}

fn startServer(allocator: std.mem.Allocator, binary: []const u8, config: *const Config) !std.process.Child {
    log("Starting systemd-cri...", .{});
    log("  Socket: {s}", .{config.socket_path});
    log("  State dir: {s}", .{config.state_dir});
    log("  Streaming port: {d}", .{config.streaming_port});
    log("  Metrics port: {d}", .{config.metrics_port});

    // Create state directory
    std.fs.makeDirAbsolute(config.state_dir) catch |e| {
        if (e != error.PathAlreadyExists) return e;
    };

    // Remove old socket
    std.fs.deleteFileAbsolute(config.socket_path) catch {};

    var streaming_port_buf: [8]u8 = undefined;
    const streaming_port_str = std.fmt.bufPrint(&streaming_port_buf, "{d}", .{config.streaming_port}) catch unreachable;

    var metrics_port_buf: [8]u8 = undefined;
    const metrics_port_str = std.fmt.bufPrint(&metrics_port_buf, "{d}", .{config.metrics_port}) catch unreachable;

    const args = [_][]const u8{
        binary,
        "--socket",
        config.socket_path,
        "--state-dir",
        config.state_dir,
        "--streaming-port",
        streaming_port_str,
        "--metrics-port",
        metrics_port_str,
        "--log-level",
        "info",
    };

    var child = std.process.Child.init(&args, allocator);
    try child.spawn();

    log("Server started with PID {d}", .{child.id});
    return child;
}

fn waitForSocket(socket_path: []const u8, timeout_sec: u32) bool {
    log("Waiting for socket to be ready...", .{});

    var elapsed: u32 = 0;
    while (elapsed < timeout_sec * 2) : (elapsed += 1) {
        // Check if socket exists
        if (std.fs.accessAbsolute(socket_path, .{})) |_| {
            return true;
        } else |_| {}

        std.Thread.sleep(500 * std.time.ns_per_ms);
    }

    return false;
}

fn verifyConnectivity(allocator: std.mem.Allocator, config: *const Config) bool {
    log("Testing connectivity with crictl...", .{});

    var endpoint_buf: [256]u8 = undefined;
    const endpoint = std.fmt.bufPrint(&endpoint_buf, "unix://{s}", .{config.socket_path}) catch return false;

    const args = [_][]const u8{
        "crictl",
        "--runtime-endpoint",
        endpoint,
        "--image-endpoint",
        endpoint,
        "version",
    };

    var child = std.process.Child.init(&args, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return false;
    const term = child.wait() catch return false;

    return term.Exited == 0;
}

fn runQuickTests(allocator: std.mem.Allocator, config: *const Config) u8 {
    log("Running quick sanity tests...", .{});
    return runCritest(allocator, config, "runtime info");
}

fn runFullTests(allocator: std.mem.Allocator, config: *const Config) u8 {
    log("Running full test suite...", .{});

    // Build skip pattern
    const default_skips = "should support seccomp|SELinux|Apparmor|ListMetricDescriptors|propagate mounts to the host";

    var skip_pattern: []const u8 = default_skips;
    if (config.skip) |user_skip| {
        // Would need to concatenate, but for now just use user skip if provided
        skip_pattern = user_skip;
    }

    return runCritestWithSkip(allocator, config, config.focus, skip_pattern);
}

fn runCritest(allocator: std.mem.Allocator, config: *const Config, focus: ?[]const u8) u8 {
    return runCritestWithSkip(allocator, config, focus, null);
}

fn runCritestWithSkip(allocator: std.mem.Allocator, config: *const Config, focus: ?[]const u8, skip: ?[]const u8) u8 {
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(allocator);

    var endpoint_buf: [256]u8 = undefined;
    const endpoint = std.fmt.bufPrint(&endpoint_buf, "unix://{s}", .{config.socket_path}) catch return 1;

    args_list.appendSlice(allocator, &.{
        "critest",
        "--runtime-endpoint",
        endpoint,
        "--image-endpoint",
        endpoint,
        "--ginkgo.no-color",
    }) catch return 1;

    if (focus) |f| {
        args_list.appendSlice(allocator, &.{ "--ginkgo.focus", f }) catch return 1;
    }

    if (skip) |s| {
        args_list.appendSlice(allocator, &.{ "--ginkgo.skip", s }) catch return 1;
    }

    if (config.verbose) {
        args_list.append(allocator, "--ginkgo.v") catch return 1;
    }

    var child = std.process.Child.init(args_list.items, allocator);
    child.spawn() catch return 1;

    const term = child.wait() catch return 1;

    return term.Exited;
}

fn cleanup(server_process: *std.process.Child, config: *const Config) void {
    log("Cleaning up...", .{});

    // Stop server
    if (server_process.id != 0) {
        log("Stopping systemd-cri (PID {d})", .{server_process.id});
        _ = server_process.kill() catch {};
        _ = server_process.wait() catch {};
    }

    // Remove socket
    std.fs.deleteFileAbsolute(config.socket_path) catch {};

    // Remove state directory
    std.fs.deleteTreeAbsolute(config.state_dir) catch {};

    // Clean up test images from machined
    cleanupTestImages();
}

fn cleanupTestImages() void {
    log("Cleaning up test images...", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get list of images using machinectl
    const list_args = [_][]const u8{ "machinectl", "list-images", "--no-legend" };

    var child = std.process.Child.init(&list_args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return;

    const stdout = child.stdout orelse return;

    // Read all output
    var output_buf: [64 * 1024]u8 = undefined;
    var output_len: usize = 0;
    while (true) {
        const n = stdout.read(output_buf[output_len..]) catch break;
        if (n == 0) break;
        output_len += n;
        if (output_len >= output_buf.len) break;
    }

    _ = child.wait() catch return;

    const output = output_buf[0..output_len];

    // Test image prefixes used by critest
    const test_prefixes = [_][]const u8{
        "e2etestimages-",
        "k8sstagingcritools-",
    };

    // Parse output and remove test images
    var removed_count: usize = 0;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // First column is the image name (space-separated)
        var cols = std.mem.tokenizeScalar(u8, line, ' ');
        const image_name = cols.next() orelse continue;

        // Check if this is a test image
        for (test_prefixes) |prefix| {
            if (std.mem.startsWith(u8, image_name, prefix)) {
                if (removeImage(allocator, image_name)) {
                    removed_count += 1;
                }
                break;
            }
        }
    }

    if (removed_count > 0) {
        log("Removed {d} test image(s)", .{removed_count});
    }
}

fn removeImage(allocator: std.mem.Allocator, image_name: []const u8) bool {
    const args = [_][]const u8{ "machinectl", "remove", image_name };

    var child = std.process.Child.init(&args, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return false;
    const term = child.wait() catch return false;

    return term.Exited == 0;
}
