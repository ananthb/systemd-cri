package cri

import (
	"context"
	"fmt"
	"time"

	"k8s.io/apimachinery/pkg/util/uuid"
	"k8s.io/cri-api/pkg/apis/runtime/v1"

	"systemd-cri/internal/store"
	"systemd-cri/internal/systemd"
)

type RuntimeServer struct {
	v1.UnimplementedRuntimeServiceServer
	store   *store.Store
	systemd *systemd.Manager
	stateDir string
}

func NewRuntimeServer(store *store.Store, manager *systemd.Manager, stateDir string) *RuntimeServer {
	return &RuntimeServer{store: store, systemd: manager, stateDir: stateDir}
}

func (s *RuntimeServer) Version(ctx context.Context, req *v1.VersionRequest) (*v1.VersionResponse, error) {
	return &v1.VersionResponse{
		Version:           req.Version,
		RuntimeName:       "systemd-cri-go",
		RuntimeVersion:    "0.2.0",
		RuntimeApiVersion: "v1",
	}, nil
}

func (s *RuntimeServer) Status(ctx context.Context, _ *v1.StatusRequest) (*v1.StatusResponse, error) {
	return &v1.StatusResponse{
		Status: &v1.RuntimeStatus{
			Conditions: []*v1.RuntimeCondition{
				{
					Type:   v1.RuntimeReady,
					Status: true,
					Reason: "Ready",
					Message: "systemd-cri-go is ready",
				},
				{
					Type:   v1.NetworkReady,
					Status: true,
					Reason: "Ready",
					Message: "networking not yet implemented",
				},
			},
		},
	}, nil
}

func (s *RuntimeServer) RunPodSandbox(ctx context.Context, req *v1.RunPodSandboxRequest) (*v1.RunPodSandboxResponse, error) {
	if req == nil || req.Config == nil || req.Config.Metadata == nil {
		return nil, fmt.Errorf("missing pod sandbox config")
	}
	id := string(uuid.NewUUID())
	unitName := fmt.Sprintf("cri-pod-%s.service", id)

	ctx, cancel := systemd.DefaultContext()
	defer cancel()

	execPath := "/usr/bin/sleep"
	execArgs := []string{"infinity"}
	if err := s.systemd.StartTransientService(ctx, unitName, execPath, execArgs);
		err != nil {
		return nil, err
	}

	pod := &store.Pod{
		ID:          id,
		Name:        req.Config.Metadata.Name,
		Namespace:   req.Config.Metadata.Namespace,
		UID:         req.Config.Metadata.Uid,
		CreatedAt:   time.Now().UTC(),
		State:       store.PodStateReady,
		Labels:      req.Config.Labels,
		Annotations: req.Config.Annotations,
		Hostname:    req.Config.Hostname,
		UnitName:    unitName,
	}
	if err := s.store.PutPod(pod); err != nil {
		return nil, err
	}

	return &v1.RunPodSandboxResponse{PodSandboxId: id}, nil
}

func (s *RuntimeServer) StopPodSandbox(ctx context.Context, req *v1.StopPodSandboxRequest) (*v1.StopPodSandboxResponse, error) {
	if req == nil || req.PodSandboxId == "" {
		return nil, fmt.Errorf("missing pod sandbox id")
	}
	pod, err := s.store.GetPod(req.PodSandboxId)
	if err != nil {
		if err == store.ErrNotFound {
			return &v1.StopPodSandboxResponse{}, nil
		}
		return nil, err
	}
	ctx, cancel := systemd.DefaultContext()
	defer cancel()
	_ = s.systemd.StopUnit(ctx, pod.UnitName)

	pod.State = store.PodStateNotReady
	_ = s.store.PutPod(pod)
	return &v1.StopPodSandboxResponse{}, nil
}

func (s *RuntimeServer) RemovePodSandbox(ctx context.Context, req *v1.RemovePodSandboxRequest) (*v1.RemovePodSandboxResponse, error) {
	if req == nil || req.PodSandboxId == "" {
		return nil, fmt.Errorf("missing pod sandbox id")
	}
	pod, err := s.store.GetPod(req.PodSandboxId)
	if err != nil {
		if err == store.ErrNotFound {
			return &v1.RemovePodSandboxResponse{}, nil
		}
		return nil, err
	}

	ctx, cancel := systemd.DefaultContext()
	defer cancel()
	_ = s.systemd.StopUnit(ctx, pod.UnitName)

	if err := s.store.DeletePod(req.PodSandboxId); err != nil && err != store.ErrNotFound {
		return nil, err
	}

	return &v1.RemovePodSandboxResponse{}, nil
}

func (s *RuntimeServer) PodSandboxStatus(ctx context.Context, req *v1.PodSandboxStatusRequest) (*v1.PodSandboxStatusResponse, error) {
	if req == nil || req.PodSandboxId == "" {
		return nil, fmt.Errorf("missing pod sandbox id")
	}
	pod, err := s.store.GetPod(req.PodSandboxId)
	if err != nil {
		return nil, err
	}
	state := v1.PodSandboxState_SANDBOX_READY
	if pod.State != store.PodStateReady {
		state = v1.PodSandboxState_SANDBOX_NOTREADY
	}
	status := &v1.PodSandboxStatus{
		Id: pod.ID,
		Metadata: &v1.PodSandboxMetadata{
			Name:      pod.Name,
			Uid:       pod.UID,
			Namespace: pod.Namespace,
			Attempt:   0,
		},
		State:     state,
		CreatedAt: pod.CreatedAt.UnixNano(),
		Labels:    pod.Labels,
		Annotations: pod.Annotations,
		Linux:     &v1.LinuxPodSandboxStatus{},
		Network:   &v1.PodSandboxNetworkStatus{},
	}

	return &v1.PodSandboxStatusResponse{Status: status}, nil
}

