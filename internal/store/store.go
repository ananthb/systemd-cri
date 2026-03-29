package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	_ "modernc.org/sqlite"
)

var ErrNotFound = errors.New("not found")

// PodState matches CRI-style sandbox state at a high level.
type PodState string

const (
	PodStateReady    PodState = "READY"
	PodStateNotReady PodState = "NOTREADY"
)

type Pod struct {
	ID           string            `json:"id"`
	Name         string            `json:"name"`
	Namespace    string            `json:"namespace"`
	UID          string            `json:"uid"`
	CreatedAt    time.Time         `json:"created_at"`
	State        PodState          `json:"state"`
	Labels       map[string]string `json:"labels,omitempty"`
	Annotations  map[string]string `json:"annotations,omitempty"`
	Hostname     string            `json:"hostname,omitempty"`
	UnitName     string            `json:"unit_name"`
	HostNetwork  bool              `json:"host_network,omitempty"`
	PortMappings []PortMapping     `json:"port_mappings,omitempty"`
}

type PortMapping struct {
	ContainerPort int32  `json:"container_port"`
	HostPort      int32  `json:"host_port"`
	HostIP        string `json:"host_ip,omitempty"`
	Protocol      int32  `json:"protocol"`
}

type Store struct {
	db *sql.DB
}

// ContainerState mirrors CRI container states at a high level.
type ContainerState string

const (
	ContainerStateCreated ContainerState = "CREATED"
	ContainerStateRunning ContainerState = "RUNNING"
	ContainerStateExited  ContainerState = "EXITED"
)

type Container struct {
	ID          string            `json:"id"`
	PodID       string            `json:"pod_id"`
	Name        string            `json:"name"`
	ImageRef    string            `json:"image_ref"`
	CreatedAt   time.Time         `json:"created_at"`
	StartedAt   time.Time         `json:"started_at,omitempty"`
	FinishedAt  time.Time         `json:"finished_at,omitempty"`
	State       ContainerState    `json:"state"`
	Labels      map[string]string `json:"labels,omitempty"`
	Annotations map[string]string `json:"annotations,omitempty"`
	LogPath     string            `json:"log_path,omitempty"`
	WorkingDir  string            `json:"working_dir,omitempty"`
	RootfsPath  string            `json:"rootfs_path,omitempty"`
	UnitName    string            `json:"unit_name"`
	Command     []string          `json:"command,omitempty"`
	Args        []string          `json:"args,omitempty"`
	ExitCode    int32             `json:"exit_code,omitempty"`
	Reason      string            `json:"reason,omitempty"`
	Message     string            `json:"message,omitempty"`
}

type Image struct {
	ID          string            `json:"id"`
	Repo        string            `json:"repo,omitempty"`
	RepoTags    []string          `json:"repo_tags,omitempty"`
	RepoDigests []string          `json:"repo_digests,omitempty"`
	Size        uint64            `json:"size,omitempty"`
	Username    string            `json:"username,omitempty"`
	Labels      map[string]string `json:"labels,omitempty"`
	RootfsPath  string            `json:"rootfs_path,omitempty"`
	Args        []string          `json:"args,omitempty"`
	WorkDir     string            `json:"work_dir,omitempty"`
	Env         []string          `json:"env,omitempty"`
}

func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}

	sqlStmt := `
	CREATE TABLE IF NOT EXISTS pods (id TEXT PRIMARY KEY, data JSON);
	CREATE TABLE IF NOT EXISTS containers (id TEXT PRIMARY KEY, data JSON);
	CREATE TABLE IF NOT EXISTS images (id TEXT PRIMARY KEY, data JSON);
	`
	_, err = db.Exec(sqlStmt)
	if err != nil {
		_ = db.Close()
		return nil, err
	}

	return &Store{db: db}, nil
}

func (s *Store) Close() error {
	return s.db.Close()
}

