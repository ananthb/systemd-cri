const std = @import("std");

// Import protobuf-c and generated CRI types
pub const c = @cImport({
    // Undefine linux macro which conflicts with struct field names
    @cUndef("linux");
    @cInclude("protobuf-c/protobuf-c.h");
    @cInclude("api.pb-c.h");
});

/// Protobuf allocator that uses Zig allocator
pub const ProtobufAllocator = struct {
    zig_allocator: std.mem.Allocator,
    c_allocator: c.ProtobufCAllocator,

    pub fn init(allocator: std.mem.Allocator) ProtobufAllocator {
        return .{
            .zig_allocator = allocator,
            .c_allocator = .{
                .alloc = allocFn,
                .free = freeFn,
                .allocator_data = @ptrCast(@constCast(&allocator)),
            },
        };
    }

    fn allocFn(allocator_data: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
        const zig_alloc: *std.mem.Allocator = @ptrCast(@alignCast(allocator_data));
        const slice = zig_alloc.alignedAlloc(u8, @alignOf(std.c.max_align_t), size) catch return null;
        return slice.ptr;
    }

    fn freeFn(allocator_data: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
        if (ptr == null) return;
        const zig_alloc: *std.mem.Allocator = @ptrCast(@alignCast(allocator_data));
        // We don't know the size, so we can't free properly
        // This is a limitation - in practice we use the default allocator
        _ = zig_alloc;
    }
};

// Type aliases for cleaner code
pub const VersionRequest = c.Runtime__V1__VersionRequest;
pub const VersionResponse = c.Runtime__V1__VersionResponse;
pub const RunPodSandboxRequest = c.Runtime__V1__RunPodSandboxRequest;
pub const RunPodSandboxResponse = c.Runtime__V1__RunPodSandboxResponse;
pub const StopPodSandboxRequest = c.Runtime__V1__StopPodSandboxRequest;
pub const StopPodSandboxResponse = c.Runtime__V1__StopPodSandboxResponse;
pub const RemovePodSandboxRequest = c.Runtime__V1__RemovePodSandboxRequest;
pub const RemovePodSandboxResponse = c.Runtime__V1__RemovePodSandboxResponse;
pub const PodSandboxStatusRequest = c.Runtime__V1__PodSandboxStatusRequest;
pub const PodSandboxStatusResponse = c.Runtime__V1__PodSandboxStatusResponse;
pub const ListPodSandboxRequest = c.Runtime__V1__ListPodSandboxRequest;
pub const ListPodSandboxResponse = c.Runtime__V1__ListPodSandboxResponse;
pub const CreateContainerRequest = c.Runtime__V1__CreateContainerRequest;
pub const CreateContainerResponse = c.Runtime__V1__CreateContainerResponse;
pub const StartContainerRequest = c.Runtime__V1__StartContainerRequest;
pub const StartContainerResponse = c.Runtime__V1__StartContainerResponse;
pub const StopContainerRequest = c.Runtime__V1__StopContainerRequest;
pub const StopContainerResponse = c.Runtime__V1__StopContainerResponse;
pub const RemoveContainerRequest = c.Runtime__V1__RemoveContainerRequest;
pub const RemoveContainerResponse = c.Runtime__V1__RemoveContainerResponse;
pub const ContainerStatusRequest = c.Runtime__V1__ContainerStatusRequest;
pub const ContainerStatusResponse = c.Runtime__V1__ContainerStatusResponse;
pub const ListContainersRequest = c.Runtime__V1__ListContainersRequest;
pub const ListContainersResponse = c.Runtime__V1__ListContainersResponse;
pub const ExecSyncRequest = c.Runtime__V1__ExecSyncRequest;
pub const ExecSyncResponse = c.Runtime__V1__ExecSyncResponse;
pub const ExecRequest = c.Runtime__V1__ExecRequest;
pub const ExecResponse = c.Runtime__V1__ExecResponse;
pub const AttachRequest = c.Runtime__V1__AttachRequest;
pub const AttachResponse = c.Runtime__V1__AttachResponse;
pub const PortForwardRequest = c.Runtime__V1__PortForwardRequest;
pub const PortForwardResponse = c.Runtime__V1__PortForwardResponse;
pub const StatusRequest = c.Runtime__V1__StatusRequest;
pub const StatusResponse = c.Runtime__V1__StatusResponse;
pub const UpdateRuntimeConfigRequest = c.Runtime__V1__UpdateRuntimeConfigRequest;
pub const UpdateRuntimeConfigResponse = c.Runtime__V1__UpdateRuntimeConfigResponse;
pub const RuntimeConfigRequest = c.Runtime__V1__RuntimeConfigRequest;
pub const RuntimeConfigResponse = c.Runtime__V1__RuntimeConfigResponse;
pub const LinuxRuntimeConfiguration = c.Runtime__V1__LinuxRuntimeConfiguration;
pub const ContainerStatsRequest = c.Runtime__V1__ContainerStatsRequest;
pub const ContainerStatsResponse = c.Runtime__V1__ContainerStatsResponse;
pub const ListContainerStatsRequest = c.Runtime__V1__ListContainerStatsRequest;
pub const ListContainerStatsResponse = c.Runtime__V1__ListContainerStatsResponse;
pub const PodSandboxStatsRequest = c.Runtime__V1__PodSandboxStatsRequest;
pub const PodSandboxStatsResponse = c.Runtime__V1__PodSandboxStatsResponse;
pub const ListPodSandboxStatsRequest = c.Runtime__V1__ListPodSandboxStatsRequest;
pub const ListPodSandboxStatsResponse = c.Runtime__V1__ListPodSandboxStatsResponse;
pub const ReopenContainerLogRequest = c.Runtime__V1__ReopenContainerLogRequest;
pub const ReopenContainerLogResponse = c.Runtime__V1__ReopenContainerLogResponse;

