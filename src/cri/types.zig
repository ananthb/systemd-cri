const std = @import("std");

/// CRI API version
pub const CRI_VERSION = "v1";
pub const RUNTIME_NAME = "systemd-cri";
pub const RUNTIME_VERSION = "0.1.0";

// ============================================================================
// Common Types
// ============================================================================

pub const Protocol = enum(i32) {
    tcp = 0,
    udp = 1,
    sctp = 2,
};

pub const MountPropagation = enum(i32) {
    propagation_private = 0,
    propagation_host_to_container = 1,
    propagation_bidirectional = 2,
};

pub const NamespaceMode = enum(i32) {
    pod = 0,
    container = 1,
    node = 2,
    target = 3,
};

// ============================================================================
// Pod Sandbox Types
// ============================================================================

pub const PodSandboxState = enum(i32) {
    sandbox_ready = 0,
    sandbox_notready = 1,
};

pub const PodSandboxMetadata = struct {
    name: []const u8,
    uid: []const u8,
    namespace: []const u8,
    attempt: u32 = 0,
};

pub const PodSandboxConfig = struct {
    metadata: PodSandboxMetadata,
    hostname: ?[]const u8 = null,
    log_directory: ?[]const u8 = null,
    dns_config: ?DNSConfig = null,
    port_mappings: ?[]const PortMapping = null,
    labels: ?std.StringHashMap([]const u8) = null,
    annotations: ?std.StringHashMap([]const u8) = null,
    linux: ?LinuxPodSandboxConfig = null,
    windows: ?WindowsPodSandboxConfig = null,
};

pub const DNSConfig = struct {
    servers: []const []const u8 = &.{},
    searches: []const []const u8 = &.{},
    options: []const []const u8 = &.{},
};

pub const PortMapping = struct {
    protocol: Protocol = .tcp,
    container_port: i32,
    host_port: i32,
    host_ip: ?[]const u8 = null,
};

pub const LinuxPodSandboxConfig = struct {
    cgroup_parent: ?[]const u8 = null,
    security_context: ?LinuxSandboxSecurityContext = null,
    sysctls: ?std.StringHashMap([]const u8) = null,
    overhead: ?LinuxContainerResources = null,
    resources: ?LinuxContainerResources = null,
};

pub const LinuxSandboxSecurityContext = struct {
    namespace_options: ?NamespaceOption = null,
    selinux_options: ?SELinuxOption = null,
    run_as_user: ?Int64Value = null,
    run_as_group: ?Int64Value = null,
    readonly_rootfs: bool = false,
    supplemental_groups: []const i64 = &.{},
    privileged: bool = false,
    seccomp: ?SecurityProfile = null,
    apparmor: ?SecurityProfile = null,
};

pub const NamespaceOption = struct {
    network: NamespaceMode = .pod,
    pid: NamespaceMode = .pod,
    ipc: NamespaceMode = .pod,
    target_id: ?[]const u8 = null,
    user_nsOptions: ?UserNamespace = null,
};

pub const UserNamespace = struct {
    mode: NamespaceMode = .pod,
    uids: []const IDMapping = &.{},
    gids: []const IDMapping = &.{},
};

pub const IDMapping = struct {
    host_id: u32,
    container_id: u32,
    length: u32,
};

pub const SELinuxOption = struct {
    user: ?[]const u8 = null,
    role: ?[]const u8 = null,
    type: ?[]const u8 = null,
    level: ?[]const u8 = null,
};

pub const SecurityProfile = struct {
    profile_type: ProfileType,
    localhost_ref: ?[]const u8 = null,
};

pub const ProfileType = enum(i32) {
    runtime_default = 0,
    unconfined = 1,
    localhost = 2,
};

pub const WindowsPodSandboxConfig = struct {
    // Placeholder for Windows support
};

pub const Int64Value = struct {
    value: i64,
};

// ============================================================================
// Container Types
// ============================================================================

pub const ContainerState = enum(i32) {
    container_created = 0,
    container_running = 1,
    container_exited = 2,
    container_unknown = 3,
};

pub const ContainerMetadata = struct {
    name: []const u8,
    attempt: u32 = 0,
};

