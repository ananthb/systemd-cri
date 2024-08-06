package crisvc

import (
	"context"

	runtime "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type criService struct {
	runtimeClient runtime.RuntimeServiceClient
}

func (r *criService) RuntimeConfig(ctx context.Context, req *runtime.RuntimeConfigRequest) (*runtime.RuntimeConfigResponse, error) {
	return nil, nil
}

func (r *criService) Version(
	context.Context,
	*runtime.VersionRequest,
) (*runtime.VersionResponse, error) {
	return nil, nil
}

// RunPodSandbox creates and starts a pod-level sandbox. Runtimes must ensure
// the sandbox is in the ready state on success.
func (r *criService) RunPodSandbox(
	context.Context,
	*runtime.RunPodSandboxRequest,
) (*runtime.RunPodSandboxResponse, error) {
	return nil, nil
}

// StopPodSandbox stops any running process that is part of the sandbox and
// reclaims network resources (e.g., IP addresses) allocated to the sandbox.
// If there are any running containers in the sandbox, they must be forcibly
// terminated.
// This call is idempotent, and must not return an error if all relevant
// resources have already been reclaimed. kubelet will call StopPodSandbox
// at least once before calling RemovePodSandbox. It will also attempt to
// reclaim resources eagerly, as soon as a sandbox is not needed. Hence,
// multiple StopPodSandbox calls are expected.
func (r *criService) StopPodSandbox(
	context.Context,
	*runtime.StopPodSandboxRequest,
) (*runtime.StopPodSandboxResponse, error) {
	return nil, nil
}

// RemovePodSandbox removes the sandbox. If there are any running containers
// in the sandbox, they must be forcibly terminated and removed.
// This call is idempotent, and must not return an error if the sandbox has
// already been removed.
func (r *criService) RemovePodSandbox(
	context.Context,
	*runtime.RemovePodSandboxRequest,
) (*runtime.RemovePodSandboxResponse, error) {
	return nil, nil
}

// PodSandboxStatus  the status of the PodSandbox. If the PodSandbox is not
// present,  an error.
func (r *criService) PodSandboxStatus(
	context.Context,
	*runtime.PodSandboxStatusRequest,
) (*runtime.PodSandboxStatusResponse, error) {
	return nil, nil
}

// ListPodSandbox  a list of PodSandboxes.
func (r *criService) ListPodSandbox(
	context.Context,
	*runtime.ListPodSandboxRequest,
) (*runtime.ListPodSandboxResponse, error) {
	return nil, nil
}

// CreateContainer creates a new container in specified PodSandbox
func (r *criService) CreateContainer(
	context.Context,
	*runtime.CreateContainerRequest,
) (*runtime.CreateContainerResponse, error) {
	return nil, nil
}

// StartContainer starts the container.
func (r *criService) StartContainer(
	context.Context,
	*runtime.StartContainerRequest,
) (*runtime.StartContainerResponse, error) {
	return nil, nil
}

// StopContainer stops a running container with a grace period (i.e., timeout).
// This call is idempotent, and must not return an error if the container has
// already been stopped.
// The runtime must forcibly kill the container after the grace period is
// reached.
func (r *criService) StopContainer(
	context.Context,
	*runtime.StopContainerRequest,
) (*runtime.StopContainerResponse, error) {
	return nil, nil
}

// RemoveContainer removes the container. If the container is running, the
// container must be forcibly removed.
// This call is idempotent, and must not return an error if the container has
// already been removed.
func (r *criService) RemoveContainer(
	context.Context,
	*runtime.RemoveContainerRequest,
) (*runtime.RemoveContainerResponse, error) {
	return nil, nil
}

// ListContainers lists all containers by filters.
func (r *criService) ListContainers(
	context.Context,
	*runtime.ListContainersRequest,
) (*runtime.ListContainersResponse, error) {
	return nil, nil
}

// ContainerStatus  status of the container. If the container is not
// present,  an error.
func (r *criService) ContainerStatus(
	context.Context,
	*runtime.ContainerStatusRequest,
) (*runtime.ContainerStatusResponse, error) {
	return nil, nil
}

// UpdateContainerResources updates ContainerConfig of the container synchronously.
// If runtime fails to transactionally update the requested resources, an error is returned.
func (r *criService) UpdateContainerResources(context.Context,
	*runtime.UpdateContainerResourcesRequest,
) (*runtime.UpdateContainerResourcesResponse, error) {
	return nil, nil
}

