// systemd-cri library exports
//
// This module exports the public API for the systemd-cri library.

const std = @import("std");

// Systemd D-Bus interface
pub const dbus = @import("systemd/dbus.zig");
pub const manager = @import("systemd/manager.zig");
pub const properties = @import("systemd/properties.zig");

// Container management
pub const pod = @import("container/pod.zig");
pub const container = @import("container/container.zig");
pub const exec = @import("container/exec.zig");

// Image management
pub const image_store = @import("image/store.zig");
pub const image_pull = @import("image/pull.zig");
pub const image_machined = @import("image/machined.zig");

// Rootfs management
pub const overlay = @import("rootfs/overlay.zig");
pub const mount = @import("rootfs/mount.zig");

// Network
pub const cni = @import("network/cni.zig");

// CRI services
pub const types = @import("cri/types.zig");
pub const runtime_service = @import("cri/runtime_service.zig");
pub const image_service = @import("cri/image_service.zig");

// Server
pub const grpc = @import("server/grpc.zig");
pub const streaming = @import("server/streaming.zig");

// Metrics
pub const prometheus = @import("metrics/prometheus.zig");
pub const metrics_server = @import("metrics/server.zig");

// State persistence
pub const store = @import("state/store.zig");

// Utilities
pub const logging = @import("util/logging.zig");
pub const uuid = @import("util/uuid.zig");

// Re-export commonly used types
pub const Bus = dbus.Bus;
pub const BusError = dbus.BusError;
pub const Manager = manager.Manager;
pub const PodManager = pod.PodManager;
pub const PodConfig = pod.PodConfig;
pub const ContainerManager = container.ContainerManager;
pub const ContainerConfig = container.ContainerConfig;
pub const StateStore = store.Store;
pub const PodSandbox = store.PodSandbox;
pub const Container = store.Container;
pub const ImageStore = image_store.ImageStore;
pub const ImagePuller = image_pull.ImagePuller;
pub const MachineImageManager = image_machined.MachineImageManager;
pub const RuntimeService = runtime_service.RuntimeService;
pub const ImageService = image_service.ImageService;
pub const GrpcServer = grpc.GrpcServer;
pub const StreamingServer = streaming.StreamingServer;
pub const Cni = cni.Cni;
pub const MetricsRegistry = prometheus.Registry;
pub const MetricsServer = metrics_server.MetricsServer;

test {
    // Run all module tests
    std.testing.refAllDecls(@This());
}