pub const ContainerConfig = struct {
    metadata: ContainerMetadata,
    image: ImageSpec,
    command: []const []const u8 = &.{},
    args: []const []const u8 = &.{},
    working_dir: ?[]const u8 = null,
    envs: []const KeyValue = &.{},
    mounts: []const Mount = &.{},
    devices: []const Device = &.{},
    labels: ?std.StringHashMap([]const u8) = null,
    annotations: ?std.StringHashMap([]const u8) = null,
    log_path: ?[]const u8 = null,
    stdin: bool = false,
    stdin_once: bool = false,
    tty: bool = false,
    linux: ?LinuxContainerConfig = null,
    windows: ?WindowsContainerConfig = null,
};

pub const ImageSpec = struct {
    image: []const u8,
    annotations: ?std.StringHashMap([]const u8) = null,
    user_specified_image: ?[]const u8 = null,
    runtime_handler: ?[]const u8 = null,
};

pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

pub const Mount = struct {
    container_path: []const u8,
    host_path: []const u8,
    readonly: bool = false,
    selinux_relabel: bool = false,
    propagation: MountPropagation = .propagation_private,
    uidMappings: []const IDMapping = &.{},
    gidMappings: []const IDMapping = &.{},
    recursive_read_only: bool = false,
};

pub const Device = struct {
    container_path: []const u8,
    host_path: []const u8,
    permissions: []const u8 = "mrw",
};

pub const LinuxContainerConfig = struct {
    resources: ?LinuxContainerResources = null,
    security_context: ?LinuxContainerSecurityContext = null,
};

pub const LinuxContainerResources = struct {
    cpu_period: i64 = 0,
    cpu_quota: i64 = 0,
    cpu_shares: i64 = 0,
    memory_limit_in_bytes: i64 = 0,
    oom_score_adj: i64 = 0,
    cpuset_cpus: ?[]const u8 = null,
    cpuset_mems: ?[]const u8 = null,
    hugepage_limits: []const HugepageLimit = &.{},
    unified: ?std.StringHashMap([]const u8) = null,
    memory_swap_limit_in_bytes: i64 = 0,
};

pub const HugepageLimit = struct {
    page_size: []const u8,
    limit: u64,
};

pub const LinuxContainerSecurityContext = struct {
    capabilities: ?Capability = null,
    privileged: bool = false,
    namespace_options: ?NamespaceOption = null,
    selinux_options: ?SELinuxOption = null,
    run_as_user: ?Int64Value = null,
    run_as_group: ?Int64Value = null,
    run_as_username: ?[]const u8 = null,
    readonly_rootfs: bool = false,
    supplemental_groups: []const i64 = &.{},
    apparmor_profile: ?[]const u8 = null,
    seccomp_profile_path: ?[]const u8 = null,
    no_new_privs: bool = false,
    masked_paths: []const []const u8 = &.{},
    readonly_paths: []const []const u8 = &.{},
    seccomp: ?SecurityProfile = null,
    apparmor: ?SecurityProfile = null,
};

pub const Capability = struct {
    add_capabilities: []const []const u8 = &.{},
    drop_capabilities: []const []const u8 = &.{},
    add_ambient_capabilities: []const []const u8 = &.{},
};

pub const WindowsContainerConfig = struct {
    // Placeholder for Windows support
};

// ============================================================================
// Image Types
// ============================================================================

pub const Image = struct {
    id: []const u8,
    repo_tags: []const []const u8 = &.{},
    repo_digests: []const []const u8 = &.{},
    size: u64 = 0,
    uid: ?Int64Value = null,
    username: ?[]const u8 = null,
    spec: ?ImageSpec = null,
    pinned: bool = false,
};

pub const AuthConfig = struct {
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    auth: ?[]const u8 = null,
    server_address: ?[]const u8 = null,
    identity_token: ?[]const u8 = null,
    registry_token: ?[]const u8 = null,
};

// ============================================================================
// Runtime Status Types
// ============================================================================

