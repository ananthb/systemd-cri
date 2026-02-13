# systemd-cri (Go rewrite)

This is the Go rewrite of systemd-cri. It is a CRI implementation that depends only on systemd at runtime and manages pods/containers via systemd D-Bus.

## Layout
- `cmd/systemd-cri` - main binary
- `internal/cri` - CRI gRPC services
- `internal/systemd` - systemd D-Bus wrapper
- `internal/store` - embedded KV store (bbolt)
- `legacy-zig/` - previous Zig implementation (archived)

## Build (WIP)
```
go build ./cmd/systemd-cri
```
