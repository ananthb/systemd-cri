package main

import (
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/url"
	"os"
	"path"
	"strings"
)

var logLevel = flag.String("log-level", "info", "log level")
var listenAddr = flag.String("listen-addr", "/run/systemd/cri/cri.sock", "address to listen on")
var stateDir = flag.String("state-dir", "/var/lib/systemd/cri", "directory to store state")
var version = flag.Bool("version", false, "Print version and exit")

func init() {
	flag.Parse()

	var level slog.Level
	if err := level.UnmarshalText([]byte(*logLevel)); err != nil {
		slog.Error("error parsing log level", "error", err)
		os.Exit(1)
	}
	handler := slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level})
	slog.SetDefault(slog.New(handler))

	if sd, ok := os.LookupEnv("STATE_DIRECTORY"); *stateDir == "" && ok {
		*stateDir = sd
	}

	if err := os.MkdirAll(*stateDir, 0755); err != nil {
		slog.Error("error creating state directory", "error", err)
		os.Exit(1)
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

	network := "unix"
	address := path.Join(addr.Host, addr.Path)

	switch addr.Scheme {
	case "unix":
	case "tcp":
		network = "tcp"
		address = addr.Host
	case "":
		if strings.Contains(addr.Path, ":") {
			network = "tcp"
			address = addr.Path
		}
	default:
		return nil, fmt.Errorf("unsupported scheme %s", addr.Scheme)
	}

	if network == "unix" {
		if err := os.Remove(address); err != nil && !os.IsNotExist(err) {
			return nil, err
		}

		if err := os.MkdirAll(path.Dir(address), 0755); err != nil {
			return nil, err
		}
	}

	return net.Listen(network, address)
}