pub const RuntimeCondition = struct {
    type: []const u8,
    status: bool,
    reason: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub const RuntimeStatus = struct {
    conditions: []const RuntimeCondition = &.{},
};

pub const RuntimeHandlerFeatures = struct {
    recursive_read_only_mounts: bool = false,
    user_namespaces: bool = false,
};

pub const RuntimeHandler = struct {
    name: []const u8,
    features: ?RuntimeHandlerFeatures = null,
};

// ============================================================================
// Exec/Attach Types
// ============================================================================

pub const ExecRequest = struct {
    container_id: []const u8,
    cmd: []const []const u8,
    tty: bool = false,
    stdin: bool = false,
    stdout: bool = true,
    stderr: bool = true,
};

pub const ExecResponse = struct {
    url: []const u8,
};

pub const ExecSyncRequest = struct {
    container_id: []const u8,
    cmd: []const []const u8,
    timeout: i64 = 0,
};

pub const ExecSyncResponse = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32,
};

pub const AttachRequest = struct {
    container_id: []const u8,
    stdin: bool = false,
    tty: bool = false,
    stdout: bool = true,
    stderr: bool = true,
};

pub const AttachResponse = struct {
    url: []const u8,
};

// ============================================================================
// Log Types
// ============================================================================

pub const ContainerLogPath = struct {
    container_id: []const u8,
    path: []const u8,
};

// ============================================================================
// Stats Types
// ============================================================================

pub const ContainerStats = struct {
    attributes: ?ContainerAttributes = null,
    cpu: ?CpuUsage = null,
    memory: ?MemoryUsage = null,
    writable_layer: ?FilesystemUsage = null,
};

pub const ContainerAttributes = struct {
    id: []const u8,
    metadata: ContainerMetadata,
    labels: ?std.StringHashMap([]const u8) = null,
    annotations: ?std.StringHashMap([]const u8) = null,
};

pub const CpuUsage = struct {
    timestamp: i64 = 0,
    usage_core_nano_seconds: ?UInt64Value = null,
    usage_nano_cores: ?UInt64Value = null,
};

pub const MemoryUsage = struct {
    timestamp: i64 = 0,
    working_set_bytes: ?UInt64Value = null,
    available_bytes: ?UInt64Value = null,
    usage_bytes: ?UInt64Value = null,
    rss_bytes: ?UInt64Value = null,
    page_faults: ?UInt64Value = null,
    major_page_faults: ?UInt64Value = null,
};

pub const FilesystemUsage = struct {
    timestamp: i64 = 0,
    fs_id: ?FilesystemIdentifier = null,
    used_bytes: ?UInt64Value = null,
    inodes_used: ?UInt64Value = null,
};

pub const FilesystemIdentifier = struct {
    mountpoint: []const u8,
};

pub const UInt64Value = struct {
    value: u64,
};

pub const PodSandboxStats = struct {
    attributes: ?PodSandboxAttributes = null,
    linux: ?LinuxPodSandboxStats = null,
    windows: ?WindowsPodSandboxStats = null,
};

pub const PodSandboxAttributes = struct {
    id: []const u8,
    metadata: PodSandboxMetadata,
    labels: ?std.StringHashMap([]const u8) = null,
    annotations: ?std.StringHashMap([]const u8) = null,
};

pub const LinuxPodSandboxStats = struct {
    cpu: ?CpuUsage = null,
    memory: ?MemoryUsage = null,
    network: ?NetworkUsage = null,
    process: ?ProcessUsage = null,
    containers: []const ContainerStats = &.{},
};

pub const NetworkUsage = struct {
    timestamp: i64 = 0,
    default_interface: ?NetworkInterfaceUsage = null,
    interfaces: []const NetworkInterfaceUsage = &.{},
};

pub const NetworkInterfaceUsage = struct {
    name: []const u8,
    rx_bytes: ?UInt64Value = null,
    rx_errors: ?UInt64Value = null,
    tx_bytes: ?UInt64Value = null,
    tx_errors: ?UInt64Value = null,
};

pub const ProcessUsage = struct {
    timestamp: i64 = 0,
    process_count: ?UInt64Value = null,
};

pub const WindowsPodSandboxStats = struct {
    // Placeholder
};