// ReopenContainerLog asks runtime to reopen the stdout/stderr log file
// for the container. This is often called after the log file has been
// rotated. If the container is not running, container runtime can choose
// to either create a new log file and return nil, or return an error.
// Once it  error, new container log file MUST NOT be created.
func (r *criService) ReopenContainerLog(
	context.Context,
	*runtime.ReopenContainerLogRequest,
) (*runtime.ReopenContainerLogResponse, error) {
	return nil, nil
}

// ExecSync runs a command in a container synchronously.
func (r *criService) ExecSync(
	context.Context,
	*runtime.ExecSyncRequest,
) (*runtime.ExecSyncResponse, error) {
	return nil, nil
}

// Exec prepares a streaming endpoint to execute a command in the container.
func (r *criService) Exec(
	context.Context,
	*runtime.ExecRequest,
) (*runtime.ExecResponse, error) {
	return nil, nil
}

// Attach prepares a streaming endpoint to attach to a running container.
func (r *criService) Attach(
	context.Context,
	*runtime.AttachRequest,
) (*runtime.AttachResponse, error) {
	return nil, nil
}

// PortForward prepares a streaming endpoint to forward ports from a PodSandbox.
func (r *criService) PortForward(
	context.Context,
	*runtime.PortForwardRequest,
) (*runtime.PortForwardResponse, error) {
	return nil, nil
}

// ContainerStats  stats of the container. If the container does not
// exist, the call  an error.
func (r *criService) ContainerStats(
	context.Context,
	*runtime.ContainerStatsRequest,
) (*runtime.ContainerStatsResponse, error) {
	return nil, nil
}

// ListContainerStats  stats of all running containers.
func (r *criService) ListContainerStats(
	context.Context,
	*runtime.ListContainerStatsRequest,
) (*runtime.ListContainerStatsResponse, error) {
	return nil, nil
}

// PodSandboxStats  stats of the pod sandbox. If the pod sandbox does not
// exist, the call  an error.
func (r *criService) PodSandboxStats(
	context.Context,
	*runtime.PodSandboxStatsRequest,
) (*runtime.PodSandboxStatsResponse, error) {
	return nil, nil
}

// ListPodSandboxStats  stats of the pod sandboxes matching a filter.
func (r *criService) ListPodSandboxStats(
	context.Context,
	*runtime.ListPodSandboxStatsRequest,
) (*runtime.ListPodSandboxStatsResponse, error) {
	return nil, nil
}

// UpdateRuntimeConfig updates the runtime configuration based on the given request.
func (r *criService) UpdateRuntimeConfig(
	context.Context,
	*runtime.UpdateRuntimeConfigRequest,
) (*runtime.UpdateRuntimeConfigResponse, error) {
	return nil, nil
}

// Status  the status of the runtime.
func (r *criService) Status(
	context.Context,
	*runtime.StatusRequest,
) (*runtime.StatusResponse, error) {
	return nil, nil
}

// CheckpointContainer checkpoints a container
func (r *criService) CheckpointContainer(
	context.Context,
	*runtime.CheckpointContainerRequest,
) (*runtime.CheckpointContainerResponse, error) {
	return nil, nil
}

// GetContainerEvents gets container events from the CRI runtime
func (r *criService) GetContainerEvents(
	*runtime.GetEventsRequest,
	runtime.RuntimeService_GetContainerEventsServer,
) error {
	return nil
}

// ListMetricDescriptors gets the descriptors for the metrics that will be returned in ListPodSandboxMetrics.
// This list should be static at startup: either the client and server restart together when
// adding or removing metrics descriptors, or they should not change.
// Put differently, if ListPodSandboxMetrics references a name that is not described in the initial
// ListMetricDescriptors call, then the metric will not be broadcasted.
func (r *criService) ListMetricDescriptors(
	context.Context,
	*runtime.ListMetricDescriptorsRequest,
) (*runtime.ListMetricDescriptorsResponse, error) {
	return nil, nil
}

// ListPodSandboxMetrics gets pod sandbox metrics from CRI Runtime
func (r *criService) ListPodSandboxMetrics(
	context.Context,
	*runtime.ListPodSandboxMetricsRequest,
) (*runtime.ListPodSandboxMetricsResponse, error) {
	return nil, nil
}
