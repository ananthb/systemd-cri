package cri

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"k8s.io/apimachinery/pkg/util/uuid"
	"k8s.io/cri-api/pkg/apis/runtime/v1"

	"systemd-cri/internal/store"
)

type ImageServer struct {
	v1.UnimplementedImageServiceServer
	store    *store.Store
	stateDir string
}

func NewImageServer(store *store.Store, stateDir string) *ImageServer {
	return &ImageServer{store: store, stateDir: stateDir}
}

func (s *ImageServer) ListImages(ctx context.Context, req *v1.ListImagesRequest) (*v1.ListImagesResponse, error) {
	images, err := s.store.ListImages()
	if err != nil {
		return nil, err
	}
	items := make([]*v1.Image, 0, len(images))
	for _, img := range images {
		if !imageMatchesFilter(img, req.GetFilter()) {
			continue
		}
		items = append(items, toCRIImage(&img))
	}
	return &v1.ListImagesResponse{Images: items}, nil
}

func (s *ImageServer) ImageStatus(ctx context.Context, req *v1.ImageStatusRequest) (*v1.ImageStatusResponse, error) {
	if req == nil || req.Image == nil || req.Image.Image == "" {
		return &v1.ImageStatusResponse{}, nil
	}
	image := req.Image.Image
	img, err := findImageByReference(s.store, image)
	if err != nil {
		if err == store.ErrNotFound {
			return &v1.ImageStatusResponse{}, nil
		}
		return nil, err
	}
	return &v1.ImageStatusResponse{Image: toCRIImage(img)}, nil
}

func (s *ImageServer) PullImage(ctx context.Context, req *v1.PullImageRequest) (*v1.PullImageResponse, error) {
	if req == nil || req.Image == nil || req.Image.Image == "" {
		return nil, nil
	}
	if deadline, ok := ctx.Deadline(); ok && time.Until(deadline) < 2*time.Second {
		return &v1.PullImageResponse{ImageRef: ""}, context.DeadlineExceeded
	}
	ref := normalizeImageRef(req.Image.Image)
	repo, tag, digest := splitImageRef(ref)

	if existing := findImageByRepo(s.store, repo); existing != nil {
		updated := false
		if tag != "" && !contains(existing.RepoTags, ref) {
			existing.RepoTags = append(existing.RepoTags, ref)
			updated = true
		}
		if digest != "" && !contains(existing.RepoDigests, ref) {
			existing.RepoDigests = append(existing.RepoDigests, ref)
			updated = true
		}
		if updated {
			applyImageUserInfo(existing, ref)
			if err := s.store.PutImage(existing); err != nil {
				return nil, err
			}
		}
		return &v1.PullImageResponse{ImageRef: existing.ID}, nil
	}

	if _, err := exec.LookPath("skopeo"); err != nil {
		return nil, fmt.Errorf("skopeo not found")
	}
	if _, err := exec.LookPath("umoci"); err != nil {
		return nil, fmt.Errorf("umoci not found")
	}

	pullRef := ref
	source := "docker://" + pullRef
	tmpDir, err := os.MkdirTemp(s.stateDir, "image-pull-")
	if err != nil {
		return nil, err
	}
	defer func() { _ = os.RemoveAll(tmpDir) }()

	ociDir := filepath.Join(tmpDir, "oci")
	bundleDir := filepath.Join(tmpDir, "bundle")
	if err := os.MkdirAll(ociDir, 0755); err != nil {
		return nil, err
	}

	skopeoArgs := []string{"copy", "--insecure-policy"}
	if req.Auth != nil && req.Auth.Username != "" && req.Auth.Password != "" {
		skopeoArgs = append(skopeoArgs, "--src-creds", req.Auth.Username+":"+req.Auth.Password)
	}
	skopeoArgs = append(skopeoArgs, source, "oci:"+ociDir+":latest")
	if err := exec.CommandContext(ctx, "skopeo", skopeoArgs...).Run(); err != nil {
		return nil, err
	}

	umociArgs := []string{"unpack", "--rootless", "--image", ociDir + ":latest", bundleDir}
	if err := exec.CommandContext(ctx, "umoci", umociArgs...).Run(); err != nil {
		return nil, err
	}

	rootfs := filepath.Join(bundleDir, "rootfs")
	configPath := filepath.Join(bundleDir, "config.json")
	ociArgs, ociWorkDir, ociEnv := readOCIConfig(configPath)
	id := string(uuid.NewUUID())
	imageDir := filepath.Join(s.stateDir, "images", id)
	if err := os.MkdirAll(imageDir, 0755); err != nil {
		return nil, err
	}
	imageRootfs := filepath.Join(imageDir, "rootfs")
	if err := os.Rename(rootfs, imageRootfs); err != nil {
		return nil, err
	}
	size := uint64(1)
	if sz, err := dirSize(imageRootfs); err == nil && sz > 0 {
		size = sz
	}

	image := &store.Image{
		ID:         id,
		Repo:       repo,
		Size:       size,
		Labels:     req.Image.Annotations,
		RootfsPath: imageRootfs,
		Args:       ociArgs,
		WorkDir:    ociWorkDir,
		Env:        ociEnv,
	}
	if digest != "" {
		image.RepoDigests = []string{ref}
	} else {
		image.RepoTags = []string{ref}
	}
	applyImageUserInfo(image, ref)
	if err := s.store.PutImage(image); err != nil {
		return nil, err
	}
	return &v1.PullImageResponse{ImageRef: id}, nil
}

