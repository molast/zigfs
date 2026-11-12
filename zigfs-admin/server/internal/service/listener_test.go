package service

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"zigfs-admin/server/internal/config"
	"zigfs-admin/server/internal/contract"
	"zigfs-admin/server/internal/port"
)

type listenerMock struct {
	port.ZigClient
	settingsError error
	saveError     error
	saved         string
}

func (m *listenerMock) Settings(context.Context) (contract.SettingsResponse, error) {
	return contract.SettingsResponse{}, m.settingsError
}
func (m *listenerMock) SaveListenerSettings(_ context.Context, address string) error {
	m.saved = address
	return m.saveError
}
func TestListenerSaveGuardsAndRollback(t *testing.T) {
	path := filepath.Join(t.TempDir(), "listener.json")
	mock := &listenerMock{settingsError: &port.StatusError{StatusCode: 403}}
	service := NewManagement(mock)
	service.ListenerFile = path
	service.AdminListenAddress = "127.0.0.1:9001"
	service.Endpoint = func() string { return "http://127.0.0.1:9000" }
	var candidates []string
	service.SetEndpoints = func(v []string) { candidates = v }
	input := contract.ListenerSettings{APIAddress: "127.0.0.1:19000", AdminListenAddress: service.AdminListenAddress, UpstreamEndpoint: "http://127.0.0.1:19000"}
	if err := service.SaveListeners(context.Background(), input); err == nil {
		t.Fatal("authorization bypass")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("unauthorized local write")
	}
	mock.settingsError = nil
	mock.saveError = &port.StatusError{StatusCode: 409}
	if err := service.SaveListeners(context.Background(), input); err == nil {
		t.Fatal("expected port rejection")
	}
	restored, err := config.ReadListenerState(path)
	if err != nil || len(restored.Endpoints) != 1 || restored.Endpoints[0] != service.Endpoint() {
		t.Fatalf("%+v %v", restored, err)
	}
	mock.saveError = nil
	if err := service.SaveListeners(context.Background(), input); err != nil {
		t.Fatal(err)
	}
	saved, err := config.ReadListenerState(path)
	if err != nil || len(saved.Endpoints) != 2 || len(candidates) != 2 {
		t.Fatalf("%+v %v", saved, err)
	}
}
