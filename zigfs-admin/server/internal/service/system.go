package service

import (
	"context"

	"zigfs-admin/server/internal/contract"
	"zigfs-admin/server/internal/port"
)

type System struct {
	zig port.ZigClient
}

func NewSystem(zig port.ZigClient) *System {
	return &System{zig: zig}
}

func (service *System) Ready(ctx context.Context) error {
	return service.zig.Ready(ctx)
}

func (service *System) Get(ctx context.Context) (contract.SystemResponse, error) {
	return service.zig.System(ctx)
}
