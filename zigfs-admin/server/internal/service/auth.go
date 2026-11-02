package service

import (
	"context"
	"encoding/json"
	"strings"
	"zigfs-admin/server/internal/managementauth"

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

func (service *Auth) Logout(ctx context.Context) error {
	token := managementauth.Token(ctx)
	if !strings.HasPrefix(token, "o1.") {
		return nil
	}
	body, _ := json.Marshal(map[string]string{"token": token})
	_, err := service.zig.OIDCAuth(ctx, "POST", "logout", body)
	return err
}
