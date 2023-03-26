package main

import (
	"fmt"
	"log"
	"net"

	"github.com/ananthb/systemd-cri/internal/machineman"
	"google.golang.org/grpc"
	runtimeapi "k8s.io/cri-api/pkg/apis/runtime/v1"
)

func main() {
	listener, err := net.Listen("tcp", fmt.Sprintf(":%d", 8080))
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}
	s := grpc.NewServer()
	imagesvc, err := machineman.NewImageService()
	if err != nil {
		log.Fatalf("failed to create image service: %v", err)
	}
	runtimesvc, err := machineman.NewRuntimeService()
	if err != nil {
		log.Fatalf("failed to create runtime service: %v", err)
	}
	runtimeapi.RegisterImageServiceServer(s, imagesvc)
	runtimeapi.RegisterRuntimeServiceServer(s, runtimesvc)
	if err := s.Serve(listener); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}
