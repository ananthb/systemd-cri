package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"
	"k8s.io/cri-api/pkg/apis/runtime/v1"
	"k8s.io/kubelet/pkg/cri/streaming"

	"systemd-cri/internal/config"
	"systemd-cri/internal/cri"
	"systemd-cri/internal/store"
	"systemd-cri/internal/systemd"
)

func main() {
	cfg := config.Default()

	flag.StringVar(&cfg.StateDir, "state-dir", cfg.StateDir, "state directory")
	flag.StringVar(&cfg.RuntimeDir, "runtime-dir", cfg.RuntimeDir, "runtime directory")
	flag.StringVar(&cfg.SocketPath, "socket", cfg.SocketPath, "CRI socket path")
	flag.IntVar(&cfg.StreamingPort, "streaming-port", cfg.StreamingPort, "streaming port")
	flag.IntVar(&cfg.MetricsPort, "metrics-port", cfg.MetricsPort, "metrics port")
	flag.StringVar(&cfg.LogLevel, "log-level", cfg.LogLevel, "log level")
	flag.Parse()

	if err := os.MkdirAll(cfg.RuntimeDir, 0755); err != nil {
		log.Fatalf("failed to create runtime dir: %v", err)
	}
	if err := os.MkdirAll(cfg.StateDir, 0755); err != nil {
		log.Fatalf("failed to create state dir: %v", err)
	}

	if cfg.SocketPath == "" {
		cfg.SocketPath = filepath.Join(cfg.RuntimeDir, "cri.sock")
	}

	_ = os.Remove(cfg.SocketPath)

	storePath := filepath.Join(cfg.StateDir, "state.db")
	st, err := store.Open(storePath)
	if err != nil {
		log.Fatalf("failed to open state store: %v", err)
	}
	defer func() { _ = st.Close() }()

	systemdMgr, err := systemd.New()
	if err != nil {
		log.Fatalf("failed to connect to systemd: %v", err)
	}
	defer func() { _ = systemdMgr.Close() }()

	runtimeSrv := cri.NewRuntimeServer(st, systemdMgr, cfg.StateDir)
	imageSrv := cri.NewImageServer(st, cfg.StateDir)
	streamRuntime := cri.NewStreamRuntime(st)

	streamAddr := net.JoinHostPort("127.0.0.1", fmt.Sprintf("%d", cfg.StreamingPort))
	streamConfig := streaming.DefaultConfig
	streamConfig.Addr = streamAddr
	streamConfig.StreamIdleTimeout = 4 * time.Hour
	streamServer, err := streaming.NewServer(streamConfig, streamRuntime)
	if err != nil {
		log.Fatalf("failed to create streaming server: %v", err)
	}
	runtimeSrv.SetStreamingServer(streamServer)
	go func() {
		if err := streamServer.Start(true); err != nil {
			log.Printf("streaming server stopped: %v", err)
		}
	}()

	lis, err := net.Listen("unix", cfg.SocketPath)
	if err != nil {
		log.Fatalf("failed to listen on %s: %v", cfg.SocketPath, err)
	}
	defer func() { _ = lis.Close() }()

	grpcServer := grpc.NewServer()
	v1.RegisterRuntimeServiceServer(grpcServer, runtimeSrv)
	v1.RegisterImageServiceServer(grpcServer, imageSrv)
	reflection.Register(grpcServer)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		sigCh := make(chan os.Signal, 2)
		signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
		<-sigCh
		log.Println("shutting down...")
		cancel()
		grpcServer.GracefulStop()
		_ = streamServer.Stop()
	}()

	log.Printf("systemd-cri-go listening on %s", cfg.SocketPath)
	if err := grpcServer.Serve(lis); err != nil {
		if ctx.Err() != nil {
			return
		}
		log.Fatalf("grpc server error: %v", err)
	}
}