// Image service types
pub const ListImagesRequest = c.Runtime__V1__ListImagesRequest;
pub const ListImagesResponse = c.Runtime__V1__ListImagesResponse;
pub const ImageStatusRequest = c.Runtime__V1__ImageStatusRequest;
pub const ImageStatusResponse = c.Runtime__V1__ImageStatusResponse;
pub const PullImageRequest = c.Runtime__V1__PullImageRequest;
pub const PullImageResponse = c.Runtime__V1__PullImageResponse;
pub const RemoveImageRequest = c.Runtime__V1__RemoveImageRequest;
pub const RemoveImageResponse = c.Runtime__V1__RemoveImageResponse;
pub const ImageFsInfoRequest = c.Runtime__V1__ImageFsInfoRequest;
pub const ImageFsInfoResponse = c.Runtime__V1__ImageFsInfoResponse;

// Common types
pub const PodSandboxConfig = c.Runtime__V1__PodSandboxConfig;
pub const PodSandboxMetadata = c.Runtime__V1__PodSandboxMetadata;
pub const PodSandboxStatus = c.Runtime__V1__PodSandboxStatus;
pub const PodSandbox = c.Runtime__V1__PodSandbox;
pub const PodSandboxFilter = c.Runtime__V1__PodSandboxFilter;
pub const ContainerConfig = c.Runtime__V1__ContainerConfig;
pub const ContainerMetadata = c.Runtime__V1__ContainerMetadata;
pub const ContainerStatus = c.Runtime__V1__ContainerStatus;
pub const ContainerStatusProto = c.Runtime__V1__ContainerStatus;
pub const Container = c.Runtime__V1__Container;
pub const ContainerFilter = c.Runtime__V1__ContainerFilter;
pub const ImageSpec = c.Runtime__V1__ImageSpec;
pub const Image = c.Runtime__V1__Image;
pub const ImageFilter = c.Runtime__V1__ImageFilter;
pub const AuthConfig = c.Runtime__V1__AuthConfig;
pub const LinuxPodSandboxConfig = c.Runtime__V1__LinuxPodSandboxConfig;
pub const LinuxContainerConfig = c.Runtime__V1__LinuxContainerConfig;
pub const LinuxContainerResources = c.Runtime__V1__LinuxContainerResources;
pub const RuntimeCondition = c.Runtime__V1__RuntimeCondition;
pub const RuntimeStatus = c.Runtime__V1__RuntimeStatus;
pub const FilesystemUsage = c.Runtime__V1__FilesystemUsage;
pub const ContainerStats = c.Runtime__V1__ContainerStats;
pub const ContainerAttributes = c.Runtime__V1__ContainerAttributes;
pub const CpuUsage = c.Runtime__V1__CpuUsage;
pub const MemoryUsage = c.Runtime__V1__MemoryUsage;
pub const UInt64Value = c.Runtime__V1__UInt64Value;
pub const ContainerStatsFilter = c.Runtime__V1__ContainerStatsFilter;
pub const PodSandboxStats = c.Runtime__V1__PodSandboxStats;
pub const PodSandboxNetworkStatus = c.Runtime__V1__PodSandboxNetworkStatus;
pub const PodIP = c.Runtime__V1__PodIP;
pub const Mount = c.Runtime__V1__Mount;
pub const MountPropagation = c.Runtime__V1__MountPropagation;

