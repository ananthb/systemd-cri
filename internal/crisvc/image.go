package crisvc

import (
	"context"

	"github.com/containers/image/v5/copy"
	"github.com/containers/image/v5/signature"
	"github.com/containers/image/v5/transports/alltransports"
	runtimeapi "k8s.io/cri-api/pkg/apis/runtime/v1"
)

func (i *criService) ListImages(
	context.Context,
	*runtimeapi.ListImagesRequest,
) (*runtimeapi.ListImagesResponse, error) {
	return nil, nil
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
