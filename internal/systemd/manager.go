package systemd

import (
	"context"
	"time"

	"github.com/coreos/go-systemd/v22/dbus"
)

type Manager struct {
	conn *dbus.Conn
}

func New() (*Manager, error) {
	conn, err := dbus.NewWithContext(context.Background())
	if err != nil {
		return nil, err
	}
	return &Manager{conn: conn}, nil
}

func (m *Manager) Close() error {
	return m.conn.Close()
}

func (m *Manager) StartTransientService(ctx context.Context, name string, execPath string, args []string, props ...dbus.Property) error {
	exec := []dbus.ExecStart{{Path: execPath, Args: append([]string{execPath}, args...), Unescape: false}}
	allProps := []dbus.Property{
		dbus.PropExecStart(exec),
		dbus.PropRemainAfterExit(true),
		dbus.PropType("simple"),
	}
	allProps = append(allProps, props...)
	ch := make(chan string, 1)
	_, err := m.conn.StartTransientUnitContext(ctx, name, "replace", allProps, ch)
	if err != nil {
		return err
	}
	select {
	case <-ch:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (m *Manager) StopUnit(ctx context.Context, name string) error {
	ch := make(chan string, 1)
	_, err := m.conn.StopUnitContext(ctx, name, "replace", ch)
	if err != nil {
		return err
	}
	select {
	case <-ch:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (m *Manager) GetUnitState(ctx context.Context, name string) (string, error) {
	return m.conn.GetUnitPropertyContext(ctx, name, "ActiveState")
}

func (m *Manager) GetUnitMainPID(ctx context.Context, name string) (uint32, error) {
	pid, err := m.conn.GetUnitPropertyContext(ctx, name, "MainPID")
	if err != nil {
		return 0, err
	}
	return pid.Value.(uint32), nil
}

func DefaultContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), 10*time.Second)
}