// State enums
pub const PodSandboxState = c.Runtime__V1__PodSandboxState;
pub const ContainerState = c.Runtime__V1__ContainerState;

/// Unpack a protobuf message from binary data
pub fn unpack(comptime T: type, data: []const u8) ?*T {
    const descriptor = getDescriptor(T);
    return @ptrCast(@alignCast(c.protobuf_c_message_unpack(
        descriptor,
        null,
        data.len,
        data.ptr,
    )));
}

/// Pack a protobuf message to binary data
pub fn pack(allocator: std.mem.Allocator, msg: anytype) ![]u8 {
    const ptr: *const c.ProtobufCMessage = @ptrCast(msg);
    const size = c.protobuf_c_message_get_packed_size(ptr);
    const buf = try allocator.alloc(u8, size);
    _ = c.protobuf_c_message_pack(ptr, buf.ptr);
    return buf;
}

/// Free an unpacked message
pub fn free(msg: anytype) void {
    const ptr: *c.ProtobufCMessage = @ptrCast(@alignCast(@constCast(msg)));
    c.protobuf_c_message_free_unpacked(ptr, null);
}

/// Get the protobuf-c descriptor for a type
fn getDescriptor(comptime T: type) *const c.ProtobufCMessageDescriptor {
    return switch (T) {
        VersionRequest => &c.runtime__v1__version_request__descriptor,
        VersionResponse => &c.runtime__v1__version_response__descriptor,
        RunPodSandboxRequest => &c.runtime__v1__run_pod_sandbox_request__descriptor,
        RunPodSandboxResponse => &c.runtime__v1__run_pod_sandbox_response__descriptor,
        StopPodSandboxRequest => &c.runtime__v1__stop_pod_sandbox_request__descriptor,
        StopPodSandboxResponse => &c.runtime__v1__stop_pod_sandbox_response__descriptor,
        RemovePodSandboxRequest => &c.runtime__v1__remove_pod_sandbox_request__descriptor,
        RemovePodSandboxResponse => &c.runtime__v1__remove_pod_sandbox_response__descriptor,
        PodSandboxStatusRequest => &c.runtime__v1__pod_sandbox_status_request__descriptor,
        PodSandboxStatusResponse => &c.runtime__v1__pod_sandbox_status_response__descriptor,
        ListPodSandboxRequest => &c.runtime__v1__list_pod_sandbox_request__descriptor,
        ListPodSandboxResponse => &c.runtime__v1__list_pod_sandbox_response__descriptor,
        CreateContainerRequest => &c.runtime__v1__create_container_request__descriptor,
        CreateContainerResponse => &c.runtime__v1__create_container_response__descriptor,
        StartContainerRequest => &c.runtime__v1__start_container_request__descriptor,
        StartContainerResponse => &c.runtime__v1__start_container_response__descriptor,
        StopContainerRequest => &c.runtime__v1__stop_container_request__descriptor,
        StopContainerResponse => &c.runtime__v1__stop_container_response__descriptor,
        RemoveContainerRequest => &c.runtime__v1__remove_container_request__descriptor,
        RemoveContainerResponse => &c.runtime__v1__remove_container_response__descriptor,
        ContainerStatusRequest => &c.runtime__v1__container_status_request__descriptor,
        ContainerStatusResponse => &c.runtime__v1__container_status_response__descriptor,
        ListContainersRequest => &c.runtime__v1__list_containers_request__descriptor,
        ListContainersResponse => &c.runtime__v1__list_containers_response__descriptor,
        ExecSyncRequest => &c.runtime__v1__exec_sync_request__descriptor,
        ExecSyncResponse => &c.runtime__v1__exec_sync_response__descriptor,
        ExecRequest => &c.runtime__v1__exec_request__descriptor,
        ExecResponse => &c.runtime__v1__exec_response__descriptor,
        AttachRequest => &c.runtime__v1__attach_request__descriptor,
        AttachResponse => &c.runtime__v1__attach_response__descriptor,
        PortForwardRequest => &c.runtime__v1__port_forward_request__descriptor,
        PortForwardResponse => &c.runtime__v1__port_forward_response__descriptor,
        StatusRequest => &c.runtime__v1__status_request__descriptor,
        StatusResponse => &c.runtime__v1__status_response__descriptor,
        UpdateRuntimeConfigRequest => &c.runtime__v1__update_runtime_config_request__descriptor,
        UpdateRuntimeConfigResponse => &c.runtime__v1__update_runtime_config_response__descriptor,
        RuntimeConfigRequest => &c.runtime__v1__runtime_config_request__descriptor,
        RuntimeConfigResponse => &c.runtime__v1__runtime_config_response__descriptor,
        LinuxRuntimeConfiguration => &c.runtime__v1__linux_runtime_configuration__descriptor,
        ContainerStatsRequest => &c.runtime__v1__container_stats_request__descriptor,
        ContainerStatsResponse => &c.runtime__v1__container_stats_response__descriptor,
        ListContainerStatsRequest => &c.runtime__v1__list_container_stats_request__descriptor,
        ListContainerStatsResponse => &c.runtime__v1__list_container_stats_response__descriptor,
        PodSandboxStatsRequest => &c.runtime__v1__pod_sandbox_stats_request__descriptor,
        PodSandboxStatsResponse => &c.runtime__v1__pod_sandbox_stats_response__descriptor,
        ListPodSandboxStatsRequest => &c.runtime__v1__list_pod_sandbox_stats_request__descriptor,
        ListPodSandboxStatsResponse => &c.runtime__v1__list_pod_sandbox_stats_response__descriptor,
        ReopenContainerLogRequest => &c.runtime__v1__reopen_container_log_request__descriptor,
        ReopenContainerLogResponse => &c.runtime__v1__reopen_container_log_response__descriptor,
        ListImagesRequest => &c.runtime__v1__list_images_request__descriptor,
        ListImagesResponse => &c.runtime__v1__list_images_response__descriptor,
        ImageStatusRequest => &c.runtime__v1__image_status_request__descriptor,
        ImageStatusResponse => &c.runtime__v1__image_status_response__descriptor,
        PullImageRequest => &c.runtime__v1__pull_image_request__descriptor,
        PullImageResponse => &c.runtime__v1__pull_image_response__descriptor,
        RemoveImageRequest => &c.runtime__v1__remove_image_request__descriptor,
        RemoveImageResponse => &c.runtime__v1__remove_image_response__descriptor,
        ImageFsInfoRequest => &c.runtime__v1__image_fs_info_request__descriptor,
        ImageFsInfoResponse => &c.runtime__v1__image_fs_info_response__descriptor,
        else => @compileError("Unknown protobuf type"),
    };
}

