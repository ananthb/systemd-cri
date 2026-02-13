module systemd-cri

go 1.22

require (
	github.com/coreos/go-systemd/v22 v22.5.0
	github.com/godbus/dbus/v5 v5.1.0
	go.etcd.io/bbolt v1.3.9
	google.golang.org/grpc v1.66.0
	k8s.io/cri-api v0.30.0
	k8s.io/apimachinery v0.30.0
)
