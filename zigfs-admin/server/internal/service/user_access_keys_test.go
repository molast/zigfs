package service_test

import (
	"context"
	"testing"
	"zigfs-admin/server/internal/contract"
	"zigfs-admin/server/internal/port"
	"zigfs-admin/server/internal/service"
)

type userKeysClient struct {
	port.ZigClient
	name    string
	request contract.CreateAccessKeyRequest
}

func (client *userKeysClient) CreateUserAccessKey(_ context.Context, name string, request contract.CreateAccessKeyRequest) (contract.CreateAccessKeyResponse, error) {
	client.name, client.request = name, request
	return contract.CreateAccessKeyResponse{}, nil
}
func TestUserAccessKeyOwnerCannotOverridePath(t *testing.T) {
	client := &userKeysClient{}
	ttl := int64(120)
	_, err := service.NewManagement(client).CreateUserAccessKey(context.Background(), "alice", contract.CreateAccessKeyRequest{Owner: "user:bob", TTLSeconds: &ttl})
	if err != nil {
		t.Fatal(err)
	}
	if client.name != "alice" || client.request.Owner != "" || *client.request.TTLSeconds != 120 {
		t.Fatalf("unexpected forwarded request: %+v", client)
	}
}
