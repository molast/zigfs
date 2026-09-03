package service

import (
	"context"

	"zigfs-admin/server/internal/contract"
	"zigfs-admin/server/internal/port"
)

type Auth struct {
	zig port.ZigClient
}

func NewAuth(zig port.ZigClient) *Auth {
	return &Auth{zig: zig}
}

func (service *Auth) Login(ctx context.Context, request contract.LoginRequest) (contract.LoginResponse, error) {
	return service.zig.Login(ctx, request)
}

func (service *Auth) Session(ctx context.Context) (contract.SessionResponse, error) {
	return service.zig.Session(ctx)
}