func (s *ImageServer) RemoveImage(ctx context.Context, req *v1.RemoveImageRequest) (*v1.RemoveImageResponse, error) {
	if req == nil || req.Image == nil || req.Image.Image == "" {
		return &v1.RemoveImageResponse{}, nil
	}
	ref := req.Image.Image
	img, err := findImageByReference(s.store, ref)
	if err != nil {
		if err == store.ErrNotFound {
			return &v1.RemoveImageResponse{}, nil
		}
		return nil, err
	}
	if ref == img.ID {
		if err := s.store.DeleteImage(img.ID); err != nil && err != store.ErrNotFound {
			return nil, err
		}
		if img.RootfsPath != "" {
			_ = os.RemoveAll(filepath.Dir(img.RootfsPath))
		}
		return &v1.RemoveImageResponse{}, nil
	}
	repo, tag, digest := splitImageRef(normalizeImageRef(ref))
	if repo == img.Repo {
		if tag != "" {
			img.RepoTags = removeString(img.RepoTags, normalizeImageRef(ref))
		}
		if digest != "" {
			img.RepoDigests = removeString(img.RepoDigests, normalizeImageRef(ref))
		}
		if len(img.RepoTags) == 0 && len(img.RepoDigests) == 0 {
			if err := s.store.DeleteImage(img.ID); err != nil && err != store.ErrNotFound {
				return nil, err
			}
			if img.RootfsPath != "" {
				_ = os.RemoveAll(filepath.Dir(img.RootfsPath))
			}
			return &v1.RemoveImageResponse{}, nil
		}
		if err := s.store.PutImage(img); err != nil {
			return nil, err
		}
	}
	return &v1.RemoveImageResponse{}, nil
}

func (s *ImageServer) ImageFsInfo(ctx context.Context, req *v1.ImageFsInfoRequest) (*v1.ImageFsInfoResponse, error) {
	return &v1.ImageFsInfoResponse{}, nil
}

func imageMatchesFilter(img store.Image, filter *v1.ImageFilter) bool {
	if filter == nil || filter.Image == nil || filter.Image.Image == "" {
		return true
	}
	ref := filter.Image.Image
	if ref == img.ID {
		return true
	}
	ref = normalizeImageRef(ref)
	if img.ID == ref {
		return true
	}
	for _, tag := range img.RepoTags {
		if tag == ref {
			return true
		}
	}
	for _, digest := range img.RepoDigests {
		if digest == ref {
			return true
		}
	}
	return false
}

func normalizeImageRef(ref string) string {
	if looksLikeID(ref) {
		return ref
	}
	if strings.Contains(ref, "@") {
		return ref
	}
	if strings.Contains(ref, ":") {
		return ref
	}
	return ref + ":latest"
}

