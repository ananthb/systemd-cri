package cri

import (
	"context"
	"fmt"
	"os"

	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/crane"
	v1 "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/empty"
	"github.com/google/go-containerregistry/pkg/v1/layout"
	"github.com/google/go-containerregistry/pkg/v1/mutate"
	"github.com/google/go-containerregistry/pkg/v1/partial"
	"github.com/opencontainers/umoci"
	"github.com/opencontainers/umoci/oci/layer"
)

func pullImageNative(ctx context.Context, ref string, auth *authn.AuthConfig, destDir string) (v1.Image, error) {
	opts := []crane.Option{crane.WithContext(ctx)}
	if auth != nil && auth.Username != "" {
		opts = append(opts, crane.WithAuth(authn.FromConfig(*auth)))
	}

	img, err := crane.Pull(ref, opts...)
	if err != nil {
		return nil, fmt.Errorf("failed to pull image: %w", err)
	}

	// Save to OCI layout
	if err := os.MkdirAll(destDir, 0755); err != nil {
		return nil, err
	}

	desc, err := partial.Descriptor(img)
	if err != nil {
		return nil, fmt.Errorf("failed to get descriptor: %w", err)
	}
	if desc.Annotations == nil {
		desc.Annotations = make(map[string]string)
	}
	desc.Annotations["org.opencontainers.image.ref.name"] = "latest"

	// layout.Write requires an ImageIndex. We wrap the image in an index.
	idx := mutate.AppendManifests(empty.Index, mutate.IndexAddendum{
		Add:        img,
		Descriptor: *desc,
	})

	_, err = layout.Write(destDir, idx)
	if err != nil {
		// If it already exists, we might need to append.
		l, err := layout.FromPath(destDir)
		if err != nil {
			return nil, fmt.Errorf("failed to write OCI layout: %w", err)
		}
		if err := l.AppendImage(img); err != nil {
			return nil, fmt.Errorf("failed to append to OCI layout: %w", err)
		}
	}

	return img, nil
}

func unpackImageNative(ctx context.Context, ociDir string, bundlePath string) error {
	engine, err := umoci.OpenLayout(ociDir)
	if err != nil {
		return fmt.Errorf("failed to open OCI layout: %w", err)
	}
	defer func() { _ = engine.Close() }()

	tagName := "latest"

	// Umoci v0.6.0 uses MapOptions directly in UnpackOptions for rootless
	unpackOptions := layer.UnpackOptions{
		KeepDirlinks: true,
	}

	// For rootless, we need to set up the mapping.
	// In a simple case without full user namespace support implemented yet,
	// we just try to unpack.

	return umoci.Unpack(engine, tagName, bundlePath, unpackOptions)
}
