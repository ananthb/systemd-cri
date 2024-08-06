package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path"
	"strings"

	"git.sr.ht/~ananth/systemd-cri/internal/crisvc"
	"github.com/coreos/go-systemd/v22/daemon"
	"github.com/soheilhy/cmux"
	"google.golang.org/grpc"
	runtime "k8s.io/cri-api/pkg/apis/runtime/v1"
)

var logLevel = flag.String("log-level", "info", "log level")
var listenAddr = flag.String("listen-addr", "unix:///run/systemd-cri.sock", "address to listen on")

func init() {
	flag.Parse()

	var level slog.Level
	if err := level.UnmarshalText([]byte(*logLevel)); err != nil {
		slog.Error("error parsing log level", "error", err)
		os.Exit(1)
	}
	handler := slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level})
	slog.SetDefault(slog.New(handler))
}

func main() {
	flag.Parse()

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	cri, err := crisvc.New()
	if err != nil {
		slog.Error("error creating service", "error", err)
		os.Exit(1)
	}

	grpcServer := grpc.NewServer()
	httpServer := new(http.Server)

	runtime.RegisterRuntimeServiceServer(grpcServer, cri)
	runtime.RegisterImageServiceServer(grpcServer, cri)

	lis, err := listen()
	if err != nil {
		slog.Error("error creating listener", "error", err)
		os.Exit(1)
	}

	m := cmux.New(lis)
	grpcLis := m.MatchWithWriters(cmux.HTTP2MatchHeaderFieldSendSettings("content-type", "application/grpc"))
	httpLis := m.Match(cmux.HTTP1Fast())

	slog.Info("starting server", "address", *listenAddr)
	go func() {
		if err := grpcServer.Serve(grpcLis); err != nil {
			slog.Error("error serving grpc", "error", err)
			os.Exit(1)
		}
	}()
	go func() {
		if err := httpServer.Serve(httpLis); err != nil {
			slog.Error("error serving http", "error", err)
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

	ctx, cancel = context.WithTimeout(context.Background(), 5)
	defer cancel()
	if err := httpServer.Shutdown(ctx); err != nil {
		slog.Error("error shutting down http", "error", err)
	}
}

func listen() (net.Listener, error) {
	if *listenAddr == "" {
		return nil, nil
	}

	addr, err := url.Parse(*listenAddr)
	if err != nil {
		return nil, err
	}

	unixAddr := path.Join(addr.Host, addr.Path)

	switch addr.Scheme {
	case "unix":
		return net.Listen("unix", unixAddr)
	case "tcp":
		return net.Listen("tcp", addr.Host)
	case "":
		if strings.Contains(addr.Path, ":") {
			return net.Listen("tcp", addr.Host)
		}

		return net.Listen("unix", unixAddr)
	default:
		return nil, fmt.Errorf("unsupported scheme %s", addr.Scheme)
	}
}
