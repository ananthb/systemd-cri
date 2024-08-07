package crisvc

import (
	"context"
	"os"
	"path/filepath"

	"github.com/containers/image/v5/copy"
	"github.com/containers/image/v5/directory"
	"github.com/containers/image/v5/signature"
	"github.com/containers/image/v5/transports/alltransports"
	runtimeapi "k8s.io/cri-api/pkg/apis/runtime/v1"
)

func (i *criService) ListImages(
	ctx context.Context,
	req *runtimeapi.ListImagesRequest,
) (*runtimeapi.ListImagesResponse, error) {
	dis, err := os.ReadDir(i.imagesDir())
	if err != nil {
		return nil, err
	}

	images := make([]*runtimeapi.Image, 0, len(dis))
	for _, di := range dis {
		if !di.IsDir() {
			continue
		}

		image, err := directory.NewReference(filepath.Join(i.imagesDir(), di.Name()))
		if err != nil {
			return nil, err
		}

		images = append(images, &runtimeapi.Image{
			Id:          image.DockerReference().String(),
			RepoTags:    []string{image.DockerReference().String()},
			RepoDigests: []string{image.DockerReference().String()},
			Size_:       0,
		})
	}

	return &runtimeapi.ListImagesResponse{
		Images: images,
	}, nil
}

func (i *criService) ImageStatus(
	context.Context,
	*runtimeapi.ImageStatusRequest,
) (*runtimeapi.ImageStatusResponse, error) {
	return nil, nil
}

func (i *criService) PullImage(
	ctx context.Context,
	req *runtimeapi.PullImageRequest,
) (*runtimeapi.PullImageResponse, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	policyContext, err := signature.NewPolicyContext(&signature.Policy{
		Default: []signature.PolicyRequirement{signature.NewPRInsecureAcceptAnything()},
	})
	if err != nil {
		return nil, err
	}

	srcRef, err := alltransports.ParseImageName(req.Image.GetImage())
	if err != nil {
		return nil, err
	}

	destDir := i.imageDir(srcRef.DockerReference().String())

	dir, err := directory.NewReference(destDir)
	if err != nil {
		return nil, err
	}

	options := &copy.Options{}
	if _, err := copy.Image(ctx, policyContext, dir, srcRef, options); err != nil {
		return nil, err
	}

	response := &runtimeapi.PullImageResponse{
		ImageRef: dir.DockerReference().String(),
	}
	return response, nil
}

func (i *criService) RemoveImage(
	context.Context,
	*runtimeapi.RemoveImageRequest,
) (*runtimeapi.RemoveImageResponse, error) {
	return nil, nil
}

func (i *criService) ImageFsInfo(
	context.Context,
	*runtimeapi.ImageFsInfoRequest,
) (*runtimeapi.ImageFsInfoResponse, error) {
	return nil, nil
}

func (c *criService) imagesDir() string {
	return filepath.Join(c.stateDir, "images")
}

func (c *criService) imageDir(imageName string) string {
	return filepath.Join(c.imagesDir(), imageName)
}
