package machineman

import (
	"context"

	"github.com/containers/image/v5/copy"
	"github.com/containers/image/v5/signature"
	"github.com/containers/image/v5/transports/alltransports"
	runtimeapi "k8s.io/cri-api/pkg/apis/runtime/v1"
)

func NewImageService() (runtimeapi.ImageServiceServer, error) {
	return &ImageService{}, nil
}

// ImageService implements RuntimeService and ImageService.
type ImageService struct {
	imageClient runtimeapi.ImageServiceClient
}

func (i *ImageService) ListImages(
	context.Context,
	*runtimeapi.ListImagesRequest,
) (*runtimeapi.ListImagesResponse, error) {
	return nil, nil
}

func (i *ImageService) ImageStatus(
	context.Context,
	*runtimeapi.ImageStatusRequest,
) (*runtimeapi.ImageStatusResponse, error) {
	return nil, nil
}

func (i *ImageService) PullImage(
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
	destRef, err := alltransports.ParseImageName("docker://localhost:5000/alpine:latest")
	if err != nil {
		return nil, err
	}
	options := &copy.Options{}
	if _, err := copy.Image(ctx, policyContext, destRef, srcRef, options); err != nil {
		return nil, err
	}
	response := &runtimeapi.PullImageResponse{
		ImageRef: destRef.DockerReference().String(),
	}
	return response, nil
}

func (i *ImageService) RemoveImage(
	context.Context,
	*runtimeapi.RemoveImageRequest,
) (*runtimeapi.RemoveImageResponse, error) {
	return nil, nil
}

func (i *ImageService) ImageFsInfo(
	context.Context,
	*runtimeapi.ImageFsInfoRequest,
) (*runtimeapi.ImageFsInfoResponse, error) {
	return nil, nil
}
