package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"runtime/debug"

	"github.com/ananthb/systemd-cri/internal/crisvc"
	"github.com/coreos/go-systemd/v22/daemon"
	"google.golang.org/grpc"
	runtime "k8s.io/cri-api/pkg/apis/runtime/v1"
)

func main() {
	if *version {
		v := "(devel)"
		if info, ok := debug.ReadBuildInfo(); ok {
			v = info.Main.Version
		}
		fmt.Println(v)
		os.Exit(0)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	cri, err := crisvc.New(*stateDir)
	if err != nil {
		slog.Error("error creating service", "error", err)
		os.Exit(1)
	}

	grpcServer := grpc.NewServer()

	runtime.RegisterRuntimeServiceServer(grpcServer, cri)
	runtime.RegisterImageServiceServer(grpcServer, cri)

	lis, err := listen()
	if err != nil {
		slog.Error("error creating listener", "error", err)
		os.Exit(1)
	}

	slog.Info("starting server", "address", *listenAddr)
	go func() {
		if err := grpcServer.Serve(lis); err != nil {
			slog.Error("error serving grpc", "error", err)
			os.Exit(1)
		}
	}()

	_, _ = daemon.SdNotify(false, daemon.SdNotifyReady)

	<-ctx.Done()
	slog.Info("shutting down")
	_, _ = daemon.SdNotify(false, daemon.SdNotifyStopping)

	if err := lis.Close(); err != nil {
		slog.Error("error closing listener", "error", err)
	}

	grpcServer.GracefulStop()
}
