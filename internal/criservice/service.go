package criservice

import (
	runtimeapi "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type CRIService interface {
	runtimeapi.RuntimeServiceServer
	runtimeapi.ImageServiceServer
}
