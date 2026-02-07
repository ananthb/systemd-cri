const std = @import("std");
const dbus = @import("systemd/dbus.zig");
const manager = @import("systemd/manager.zig");
const state_store = @import("state/store.zig");
const pod = @import("container/pod.zig");
const container = @import("container/container.zig");
const exec = @import("container/exec.zig");
const image_store = @import("image/store.zig");
const runtime_service = @import("cri/runtime_service.zig");
const image_service = @import("cri/image_service.zig");
const grpc = @import("server/grpc.zig");
const streaming = @import("server/streaming.zig");
const logging = @import("util/logging.zig");

const VERSION = "0.1.0";
const DEFAULT_STATE_DIR = "/var/lib/systemd-cri";
const DEFAULT_RUNTIME_DIR = "/run/systemd-cri";
const DEFAULT_STREAMING_PORT: u16 = 10010;

/// Command line arguments
const Args = struct {
    state_dir: []const u8,
    runtime_dir: []const u8,
    socket_path: []const u8,
    streaming_port: u16 = DEFAULT_STREAMING_PORT,
    log_level: logging.Level = .info,
    help: bool = false,
    version: bool = false,

    // Test commands for development
    test_run_pod: bool = false,
    test_list_pods: bool = false,
    test_stop_pod: ?[]const u8 = null,
    test_remove_pod: ?[]const u8 = null,
    test_pull_image: ?[]const u8 = null,

    // Owned memory that needs to be freed
    owned_socket_path: ?[]const u8 = null,

    pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        if (self.owned_socket_path) |p| {
            allocator.free(p);
        }
    }
};

fn parseArgs(allocator: std.mem.Allocator) !Args {
    // Read from environment variables (set by systemd) or use defaults
    const state_dir = std.posix.getenv("STATE_DIRECTORY") orelse DEFAULT_STATE_DIR;
    const runtime_dir = std.posix.getenv("RUNTIME_DIRECTORY") orelse DEFAULT_RUNTIME_DIR;

    // Build socket path from runtime directory
    const socket_path = try std.fs.path.join(allocator, &.{ runtime_dir, "cri.sock" });
    errdefer allocator.free(socket_path);

    var args = Args{
        .state_dir = state_dir,
        .runtime_dir = runtime_dir,
        .socket_path = socket_path,
        .owned_socket_path = socket_path,
    };

    var arg_it = try std.process.argsWithAllocator(allocator);
    defer arg_it.deinit();

    // Skip program name
    _ = arg_it.skip();

    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            args.help = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            args.version = true;
        } else if (std.mem.eql(u8, arg, "--state-dir")) {
            args.state_dir = arg_it.next() orelse {
                std.debug.print("Error: --state-dir requires a path argument\n", .{});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, arg, "--socket")) {
            const new_socket = arg_it.next() orelse {
                std.debug.print("Error: --socket requires a path argument\n", .{});
                return error.InvalidArgs;
            };
            // Free the computed socket path since user is overriding
            if (args.owned_socket_path) |p| {
                allocator.free(p);
                args.owned_socket_path = null;
            }
            args.socket_path = new_socket;
        } else if (std.mem.eql(u8, arg, "--streaming-port")) {
            const port_str = arg_it.next() orelse {
                std.debug.print("Error: --streaming-port requires a port number\n", .{});
                return error.InvalidArgs;
            };
            args.streaming_port = std.fmt.parseInt(u16, port_str, 10) catch {
                std.debug.print("Error: invalid port number: {s}\n", .{port_str});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            const level_str = arg_it.next() orelse {
                std.debug.print("Error: --log-level requires an argument\n", .{});
                return error.InvalidArgs;
            };
            if (std.mem.eql(u8, level_str, "debug")) {
                args.log_level = .debug;
            } else if (std.mem.eql(u8, level_str, "info")) {
                args.log_level = .info;
            } else if (std.mem.eql(u8, level_str, "warn")) {
                args.log_level = .warn;
            } else if (std.mem.eql(u8, level_str, "error")) {
                args.log_level = .err;
            } else {
                std.debug.print("Error: invalid log level: {s}\n", .{level_str});
                return error.InvalidArgs;
            }
        } else if (std.mem.eql(u8, arg, "--test-run-pod")) {
            args.test_run_pod = true;
        } else if (std.mem.eql(u8, arg, "--test-list-pods")) {
            args.test_list_pods = true;
        } else if (std.mem.eql(u8, arg, "--test-stop-pod")) {
            args.test_stop_pod = arg_it.next() orelse {
                std.debug.print("Error: --test-stop-pod requires a pod ID argument\n", .{});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, arg, "--test-remove-pod")) {
            args.test_remove_pod = arg_it.next() orelse {
                std.debug.print("Error: --test-remove-pod requires a pod ID argument\n", .{});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, arg, "--test-pull-image")) {
            args.test_pull_image = arg_it.next() orelse {
                std.debug.print("Error: --test-pull-image requires an image reference\n", .{});
                return error.InvalidArgs;
            };
        } else {
            std.debug.print("Error: unknown argument: {s}\n", .{arg});
            return error.InvalidArgs;
        }
    }

    return args;
}

