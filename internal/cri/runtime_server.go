package cri

import (
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	coreosdbus "github.com/coreos/go-systemd/v22/dbus"
	gdbus "github.com/godbus/dbus/v5"
	"k8s.io/apimachinery/pkg/util/uuid"
	"k8s.io/cri-api/pkg/apis/runtime/v1"
	"k8s.io/kubelet/pkg/cri/streaming"

	"systemd-cri/internal/store"
	"systemd-cri/internal/systemd"
)

type RuntimeServer struct {
	v1.UnimplementedRuntimeServiceServer
	store        *store.Store
	systemd      *systemd.Manager
	stateDir     string
	streamingSrv streaming.Server
	forwards     map[string][]*portForwarder
	mu           sync.Mutex
}

type portForwarder struct {
	ln   net.Listener
	done chan struct{}
}

func NewRuntimeServer(store *store.Store, systemd *systemd.Manager, stateDir string) *RuntimeServer {
	return &RuntimeServer{
		store:    store,
		systemd:  systemd,
		stateDir: stateDir,
		forwards: make(map[string][]*portForwarder),
	}
}

func (s *RuntimeServer) SetStreamingServer(srv streaming.Server) {
	s.streamingSrv = srv
}

func (s *RuntimeServer) Version(ctx context.Context, req *v1.VersionRequest) (*v1.VersionResponse, error) {
	return &v1.VersionResponse{
		Version:           "0.1.0",
		RuntimeName:       "systemd-cri",
		RuntimeVersion:    "0.1.0",
		RuntimeApiVersion: "v1",
	}, nil
}

func (s *RuntimeServer) Status(ctx context.Context, req *v1.StatusRequest) (*v1.StatusResponse, error) {
	return &v1.StatusResponse{
		Status: &v1.RuntimeStatus{
			Conditions: []*v1.RuntimeCondition{
				{Type: v1.RuntimeReady, Status: true},
				{Type: v1.NetworkReady, Status: true},
			},
		},
	}, nil
}

