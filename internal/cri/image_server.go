package cri

import (
	"context"
	"fmt"

	"k8s.io/cri-api/pkg/apis/runtime/v1"
)

type ImageServer struct {
	v1.UnimplementedImageServiceServer
}

func NewImageServer() *ImageServer {
	return &ImageServer{}
}

func (s *ImageServer) ListImages(ctx context.Context, req *v1.ListImagesRequest) (*v1.ListImagesResponse, error) {
	return &v1.ListImagesResponse{}, nil
}

func (s *ImageServer) ImageStatus(ctx context.Context, req *v1.ImageStatusRequest) (*v1.ImageStatusResponse, error) {
	return &v1.ImageStatusResponse{}, nil
}

func (s *ImageServer) PullImage(ctx context.Context, req *v1.PullImageRequest) (*v1.PullImageResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *ImageServer) RemoveImage(ctx context.Context, req *v1.RemoveImageRequest) (*v1.RemoveImageResponse, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *ImageServer) ImageFsInfo(ctx context.Context, req *v1.ImageFsInfoRequest) (*v1.ImageFsInfoResponse, error) {
	return &v1.ImageFsInfoResponse{}, nil
}