fn printHelp() void {
    const help =
        \\systemd-cri - Container Runtime Interface using systemd
        \\
        \\Usage: systemd-cri [OPTIONS]
        \\
        \\Options:
        \\  -h, --help              Show this help message
        \\  -v, --version           Show version information
        \\  --state-dir PATH        State directory (default: $STATE_DIRECTORY or /var/lib/systemd-cri)
        \\  --socket PATH           gRPC socket path (default: $RUNTIME_DIRECTORY/cri.sock)
        \\  --streaming-port PORT   HTTP streaming port (default: 10010)
        \\  --log-level LEVEL       Log level: debug, info, warn, error (default: info)
        \\
        \\Environment Variables:
        \\  STATE_DIRECTORY         State directory (set by systemd StateDirectory=)
        \\  RUNTIME_DIRECTORY       Runtime directory (set by systemd RuntimeDirectory=)
        \\
        \\Development/Testing Commands:
        \\  --test-run-pod          Create a test pod sandbox
        \\  --test-list-pods        List all pod sandboxes
        \\  --test-stop-pod ID      Stop a pod sandbox by ID
        \\  --test-remove-pod ID    Remove a pod sandbox by ID
        \\  --test-pull-image REF   Pull an image by reference
        \\
    ;
    std.debug.print("{s}", .{help});
}

fn printVersion() void {
    std.debug.print("systemd-cri version {s}\n", .{VERSION});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    var args = parseArgs(allocator) catch {
        printHelp();
        std.process.exit(1);
    };
    defer args.deinit(allocator);

    if (args.help) {
        printHelp();
        return;
    }

    if (args.version) {
        printVersion();
        return;
    }

    // Initialize logging
    logging.initGlobal(args.log_level);
    logging.info("Starting systemd-cri v{s}", .{VERSION});
    logging.info("State directory: {s}", .{args.state_dir});
    logging.info("Runtime directory: {s}", .{args.runtime_dir});
    logging.info("Socket path: {s}", .{args.socket_path});

    // Open D-Bus connection
    var bus = dbus.Bus.openWithDescription(allocator, "systemd-cri") catch |err| {
        logging.err("Failed to connect to D-Bus: {}", .{err});
        std.process.exit(1);
    };
    defer bus.deinit();
    logging.info("Connected to D-Bus", .{});

    // Get unique name to verify connection
    const unique_name = bus.getUniqueName() catch |err| {
        logging.err("Failed to get D-Bus unique name: {}", .{err});
        std.process.exit(1);
    };
    logging.debug("D-Bus unique name: {s}", .{unique_name});

    // Initialize state store
    var store = state_store.Store.init(allocator, args.state_dir) catch |err| {
        logging.err("Failed to initialize state store: {}", .{err});
        std.process.exit(1);
    };
    defer store.deinit();
    logging.info("State store initialized", .{});

    // Initialize image store
    var img_store = image_store.ImageStore.init(allocator, args.state_dir) catch |err| {
        logging.err("Failed to initialize image store: {}", .{err});
        std.process.exit(1);
    };
    defer img_store.deinit();
    logging.info("Image store initialized", .{});

    // Initialize pod manager
    var pod_manager = pod.PodManager.init(allocator, &bus, &store);

    // Initialize container manager
    var container_manager = container.ContainerManager.init(allocator, &bus, &store, args.state_dir);

    // Handle test commands
    if (args.test_run_pod) {
        runTestPod(&pod_manager) catch |err| {
            logging.err("Test run pod failed: {}", .{err});
            std.process.exit(1);
        };
        return;
    }

    if (args.test_list_pods) {
        listTestPods(&pod_manager, allocator) catch |err| {
            logging.err("Test list pods failed: {}", .{err});
            std.process.exit(1);
        };
        return;
    }

    if (args.test_stop_pod) |pod_id| {
        pod_manager.stopPodSandbox(pod_id) catch |err| {
            logging.err("Stop pod failed: {}", .{err});
            std.process.exit(1);
        };
        std.debug.print("Pod {s} stopped\n", .{pod_id});
        return;
    }

    if (args.test_remove_pod) |pod_id| {
        pod_manager.removePodSandbox(pod_id) catch |err| {
            logging.err("Remove pod failed: {}", .{err});
            std.process.exit(1);
        };
        std.debug.print("Pod {s} removed\n", .{pod_id});
        return;
    }

    if (args.test_pull_image) |image_ref_arg| {
        testPullImage(allocator, &img_store, &bus, image_ref_arg) catch |err| {
            logging.err("Pull image failed: {}", .{err});
            std.process.exit(1);
        };
        return;
    }

    // Initialize CRI services
    var runtime_svc = runtime_service.RuntimeService.init(
        allocator,
        &pod_manager,
        &container_manager,
    );

    var image_svc = image_service.ImageService.init(allocator, &img_store, &bus) catch |err| {
        logging.err("Failed to initialize image service: {}", .{err});
        std.process.exit(1);
    };

    // Initialize executor for exec/attach
    var executor = exec.Executor.init(allocator, &store) catch |err| {
        logging.err("Failed to initialize executor: {}", .{err});
        std.process.exit(1);
    };
    defer executor.deinit();

    // Initialize streaming server
    var streaming_server = streaming.StreamingServer.init(
        allocator,
        &executor,
        args.streaming_port,
    );
    defer streaming_server.deinit();

    // Start streaming server
    streaming_server.start() catch |err| {
        logging.err("Failed to start streaming server: {}", .{err});
        std.process.exit(1);
    };
    logging.info("Streaming server started on port {d}", .{args.streaming_port});

    // Initialize and start gRPC server
    var grpc_server = grpc.GrpcServer.init(
        allocator,
        args.socket_path,
        &runtime_svc,
        &image_svc,
    ) catch |err| {
        logging.err("Failed to initialize gRPC server: {}", .{err});
        std.process.exit(1);
    };
    defer grpc_server.deinit();

    grpc_server.start() catch |err| {
        logging.err("Failed to start gRPC server: {}", .{err});
        std.process.exit(1);
    };

    logging.info("gRPC server started, listening on {s}", .{args.socket_path});
    logging.info("Ready to accept connections", .{});

    // Run the gRPC server main loop
    grpc_server.run() catch |err| {
        logging.err("gRPC server error: {}", .{err});
        std.process.exit(1);
    };
}

