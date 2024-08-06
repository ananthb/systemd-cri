package crisvc

import (
	runtimeapi "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type CRIService interface {
	runtimeapi.RuntimeServiceServer
	runtimeapi.ImageServiceServer
}

func New() (CRIService, error) {
	return &criService{}, nil
}
