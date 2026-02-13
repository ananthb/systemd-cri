package store

import (
	"encoding/json"
	"errors"
	"time"

	"go.etcd.io/bbolt"
)

const (
	bucketPods       = "pods"
	bucketContainers = "containers"
	bucketImages     = "images"
)

var ErrNotFound = errors.New("not found")

// PodState matches CRI-style sandbox state at a high level.
type PodState string

const (
	PodStateReady    PodState = "READY"
	PodStateNotReady PodState = "NOTREADY"
)

type Pod struct {
	ID          string            `json:"id"`
	Name        string            `json:"name"`
	Namespace   string            `json:"namespace"`
	UID         string            `json:"uid"`
	CreatedAt   time.Time         `json:"created_at"`
	State       PodState          `json:"state"`
	Labels      map[string]string `json:"labels,omitempty"`
	Annotations map[string]string `json:"annotations,omitempty"`
	Hostname    string            `json:"hostname,omitempty"`
	UnitName    string            `json:"unit_name"`
}

type Store struct {
	db *bbolt.DB
}

func Open(path string) (*Store, error) {
	db, err := bbolt.Open(path, 0600, &bbolt.Options{Timeout: 2 * time.Second})
	if err != nil {
		return nil, err
	}
	err = db.Update(func(tx *bbolt.Tx) error {
		if _, err := tx.CreateBucketIfNotExists([]byte(bucketPods)); err != nil {
			return err
		}
		if _, err := tx.CreateBucketIfNotExists([]byte(bucketContainers)); err != nil {
			return err
		}
		if _, err := tx.CreateBucketIfNotExists([]byte(bucketImages)); err != nil {
			return err
		}
		return nil
	})
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
	return s.db.Update(func(tx *bbolt.Tx) error {
		b := tx.Bucket([]byte(bucketPods))
		data, err := json.Marshal(pod)
		if err != nil {
			return err
		}
		return b.Put([]byte(pod.ID), data)
	})
}

func (s *Store) GetPod(id string) (*Pod, error) {
	var pod Pod
	err := s.db.View(func(tx *bbolt.Tx) error {
		b := tx.Bucket([]byte(bucketPods))
		data := b.Get([]byte(id))
		if data == nil {
			return ErrNotFound
		}
		return json.Unmarshal(data, &pod)
	})
	if err != nil {
		return nil, err
	}
	return &pod, nil
}

func (s *Store) DeletePod(id string) error {
	return s.db.Update(func(tx *bbolt.Tx) error {
		b := tx.Bucket([]byte(bucketPods))
		data := b.Get([]byte(id))
		if data == nil {
			return ErrNotFound
		}
		return b.Delete([]byte(id))
	})
}

func (s *Store) ListPods() ([]Pod, error) {
	pods := []Pod{}
	err := s.db.View(func(tx *bbolt.Tx) error {
		b := tx.Bucket([]byte(bucketPods))
		return b.ForEach(func(_, v []byte) error {
			var pod Pod
			if err := json.Unmarshal(v, &pod); err != nil {
				return err
			}
			pods = append(pods, pod)
			return nil
		})
	})
	if err != nil {
		return nil, err
	}
	return pods, nil
}
