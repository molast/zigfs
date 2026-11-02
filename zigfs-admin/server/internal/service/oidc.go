package service

import (
	"context"
	"encoding/json"
)

func (service *Management) OIDCProviders(ctx context.Context, method, id string, body json.RawMessage) (json.RawMessage, error) {
	return service.zig.OIDCProviders(ctx, method, id, body)
}

func (service *Management) OIDCAuth(ctx context.Context, method, operation string, body json.RawMessage) (json.RawMessage, error) {
	return service.zig.OIDCAuth(ctx, method, operation, body)
}
