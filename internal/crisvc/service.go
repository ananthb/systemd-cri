package crisvc

import (
	runtimeapi "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type CRIService interface {
	runtimeapi.RuntimeServiceServer
	runtimeapi.ImageServiceServer
}

func New(stateDir string) (CRIService, error) {
	return &criService{
		stateDir: stateDir,
	}, nil
}
