package main

import (
	"context"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"

	"git.sr.ht/~ananth/systemd-cri/internal/crisvc"
	"github.com/soheilhy/cmux"
	"google.golang.org/grpc"
	v1 "k8s.io/cri-api/pkg/apis/runtime/v1"
)

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	cri, err := crisvc.New()
	if err != nil {
		slog.Error("error creating service", "error", err)
		os.Exit(1)
	}

	grpcServer := grpc.NewServer()

	v1.RegisterRuntimeServiceServer(grpcServer, cri)
	v1.RegisterImageServiceServer(grpcServer, cri)

	const addr = ":50051"

	lis, err := net.Listen("tcp", addr)
	if err != nil {
		slog.Error("error creating listener", "error", err)
		os.Exit(1)
	}

	m := cmux.New(lis)
	grpcLis := m.MatchWithWriters(cmux.HTTP2MatchHeaderFieldSendSettings("content-type", "application/grpc"))
	httpLis := m.Match(cmux.HTTP1Fast())

	slog.Info("starting server", "address", addr)
	go func() {
		if err := grpcServer.Serve(grpcLis); err != nil {
			slog.Error("error serving grpc", "error", err)
			os.Exit(1)
		}
	}()
	go func() {
		if err := http.Serve(httpLis, nil); err != nil {
			slog.Error("error serving http", "error", err)
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	slog.Info("shutting down")

	grpcServer.GracefulStop()
}