func (s *RuntimeServer) ListPodSandbox(ctx context.Context, req *v1.ListPodSandboxRequest) (*v1.ListPodSandboxResponse, error) {
	pods, err := s.store.ListPods()
	if err != nil {
		return nil, err
	}
	items := make([]*v1.PodSandbox, 0, len(pods))
	for _, pod := range pods {
		state := v1.PodSandboxState_SANDBOX_READY
		if pod.State != store.PodStateReady {
			state = v1.PodSandboxState_SANDBOX_NOTREADY
		}
		items = append(items, &v1.PodSandbox{
			Id: pod.ID,
			Metadata: &v1.PodSandboxMetadata{
				Name:      pod.Name,
				Uid:       pod.UID,
				Namespace: pod.Namespace,
				Attempt:   0,
			},
			State:     state,
			CreatedAt: pod.CreatedAt.UnixNano(),
			Labels:    pod.Labels,
			Annotations: pod.Annotations,
		},
		)
	}
	return &v1.ListPodSandboxResponse{Items: items}, nil
}

func (s *RuntimeServer) UpdateRuntimeConfig(ctx context.Context, req *v1.UpdateRuntimeConfigRequest) (*v1.UpdateRuntimeConfigResponse, error) {
	return &v1.UpdateRuntimeConfigResponse{}, nil
}

func (s *RuntimeServer) RuntimeConfig(ctx context.Context, req *v1.RuntimeConfigRequest) (*v1.RuntimeConfigResponse, error) {
	return &v1.RuntimeConfigResponse{Linux: &v1.LinuxRuntimeConfiguration{}}, nil
}

func (s *RuntimeServer) ReopenContainerLog(ctx context.Context, req *v1.ReopenContainerLogRequest) (*v1.ReopenContainerLogResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *RuntimeServer) CheckpointContainer(ctx context.Context, req *v1.CheckpointContainerRequest) (*v1.CheckpointContainerResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *RuntimeServer) ListContainerStats(ctx context.Context, req *v1.ListContainerStatsRequest) (*v1.ListContainerStatsResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *RuntimeServer) ListPodSandboxStats(ctx context.Context, req *v1.ListPodSandboxStatsRequest) (*v1.ListPodSandboxStatsResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *RuntimeServer) PortForward(ctx context.Context, req *v1.PortForwardRequest) (*v1.PortForwardResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *RuntimeServer) Exec(ctx context.Context, req *v1.ExecRequest) (*v1.ExecResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *RuntimeServer) Attach(ctx context.Context, req *v1.AttachRequest) (*v1.AttachResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *RuntimeServer) ExecSync(ctx context.Context, req *v1.ExecSyncRequest) (*v1.ExecSyncResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *RuntimeServer) CreateContainer(ctx context.Context, req *v1.CreateContainerRequest) (*v1.CreateContainerResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *RuntimeServer) StartContainer(ctx context.Context, req *v1.StartContainerRequest) (*v1.StartContainerResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *RuntimeServer) StopContainer(ctx context.Context, req *v1.StopContainerRequest) (*v1.StopContainerResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *RuntimeServer) RemoveContainer(ctx context.Context, req *v1.RemoveContainerRequest) (*v1.RemoveContainerResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *RuntimeServer) ListContainers(ctx context.Context, req *v1.ListContainersRequest) (*v1.ListContainersResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *RuntimeServer) ContainerStatus(ctx context.Context, req *v1.ContainerStatusRequest) (*v1.ContainerStatusResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *RuntimeServer) UpdateContainerResources(ctx context.Context, req *v1.UpdateContainerResourcesRequest) (*v1.UpdateContainerResourcesResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *RuntimeServer) ListImages(ctx context.Context, req *v1.ListImagesRequest) (*v1.ListImagesResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *RuntimeServer) ImageStatus(ctx context.Context, req *v1.ImageStatusRequest) (*v1.ImageStatusResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *RuntimeServer) PullImage(ctx context.Context, req *v1.PullImageRequest) (*v1.PullImageResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *RuntimeServer) RemoveImage(ctx context.Context, req *v1.RemoveImageRequest) (*v1.RemoveImageResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *RuntimeServer) ImageFsInfo(ctx context.Context, req *v1.ImageFsInfoRequest) (*v1.ImageFsInfoResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *RuntimeServer) ListMetrics(ctx context.Context, req *v1.ListMetricsRequest) (*v1.ListMetricsResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *RuntimeServer) ListPodSandboxMetrics(ctx context.Context, req *v1.ListPodSandboxMetricsRequest) (*v1.ListPodSandboxMetricsResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *RuntimeServer) CheckpointContainerStatus(ctx context.Context, req *v1.CheckpointContainerStatusRequest) (*v1.CheckpointContainerStatusResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *RuntimeServer) PodSandboxStats(ctx context.Context, req *v1.PodSandboxStatsRequest) (*v1.PodSandboxStatsResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *RuntimeServer) ContainerStats(ctx context.Context, req *v1.ContainerStatsRequest) (*v1.ContainerStatsResponse, error) {
	return nil, fmt.Errorf("not implemented")
}
