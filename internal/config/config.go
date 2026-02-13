package config

import "time"

type Config struct {
	StateDir      string
	RuntimeDir    string
	SocketPath    string
	StreamingPort int
	MetricsPort   int
	LogLevel      string
	ShutdownGrace time.Duration
}

func Default() Config {
	return Config{
		StateDir:      "/var/lib/systemd-cri",
		RuntimeDir:    "/run/systemd-cri",
		SocketPath:    "/run/systemd-cri/cri.sock",
		StreamingPort: 10010,
		MetricsPort:   9090,
		LogLevel:      "info",
		ShutdownGrace: 5 * time.Second,
	}
}