func (s *Store) PutPod(pod *Pod) error {
	data, err := json.Marshal(pod)
	if err != nil {
		return err
	}
	_, err = s.db.Exec("INSERT OR REPLACE INTO pods (id, data) VALUES (?, ?)", pod.ID, data)
	return err
}

func (s *Store) GetPod(id string) (*Pod, error) {
	var data []byte
	err := s.db.QueryRow("SELECT data FROM pods WHERE id = ?", id).Scan(&data)
	if err != nil {
		if err == sql.ErrNoRows {
			return nil, ErrNotFound
		}
		return nil, err
	}
	var pod Pod
	if err := json.Unmarshal(data, &pod); err != nil {
		return nil, err
	}
	return &pod, nil
}

func (s *Store) DeletePod(id string) error {
	res, err := s.db.Exec("DELETE FROM pods WHERE id = ?", id)
	if err != nil {
		return err
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Store) ListPods() ([]Pod, error) {
	rows, err := s.db.Query("SELECT data FROM pods")
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()

	var pods []Pod
	for rows.Next() {
		var data []byte
		if err := rows.Scan(&data); err != nil {
			return nil, err
		}
		var pod Pod
		if err := json.Unmarshal(data, &pod); err != nil {
			return nil, err
		}
		pods = append(pods, pod)
	}
	return pods, nil
}

func (s *Store) PutContainer(container *Container) error {
	data, err := json.Marshal(container)
	if err != nil {
		return err
	}
	_, err = s.db.Exec("INSERT OR REPLACE INTO containers (id, data) VALUES (?, ?)", container.ID, data)
	return err
}

func (s *Store) GetContainer(id string) (*Container, error) {
	var data []byte
	err := s.db.QueryRow("SELECT data FROM containers WHERE id = ?", id).Scan(&data)
	if err != nil {
		if err == sql.ErrNoRows {
			return nil, ErrNotFound
		}
		return nil, err
	}
	var container Container
	if err := json.Unmarshal(data, &container); err != nil {
		return nil, err
	}
	return &container, nil
}

func (s *Store) DeleteContainer(id string) error {
	res, err := s.db.Exec("DELETE FROM containers WHERE id = ?", id)
	if err != nil {
		return err
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Store) ListContainers() ([]Container, error) {
	rows, err := s.db.Query("SELECT data FROM containers")
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()

	var containers []Container
	for rows.Next() {
		var data []byte
		if err := rows.Scan(&data); err != nil {
			return nil, err
		}
		var container Container
		if err := json.Unmarshal(data, &container); err != nil {
			return nil, err
		}
		containers = append(containers, container)
	}
	return containers, nil
}

func (s *Store) PutImage(image *Image) error {
	data, err := json.Marshal(image)
	if err != nil {
		return err
	}
	_, err = s.db.Exec("INSERT OR REPLACE INTO images (id, data) VALUES (?, ?)", image.ID, data)
	return err
}

func (s *Store) GetImage(id string) (*Image, error) {
	var data []byte
	err := s.db.QueryRow("SELECT data FROM images WHERE id = ?", id).Scan(&data)
	if err != nil {
		if err == sql.ErrNoRows {
			return nil, ErrNotFound
		}
		return nil, err
	}
	var image Image
	if err := json.Unmarshal(data, &image); err != nil {
		return nil, err
	}
	return &image, nil
}

func (s *Store) DeleteImage(id string) error {
	res, err := s.db.Exec("DELETE FROM images WHERE id = ?", id)
	if err != nil {
		return err
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Store) ListImages() ([]Image, error) {
	rows, err := s.db.Query("SELECT data FROM images")
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()

	var images []Image
	for rows.Next() {
		var data []byte
		if err := rows.Scan(&data); err != nil {
			return nil, err
		}
		var image Image
		if err := json.Unmarshal(data, &image); err != nil {
			return nil, err
		}
		images = append(images, image)
	}
	return images, nil
}