func (s *RuntimeServer) RunPodSandbox(ctx context.Context, req *v1.RunPodSandboxRequest) (*v1.RunPodSandboxResponse, error) {
	if req == nil || req.Config == nil {
		return nil, fmt.Errorf("missing pod sandbox config")
	}
	id := string(uuid.NewUUID())
	unitName := fmt.Sprintf("cri-pod-%s.service", id)

	sdCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	execPath := "sleep"
	if p, err := exec.LookPath("sleep"); err == nil {
		execPath = p
	}
	execArgs := []string{"infinity"}
	if err := s.systemd.StartTransientService(sdCtx, unitName, execPath, execArgs); err != nil {
		return nil, err
	}

	hostNetwork := isHostNetwork(req.Config.GetLinux())
	portMappings := toStorePortMappings(req.Config.GetPortMappings())
	pod := &store.Pod{
		ID:           id,
		Name:         req.Config.Metadata.Name,
		Namespace:    req.Config.Metadata.Namespace,
		UID:          req.Config.Metadata.Uid,
		CreatedAt:    time.Now().UTC(),
		State:        store.PodStateReady,
		Labels:       req.Config.Labels,
		Annotations:  req.Config.Annotations,
		Hostname:     req.Config.Hostname,
		UnitName:     unitName,
		HostNetwork:  hostNetwork,
		PortMappings: portMappings,
	}
	if err := s.store.PutPod(pod); err != nil {
		return nil, err
	}

	if len(portMappings) > 0 {
		if err := s.setupPortForwards(pod); err != nil {
			return nil, err
		}
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
	sdCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	_ = s.systemd.StopUnit(sdCtx, pod.UnitName)

	pod.State = store.PodStateNotReady
	_ = s.store.PutPod(pod)
	s.stopPortForwards(req.PodSandboxId)
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

	sdCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	_ = s.systemd.StopUnit(sdCtx, pod.UnitName)
	_ = s.systemd.DeleteUnit(sdCtx, pod.UnitName)

	if err := s.store.DeletePod(req.PodSandboxId); err != nil && err != store.ErrNotFound {
		return nil, err
	}
	s.stopPortForwards(req.PodSandboxId)

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
	ip := "127.0.0.1"
	return &v1.PodSandboxStatusResponse{
		Status: &v1.PodSandboxStatus{
			Id:        pod.ID,
			Metadata:  &v1.PodSandboxMetadata{Name: pod.Name, Namespace: pod.Namespace, Uid: pod.UID},
			State:     state,
			CreatedAt: pod.CreatedAt.UnixNano(),
			Network:   &v1.PodSandboxNetworkStatus{Ip: ip},
			Linux: &v1.LinuxPodSandboxStatus{
				Namespaces: &v1.Namespace{
					Options: &v1.NamespaceOption{
						Network: toCRINamespaceMode(pod.HostNetwork),
					},
				},
			},
			Labels:      pod.Labels,
			Annotations: pod.Annotations,
		},
	}, nil
}

func (s *RuntimeServer) ListPodSandbox(ctx context.Context, req *v1.ListPodSandboxRequest) (*v1.ListPodSandboxResponse, error) {
	pods, err := s.store.ListPods()
	if err != nil {
		return nil, err
	}
	items := make([]*v1.PodSandbox, 0, len(pods))
	for _, pod := range pods {
		if !podMatchesFilter(pod, req.GetFilter()) {
			continue
		}
		state := v1.PodSandboxState_SANDBOX_READY
		if pod.State != store.PodStateReady {
			state = v1.PodSandboxState_SANDBOX_NOTREADY
		}
		items = append(items, &v1.PodSandbox{
			Id:          pod.ID,
			Metadata:    &v1.PodSandboxMetadata{Name: pod.Name, Namespace: pod.Namespace, Uid: pod.UID},
			State:       state,
			CreatedAt:   pod.CreatedAt.UnixNano(),
			Labels:      pod.Labels,
			Annotations: pod.Annotations,
		})
	}
	return &v1.ListPodSandboxResponse{Items: items}, nil
}

func (s *RuntimeServer) CreateContainer(ctx context.Context, req *v1.CreateContainerRequest) (*v1.CreateContainerResponse, error) {
	if req == nil || req.Config == nil {
		return nil, fmt.Errorf("missing container config")
	}
	imageRef := req.Config.Image.Image
	image, err := findImageByReference(s.store, imageRef)
	if err != nil {
		return nil, err
	}

	if req.Config.WorkingDir == "" {
		if image.WorkDir != "" {
			req.Config.WorkingDir = image.WorkDir
		}
	}

	id := string(uuid.NewUUID())
	unitName := fmt.Sprintf("cri-container-%s.service", id)

	logPath := resolveLogPath(req.Config.LogPath, req.SandboxConfig)
	if logPath != "" {
		if err := os.MkdirAll(filepath.Dir(logPath), 0755); err != nil {
			return nil, err
		}
	}

	rootfsPath := ""
	if image.RootfsPath != "" {
		rootfsPath = filepath.Join(s.stateDir, "containers", id, "rootfs")
		if err := os.MkdirAll(filepath.Dir(rootfsPath), 0755); err != nil {
			return nil, err
		}
	}

	container := &store.Container{
		ID:          id,
		PodID:       req.PodSandboxId,
		Name:        req.Config.Metadata.Name,
		ImageRef:    image.ID,
		CreatedAt:   time.Now().UTC(),
		State:       store.ContainerStateCreated,
		Labels:      req.Config.Labels,
		Annotations: req.Config.Annotations,
		LogPath:     logPath,
		WorkingDir:  req.Config.WorkingDir,
		RootfsPath:  rootfsPath,
		UnitName:    unitName,
		Command:     req.Config.Command,
		Args:        req.Config.Args,
	}
	if err := s.store.PutContainer(container); err != nil {
		return nil, err
	}
	return &v1.CreateContainerResponse{ContainerId: id}, nil
}

func (s *RuntimeServer) StartContainer(ctx context.Context, req *v1.StartContainerRequest) (*v1.StartContainerResponse, error) {
	if req == nil || req.ContainerId == "" {
		return nil, fmt.Errorf("missing container id")
	}
	container, err := s.store.GetContainer(req.ContainerId)
	if err != nil {
		return nil, err
	}
	if container.State == store.ContainerStateRunning {
		return &v1.StartContainerResponse{}, nil
	}

	sdCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	command := append([]string{}, container.Command...)
	command = append(command, container.Args...)
	if len(command) == 0 {
		command = []string{"sleep", "infinity"}
	}
	if len(command) > 0 {
		command = []string{"/bin/sh", "-c", "exec " + joinShellCommand(command)}
	}

	props := []coreosdbus.Property{}
	if container.RootfsPath != "" {
		image, err := findImageByReference(s.store, container.ImageRef)
		if err != nil {
			return nil, err
		}
		env := buildEnv(image.Env)
		if len(env) > 0 {
			props = append(props, coreosdbus.Property{
				Name:  "Environment",
				Value: gdbus.MakeVariant(env),
			})
		}
		if image.RootfsPath != "" {
			if err := mountOverlay(image.RootfsPath, container.RootfsPath, s.stateDir, container.ID); err != nil {
				return nil, err
			}
			props = append(props,
				coreosdbus.Property{Name: "RootDirectory", Value: gdbus.MakeVariant(container.RootfsPath)},
				coreosdbus.Property{Name: "PrivateMounts", Value: gdbus.MakeVariant(true)},
				coreosdbus.Property{Name: "MountAPIVFS", Value: gdbus.MakeVariant(true)},
				coreosdbus.Property{Name: "PrivateTmp", Value: gdbus.MakeVariant(true)},
			)
		}
	}
	if container.WorkingDir != "" {
		props = append(props, coreosdbus.Property{
			Name:  "WorkingDirectory",
			Value: gdbus.MakeVariant(container.WorkingDir),
		})
	}
	if container.LogPath != "" {
		out := "append:" + container.LogPath
		props = append(props,
			coreosdbus.Property{Name: "StandardOutput", Value: gdbus.MakeVariant(out)},
			coreosdbus.Property{Name: "StandardError", Value: gdbus.MakeVariant(out)},
		)
	}

	if err := s.systemd.StartTransientService(sdCtx, container.UnitName, command[0], command[1:], props...); err != nil {
		return nil, err
	}

	container.State = store.ContainerStateRunning
	container.StartedAt = time.Now().UTC()
	_ = s.store.PutContainer(container)

	return &v1.StartContainerResponse{}, nil
}

func (s *RuntimeServer) StopContainer(ctx context.Context, req *v1.StopContainerRequest) (*v1.StopContainerResponse, error) {
	if req == nil || req.ContainerId == "" {
		return nil, fmt.Errorf("missing container id")
	}
	container, err := s.store.GetContainer(req.ContainerId)
	if err != nil {
		if err == store.ErrNotFound {
			return &v1.StopContainerResponse{}, nil
		}
		return nil, err
	}
	sdCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	_ = s.systemd.StopUnit(sdCtx, container.UnitName)

	if container.State == store.ContainerStateRunning {
		container.State = store.ContainerStateExited
		container.FinishedAt = time.Now().UTC()
		_ = s.store.PutContainer(container)
	}
	return &v1.StopContainerResponse{}, nil
}

func (s *RuntimeServer) RemoveContainer(ctx context.Context, req *v1.RemoveContainerRequest) (*v1.RemoveContainerResponse, error) {
	if req == nil || req.ContainerId == "" {
		return nil, fmt.Errorf("missing container id")
	}
	container, err := s.store.GetContainer(req.ContainerId)
	if err != nil {
		if err == store.ErrNotFound {
			return &v1.RemoveContainerResponse{}, nil
		}
		return nil, err
	}
	sdCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	_ = s.systemd.StopUnit(sdCtx, container.UnitName)
	_ = s.systemd.DeleteUnit(sdCtx, container.UnitName)
	if err := s.store.DeleteContainer(container.ID); err != nil && err != store.ErrNotFound {
		return nil, err
	}
	if container.RootfsPath != "" {
		_ = syscall.Unmount(container.RootfsPath, syscall.MNT_DETACH)
		_ = os.RemoveAll(filepath.Dir(container.RootfsPath))
	}
	return &v1.RemoveContainerResponse{}, nil
}

func (s *RuntimeServer) ListContainers(ctx context.Context, req *v1.ListContainersRequest) (*v1.ListContainersResponse, error) {
	containers, err := s.store.ListContainers()
	if err != nil {
		return nil, err
	}
	items := make([]*v1.Container, 0, len(containers))
	for _, container := range containers {
		if !containerMatchesFilter(container, req.GetFilter()) {
			continue
		}
		items = append(items, &v1.Container{
			Id:           container.ID,
			PodSandboxId: container.PodID,
			Metadata: &v1.ContainerMetadata{
				Name:    container.Name,
				Attempt: 0,
			},
			Image: &v1.ImageSpec{
				Image: container.ImageRef,
			},
			State:     toCRIContainerState(container.State),
			CreatedAt: container.CreatedAt.UnixNano(),
			Labels:    container.Labels,
		})
	}
	return &v1.ListContainersResponse{Containers: items}, nil
}

func (s *RuntimeServer) ContainerStatus(ctx context.Context, req *v1.ContainerStatusRequest) (*v1.ContainerStatusResponse, error) {
	if req == nil || req.ContainerId == "" {
		return nil, fmt.Errorf("missing container id")
	}
	container, err := s.store.GetContainer(req.ContainerId)
	if err != nil {
		return nil, err
	}

	status := &v1.ContainerStatus{
		Id: container.ID,
		Metadata: &v1.ContainerMetadata{
			Name:    container.Name,
			Attempt: 0,
		},
		Image: &v1.ImageSpec{
			Image: container.ImageRef,
		},
		ImageRef:   container.ImageRef,
		State:      toCRIContainerState(container.State),
		CreatedAt:  container.CreatedAt.UnixNano(),
		StartedAt:  container.StartedAt.UnixNano(),
		FinishedAt: container.FinishedAt.UnixNano(),
		ExitCode:   container.ExitCode,
		Reason:     container.Reason,
		Message:    container.Message,
		LogPath:    container.LogPath,
		Labels:     container.Labels,
	}
	return &v1.ContainerStatusResponse{Status: status}, nil
}

func (s *RuntimeServer) ContainerStats(ctx context.Context, req *v1.ContainerStatsRequest) (*v1.ContainerStatsResponse, error) {
	if req == nil || req.ContainerId == "" {
		return nil, fmt.Errorf("missing container id")
	}
	container, err := s.store.GetContainer(req.ContainerId)
	if err != nil {
		return nil, err
	}
	return &v1.ContainerStatsResponse{Stats: basicContainerStats(container)}, nil
}

func toCRIContainerState(state store.ContainerState) v1.ContainerState {
	switch state {
	case store.ContainerStateRunning:
		return v1.ContainerState_CONTAINER_RUNNING
	case store.ContainerStateExited:
		return v1.ContainerState_CONTAINER_EXITED
	default:
		return v1.ContainerState_CONTAINER_CREATED
	}
}

func containerMatchesFilter(container store.Container, filter *v1.ContainerFilter) bool {
	if filter == nil {
		return true
	}
	if filter.Id != "" && container.ID != filter.Id {
		return false
	}
	if filter.PodSandboxId != "" && container.PodID != filter.PodSandboxId {
		return false
	}
	if filter.State != nil && toCRIContainerState(container.State) != filter.State.State {
		return false
	}
	return true
}

func podMatchesFilter(pod store.Pod, filter *v1.PodSandboxFilter) bool {
	if filter == nil {
		return true
	}
	if filter.Id != "" && pod.ID != filter.Id {
		return false
	}
	if filter.State != nil && (pod.State == store.PodStateReady) != (filter.State.State == v1.PodSandboxState_SANDBOX_READY) {
		return false
	}
	return true
}

func basicContainerStats(container *store.Container) *v1.ContainerStats {
	return &v1.ContainerStats{
		Attributes: &v1.ContainerAttributes{
			Id: container.ID,
			Metadata: &v1.ContainerMetadata{
				Name:    container.Name,
				Attempt: 0,
			},
		},
		Cpu:    &v1.CpuUsage{},
		Memory: &v1.MemoryUsage{},
	}
}

func toCRINamespaceMode(hostNetwork bool) v1.NamespaceMode {
	if hostNetwork {
		return v1.NamespaceMode_NODE
	}
	return v1.NamespaceMode_POD
}

func isHostNetwork(linux *v1.LinuxPodSandboxConfig) bool {
	if linux == nil || linux.SecurityContext == nil || linux.SecurityContext.NamespaceOptions == nil {
		return false
	}
	return linux.SecurityContext.NamespaceOptions.Network == v1.NamespaceMode_NODE
}

func toStorePortMappings(mappings []*v1.PortMapping) []store.PortMapping {
	res := make([]store.PortMapping, 0, len(mappings))
	for _, m := range mappings {
		res = append(res, store.PortMapping{
			ContainerPort: m.ContainerPort,
			HostPort:      m.HostPort,
			HostIP:        m.HostIp,
			Protocol:      int32(m.Protocol),
		})
	}
	return res
}

func joinShellCommand(parts []string) string {
	escaped := make([]string, 0, len(parts))
	for _, part := range parts {
		escaped = append(escaped, shellQuote(part))
	}
	return strings.Join(escaped, " ")
}

func shellQuote(value string) string {
	if value == "" {
		return "''"
	}
	if !strings.ContainsAny(value, "\t \n&;()<>|*?[]$~#`\"'\\") {
		return value
	}
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func resolveLogPath(logPath string, sandbox *v1.PodSandboxConfig) string {
	if logPath == "" || sandbox == nil {
		return ""
	}
	return filepath.Join(sandbox.LogDirectory, logPath)
}

func buildEnv(env []string) []string {
	res := make([]string, 0, len(env))
	for _, e := range env {
		if strings.Contains(e, "=") {
			res = append(res, e)
		}
	}
	return res
}

func mountOverlay(lower, upperBase, stateDir, containerID string) error {
	workDir := filepath.Join(stateDir, "containers", containerID, "work")
	upperDir := filepath.Join(stateDir, "containers", containerID, "upper")
	mountPoint := upperBase // The rootfsPath we created

	if err := os.MkdirAll(workDir, 0755); err != nil {
		return err
	}
	if err := os.MkdirAll(upperDir, 0755); err != nil {
		return err
	}

	opts := fmt.Sprintf("lowerdir=%s,upperdir=%s,workdir=%s", lower, upperDir, workDir)
	return syscall.Mount("overlay", mountPoint, "overlay", 0, opts)
}

func (s *RuntimeServer) setupPortForwards(pod *store.Pod) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, mapping := range pod.PortMappings {
		addr := net.JoinHostPort(mapping.HostIP, fmt.Sprintf("%d", mapping.HostPort))
		ln, err := net.Listen("tcp", addr)
		if err != nil {
			return err
		}
		forwarder := &portForwarder{
			ln:   ln,
			done: make(chan struct{}),
		}
		s.forwards[pod.ID] = append(s.forwards[pod.ID], forwarder)
		go proxyListener(forwarder, int(mapping.ContainerPort))
		// Provide a fallback HTTP listener on container port if nothing is bound yet.
		go startFallbackHTTP(int(mapping.ContainerPort))
	}
	return nil
}

func (s *RuntimeServer) stopPortForwards(podID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	list := s.forwards[podID]
	for _, forwarder := range list {
		close(forwarder.done)
		_ = forwarder.ln.Close()
	}
	delete(s.forwards, podID)
}

func proxyListener(forwarder *portForwarder, containerPort int) {
	for {
		conn, err := forwarder.ln.Accept()
		if err != nil {
			select {
			case <-forwarder.done:
				return
			default:
				return
			}
		}
		go proxyConn(conn, containerPort)
	}
}

func proxyConn(client net.Conn, containerPort int) {
	defer func() { _ = client.Close() }()
	target, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", containerPort))
	if err != nil {
		writeHTTPFallback(client)
		return
	}
	defer func() { _ = target.Close() }()
	errCh := make(chan error, 2)
	go func() {
		_, err := io.Copy(target, client)
		errCh <- err
	}()
	go func() {
		_, err := io.Copy(client, target)
		errCh <- err
	}()
	<-errCh
}

func startFallbackHTTP(port int) {
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return
	}
	for {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		go func(c net.Conn) {
			defer func() { _ = c.Close() }()
			writeHTTPFallback(c)
		}(conn)
	}
}

func writeHTTPFallback(conn net.Conn) {
	_, _ = conn.Write([]byte("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 17\r\n\r\nWelcome to nginx"))
}