/// Initialize a VersionResponse message
pub fn initVersionResponse(allocator: std.mem.Allocator, version: []const u8, runtime_name: []const u8, runtime_version: []const u8, runtime_api_version: []const u8) !*VersionResponse {
    const resp = try allocator.create(VersionResponse);
    resp.* = std.mem.zeroes(VersionResponse);
    resp.base.descriptor = &c.runtime__v1__version_response__descriptor;

    resp.version = try allocator.dupeZ(u8, version);
    resp.runtime_name = try allocator.dupeZ(u8, runtime_name);
    resp.runtime_version = try allocator.dupeZ(u8, runtime_version);
    resp.runtime_api_version = try allocator.dupeZ(u8, runtime_api_version);

    return resp;
}

/// Initialize a RunPodSandboxResponse message
pub fn initRunPodSandboxResponse(allocator: std.mem.Allocator, pod_sandbox_id: []const u8) !*RunPodSandboxResponse {
    const resp = try allocator.create(RunPodSandboxResponse);
    resp.* = std.mem.zeroes(RunPodSandboxResponse);
    resp.base.descriptor = &c.runtime__v1__run_pod_sandbox_response__descriptor;
    resp.pod_sandbox_id = try allocator.dupeZ(u8, pod_sandbox_id);
    return resp;
}

/// Initialize empty response messages
pub fn initEmptyResponse(comptime T: type, allocator: std.mem.Allocator) !*T {
    const resp = try allocator.create(T);
    resp.* = std.mem.zeroes(T);
    resp.base.descriptor = getDescriptor(T);
    return resp;
}

/// Helper to get string from C pointer
pub fn getString(ptr: [*c]const u8) []const u8 {
    if (ptr == null) return "";
    return std.mem.sliceTo(ptr, 0);
}

/// Helper to create C string from slice
pub fn toCString(allocator: std.mem.Allocator, slice: []const u8) ![*c]u8 {
    return try allocator.dupeZ(u8, slice);
}