fn runTestPod(pod_manager: *pod.PodManager) !void {
    const config = pod.PodConfig{
        .name = "test-pod",
        .uid = "test-uid-12345",
        .namespace = "default",
        .labels = null,
        .annotations = null,
    };

    const pod_id = try pod_manager.runPodSandbox(&config);
    defer pod_manager.allocator.free(pod_id);

    std.debug.print("Created pod sandbox: {s}\n", .{pod_id});

    // Get status
    const status = try pod_manager.podSandboxStatus(pod_id);
    defer pod_manager.allocator.free(status.id);

    std.debug.print("Pod status: state={s} created_at={d}\n", .{
        status.state.toString(),
        status.created_at,
    });
}

fn listTestPods(pod_manager: *pod.PodManager, allocator: std.mem.Allocator) !void {
    var pods = try pod_manager.listPodSandboxes(null);
    defer {
        for (pods.items) |*p| {
            p.deinit(allocator);
        }
        pods.deinit(allocator);
    }

    if (pods.items.len == 0) {
        std.debug.print("No pod sandboxes found\n", .{});
        return;
    }

    std.debug.print("Pod Sandboxes ({d}):\n", .{pods.items.len});
    std.debug.print("{s:<40} {s:<20} {s:<15} {s}\n", .{ "ID", "NAME", "NAMESPACE", "STATE" });
    std.debug.print("{s}\n", .{"-" ** 80});

    for (pods.items) |p| {
        // Truncate ID for display
        const id_display = if (p.id.len > 36) p.id[0..36] else p.id;
        std.debug.print("{s:<40} {s:<20} {s:<15} {s}\n", .{
            id_display,
            p.name,
            p.namespace,
            p.state.toString(),
        });
    }
}

fn testPullImage(allocator: std.mem.Allocator, img_store: *image_store.ImageStore, bus: *dbus.Bus, image_ref: []const u8) !void {
    const image_pull = @import("image/pull.zig");

    var puller = try image_pull.ImagePuller.init(allocator, img_store, bus);
    defer puller.deinit();

    std.debug.print("Pulling image: {s}\n", .{image_ref});

    const image_id = puller.pullImage(image_ref, null) catch |err| {
        std.debug.print("Pull failed: {}\n", .{err});
        return err;
    };
    defer allocator.free(image_id);

    std.debug.print("Image pulled: {s}\n", .{image_id});
}

test "simple test" {
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.append(std.testing.allocator, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
