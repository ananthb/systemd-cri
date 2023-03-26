package machineman

import (
	"context"

	runtimeapi "k8s.io/cri-api/pkg/apis/runtime/v1"
)

func NewRuntimeService() (runtimeapi.RuntimeServiceServer, error) {
	return &RuntimeService{}, nil
}

type RuntimeService struct {
	runtimeClient runtimeapi.RuntimeServiceClient
}

func (r *RuntimeService) Version(
	context.Context,
	*runtimeapi.VersionRequest,
) (*runtimeapi.VersionResponse, error) {
	return nil, nil
}

// RunPodSandbox creates and starts a pod-level sandbox. Runtimes must ensure
// the sandbox is in the ready state on success.
func (r *RuntimeService) RunPodSandbox(
	context.Context,
	*runtimeapi.RunPodSandboxRequest,
) (*runtimeapi.RunPodSandboxResponse, error) {
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
func (r *RuntimeService) StopPodSandbox(
	context.Context,
	*runtimeapi.StopPodSandboxRequest,
) (*runtimeapi.StopPodSandboxResponse, error) {
	return nil, nil
}

// RemovePodSandbox removes the sandbox. If there are any running containers
// in the sandbox, they must be forcibly terminated and removed.
// This call is idempotent, and must not return an error if the sandbox has
// already been removed.
func (r *RuntimeService) RemovePodSandbox(
	context.Context,
	*runtimeapi.RemovePodSandboxRequest,
) (*runtimeapi.RemovePodSandboxResponse, error) {
	return nil, nil
}

// PodSandboxStatus  the status of the PodSandbox. If the PodSandbox is not
// present,  an error.
func (r *RuntimeService) PodSandboxStatus(
	context.Context,
	*runtimeapi.PodSandboxStatusRequest,
) (*runtimeapi.PodSandboxStatusResponse, error) {
	return nil, nil
}

// ListPodSandbox  a list of PodSandboxes.
func (r *RuntimeService) ListPodSandbox(
	context.Context,
	*runtimeapi.ListPodSandboxRequest,
) (*runtimeapi.ListPodSandboxResponse, error) {
	return nil, nil
}

// CreateContainer creates a new container in specified PodSandbox
func (r *RuntimeService) CreateContainer(
	context.Context,
	*runtimeapi.CreateContainerRequest,
) (*runtimeapi.CreateContainerResponse, error) {
	return nil, nil
}

// StartContainer starts the container.
func (r *RuntimeService) StartContainer(
	context.Context,
	*runtimeapi.StartContainerRequest,
) (*runtimeapi.StartContainerResponse, error) {
	return nil, nil
}

// StopContainer stops a running container with a grace period (i.e., timeout).
// This call is idempotent, and must not return an error if the container has
// already been stopped.
// The runtime must forcibly kill the container after the grace period is
// reached.
func (r *RuntimeService) StopContainer(
	context.Context,
	*runtimeapi.StopContainerRequest,
) (*runtimeapi.StopContainerResponse, error) {
	return nil, nil
}

// RemoveContainer removes the container. If the container is running, the
// container must be forcibly removed.
// This call is idempotent, and must not return an error if the container has
// already been removed.
func (r *RuntimeService) RemoveContainer(
	context.Context,
	*runtimeapi.RemoveContainerRequest,
) (*runtimeapi.RemoveContainerResponse, error) {
	return nil, nil
}

// ListContainers lists all containers by filters.
func (r *RuntimeService) ListContainers(
	context.Context,
	*runtimeapi.ListContainersRequest,
) (*runtimeapi.ListContainersResponse, error) {
	return nil, nil
}

// ContainerStatus  status of the container. If the container is not
// present,  an error.
func (r *RuntimeService) ContainerStatus(
	context.Context,
	*runtimeapi.ContainerStatusRequest,
) (*runtimeapi.ContainerStatusResponse, error) {
	return nil, nil
}

// UpdateContainerResources updates ContainerConfig of the container synchronously.
// If runtime fails to transactionally update the requested resources, an error is returned.
func (r *RuntimeService) UpdateContainerResources(context.Context,
	*runtimeapi.UpdateContainerResourcesRequest,
) (*runtimeapi.UpdateContainerResourcesResponse, error) {
	return nil, nil
}

// ReopenContainerLog asks runtime to reopen the stdout/stderr log file
// for the container. This is often called after the log file has been
// rotated. If the container is not running, container runtime can choose
// to either create a new log file and return nil, or return an error.
// Once it  error, new container log file MUST NOT be created.
func (r *RuntimeService) ReopenContainerLog(
	context.Context,
	*runtimeapi.ReopenContainerLogRequest,
) (*runtimeapi.ReopenContainerLogResponse, error) {
	return nil, nil
}

// ExecSync runs a command in a container synchronously.
func (r *RuntimeService) ExecSync(
	context.Context,
	*runtimeapi.ExecSyncRequest,
) (*runtimeapi.ExecSyncResponse, error) {
	return nil, nil
}

// Exec prepares a streaming endpoint to execute a command in the container.
func (r *RuntimeService) Exec(context.Context, *runtimeapi.ExecRequest) (*runtimeapi.ExecResponse, error) {
	return nil, nil
}

// Attach prepares a streaming endpoint to attach to a running container.
func (r *RuntimeService) Attach(
	context.Context,
	*runtimeapi.AttachRequest,
) (*runtimeapi.AttachResponse, error) {
	return nil, nil
}

// PortForward prepares a streaming endpoint to forward ports from a PodSandbox.
func (r *RuntimeService) PortForward(
	context.Context,
	*runtimeapi.PortForwardRequest,
) (*runtimeapi.PortForwardResponse, error) {
	return nil, nil
}

// ContainerStats  stats of the container. If the container does not
// exist, the call  an error.
func (r *RuntimeService) ContainerStats(
	context.Context,
	*runtimeapi.ContainerStatsRequest,
) (*runtimeapi.ContainerStatsResponse, error) {
	return nil, nil
}

// ListContainerStats  stats of all running containers.
func (r *RuntimeService) ListContainerStats(
	context.Context,
	*runtimeapi.ListContainerStatsRequest,
) (*runtimeapi.ListContainerStatsResponse, error) {
	return nil, nil
}

// PodSandboxStats  stats of the pod sandbox. If the pod sandbox does not
// exist, the call  an error.
func (r *RuntimeService) PodSandboxStats(
	context.Context,
	*runtimeapi.PodSandboxStatsRequest,
) (*runtimeapi.PodSandboxStatsResponse, error) {
	return nil, nil
}

// ListPodSandboxStats  stats of the pod sandboxes matching a filter.
func (r *RuntimeService) ListPodSandboxStats(
	context.Context,
	*runtimeapi.ListPodSandboxStatsRequest,
) (*runtimeapi.ListPodSandboxStatsResponse, error) {
	return nil, nil
}

// UpdateRuntimeConfig updates the runtime configuration based on the given request.
func (r *RuntimeService) UpdateRuntimeConfig(
	context.Context,
	*runtimeapi.UpdateRuntimeConfigRequest,
) (*runtimeapi.UpdateRuntimeConfigResponse, error) {
	return nil, nil
}

// Status  the status of the runtime.
func (r *RuntimeService) Status(
	context.Context,
	*runtimeapi.StatusRequest,
) (*runtimeapi.StatusResponse, error) {
	return nil, nil
}

// CheckpointContainer checkpoints a container
func (r *RuntimeService) CheckpointContainer(
	context.Context,
	*runtimeapi.CheckpointContainerRequest,
) (*runtimeapi.CheckpointContainerResponse, error) {
	return nil, nil
}

// GetContainerEvents gets container events from the CRI runtime
func (r *RuntimeService) GetContainerEvents(
	*runtimeapi.GetEventsRequest,
	runtimeapi.RuntimeService_GetContainerEventsServer,
) error {
	return nil
}

// ListMetricDescriptors gets the descriptors for the metrics that will be returned in ListPodSandboxMetrics.
// This list should be static at startup: either the client and server restart together when
// adding or removing metrics descriptors, or they should not change.
// Put differently, if ListPodSandboxMetrics references a name that is not described in the initial
// ListMetricDescriptors call, then the metric will not be broadcasted.
func (r *RuntimeService) ListMetricDescriptors(
	context.Context,
	*runtimeapi.ListMetricDescriptorsRequest,
) (*runtimeapi.ListMetricDescriptorsResponse, error) {
	return nil, nil
}

// ListPodSandboxMetrics gets pod sandbox metrics from CRI Runtime
func (r *RuntimeService) ListPodSandboxMetrics(context.Context, *runtimeapi.ListPodSandboxMetricsRequest,
) (*runtimeapi.ListPodSandboxMetricsResponse, error) {
	return nil, nil
}
