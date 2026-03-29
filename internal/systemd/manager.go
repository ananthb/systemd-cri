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
	m.conn.Close()
	return nil
}

func (m *Manager) StartTransientService(ctx context.Context, name string, execPath string, args []string, props ...dbus.Property) error {
	command := append([]string{execPath}, args...)
	allProps := []dbus.Property{
		dbus.PropExecStart(command, false),
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

func (m *Manager) DeleteUnit(ctx context.Context, name string) error {
	// For transient units, stop is enough as they are not persisted on disk by us in /run/systemd/system/
	// unless we manually wrote them. Since we are moving back to transient units,
	// we don't need to delete files.
	return nil
}

func (m *Manager) GetUnitState(ctx context.Context, name string) (string, error) {
	prop, err := m.conn.GetUnitPropertyContext(ctx, name, "ActiveState")
	if err != nil {
		return "", err
	}
	if value, ok := prop.Value.Value().(string); ok {
		return value, nil
	}
	return "", nil
}

func (m *Manager) GetUnitMainPID(ctx context.Context, name string) (uint32, error) {
	pid, err := m.conn.GetUnitPropertyContext(ctx, name, "MainPID")
	if err != nil {
		return 0, err
	}
	if value, ok := pid.Value.Value().(uint32); ok {
		return value, nil
	}
	return 0, nil
}

func DefaultContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), 10*time.Second)
}