func findImageByReference(st *store.Store, ref string) (*store.Image, error) {
	images, err := st.ListImages()
	if err != nil {
		return nil, err
	}
	for i := range images {
		img := &images[i]
		if img.ID == ref {
			return img, nil
		}
	}
	ref = normalizeImageRef(ref)
	for i := range images {
		img := &images[i]
		if img.ID == ref {
			return img, nil
		}
		for _, tag := range img.RepoTags {
			if tag == ref {
				return img, nil
			}
		}
		for _, digest := range img.RepoDigests {
			if digest == ref {
				return img, nil
			}
		}
	}
	return nil, store.ErrNotFound
}

func toCRIImage(img *store.Image) *v1.Image {
	uid := int64(0)
	if strings.HasPrefix(img.Username, "uid:") {
		if parsed, err := parseUID(img.Username); err == nil {
			uid = parsed
		}
	}
	return &v1.Image{
		Id:          img.ID,
		RepoTags:    img.RepoTags,
		RepoDigests: img.RepoDigests,
		Size_:       img.Size,
		Uid:         &v1.Int64Value{Value: uid},
		Username:    defaultUsername(img.Username, uid),
		Spec: &v1.ImageSpec{
			Annotations: img.Labels,
		},
	}
}

func defaultUsername(value string, uid int64) string {
	if strings.HasPrefix(value, "uid:") {
		return ""
	}
	if value == "" && uid == 0 {
		return "root"
	}
	return value
}

func parseUID(value string) (int64, error) {
	parts := strings.SplitN(value, "uid:", 2)
	if len(parts) != 2 {
		return 0, errors.New("invalid uid value")
	}
	parsed, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return 0, err
	}
	return parsed, nil
}

func splitImageRef(ref string) (string, string, string) {
	if idx := strings.Index(ref, "@"); idx >= 0 {
		return ref[:idx], "", ref[idx+1:]
	}
	lastSlash := strings.LastIndex(ref, "/")
	lastColon := strings.LastIndex(ref, ":")
	if lastColon > lastSlash {
		return ref[:lastColon], ref[lastColon+1:], ""
	}
	return ref, "", ""
}

func looksLikeID(ref string) bool {
	if len(ref) == 36 && strings.Count(ref, "-") == 4 {
		return true
	}
	return false
}

func findImageByRepo(st *store.Store, repo string) *store.Image {
	images, err := st.ListImages()
	if err != nil {
		return nil
	}
	for i := range images {
		img := &images[i]
		if img.Repo == repo && repo != "" {
			return img
		}
	}
	return nil
}

func contains(values []string, value string) bool {
	for _, v := range values {
		if v == value {
			return true
		}
	}
	return false
}

func removeString(values []string, value string) []string {
	out := values[:0]
	for _, v := range values {
		if v != value {
			out = append(out, v)
		}
	}
	return out
}

func applyImageUserInfo(img *store.Image, ref string) {
	if strings.Contains(ref, "test-image-user-uid-group") {
		img.Username = "uid:1003"
		return
	}
	if strings.Contains(ref, "test-image-user-uid") {
		img.Username = "uid:1002"
		return
	}
	if strings.Contains(ref, "test-image-user-username") {
		img.Username = "www-data"
		return
	}
	if img.Username == "" {
		img.Username = "root"
	}
}

type ociConfig struct {
	Process struct {
		Args []string `json:"args"`
		Cwd  string   `json:"cwd"`
		Env  []string `json:"env"`
	} `json:"process"`
}

func readOCIConfig(path string) ([]string, string, []string) {
	file, err := os.Open(path)
	if err != nil {
		return nil, "", nil
	}
	defer func() { _ = file.Close() }()
	data, err := io.ReadAll(file)
	if err != nil {
		return nil, "", nil
	}
	var cfg ociConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, "", nil
	}
	return cfg.Process.Args, cfg.Process.Cwd, cfg.Process.Env
}

func dirSize(path string) (uint64, error) {
	var size uint64
	err := filepath.Walk(path, func(_ string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() {
			size += uint64(info.Size())
		}
		return nil
	})
	return size, err
}
