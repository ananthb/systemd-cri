package cri

import (
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"syscall"

	"k8s.io/client-go/tools/remotecommand"

	"systemd-cri/internal/store"
)

type StreamRuntime struct {
	store *store.Store
}

func NewStreamRuntime(store *store.Store) *StreamRuntime {
	return &StreamRuntime{store: store}
}

func (r *StreamRuntime) Exec(ctx context.Context, containerID string, cmd []string, in io.Reader, out, errw io.WriteCloser, tty bool, resize <-chan remotecommand.TerminalSize) error {
	if len(cmd) == 0 {
		return fmt.Errorf("missing command")
	}
	container, err := r.store.GetContainer(containerID)
	if err != nil {
		return err
	}
	proc := exec.CommandContext(ctx, "/bin/sh", "-c", "exec "+joinShellCommand(cmd))
	proc.Env = append(os.Environ(), "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
	if container.WorkingDir != "" {
		proc.Dir = container.WorkingDir
	} else if container.RootfsPath != "" {
		proc.Dir = "/"
	}
	if container.RootfsPath != "" {
		proc.SysProcAttr = &syscall.SysProcAttr{Chroot: container.RootfsPath}
	}
	return runStreamingProcess(proc, in, out, errw, tty)
}

func (r *StreamRuntime) Attach(ctx context.Context, containerID string, in io.Reader, out, errw io.WriteCloser, tty bool, resize <-chan remotecommand.TerminalSize) error {
	container, err := r.store.GetContainer(containerID)
	if err != nil {
		return err
	}
	proc := exec.CommandContext(ctx, "/bin/sh")
	proc.Env = append(os.Environ(), "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
	if container.WorkingDir != "" {
		proc.Dir = container.WorkingDir
	} else if container.RootfsPath != "" {
		proc.Dir = "/"
	}
	if container.RootfsPath != "" {
		proc.SysProcAttr = &syscall.SysProcAttr{Chroot: container.RootfsPath}
	}
	return runStreamingProcess(proc, in, out, errw, tty)
}

func (r *StreamRuntime) PortForward(ctx context.Context, podSandboxID string, port int32, stream io.ReadWriteCloser) error {
	defer func() { _ = stream.Close() }()
	address := fmt.Sprintf("127.0.0.1:%d", port)
	conn, err := net.Dial("tcp", address)
	if err != nil {
		return err
	}
	defer func() { _ = conn.Close() }()

	errCh := make(chan error, 2)
	go func() {
		_, err := io.Copy(conn, stream)
		errCh <- err
	}()
	go func() {
		_, err := io.Copy(stream, conn)
		errCh <- err
	}()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case err := <-errCh:
		return err
	}
}

func runStreamingProcess(proc *exec.Cmd, in io.Reader, out, errw io.WriteCloser, tty bool) error {
	defer func() { _ = out.Close() }()
	if errw != nil {
		defer func() { _ = errw.Close() }()
	}
	if in != nil {
		proc.Stdin = in
	}
	proc.Stdout = out
	if tty {
		proc.Stderr = out
	} else {
		proc.Stderr = errw
	}
	return proc.Run()
}
