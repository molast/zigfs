package zigclient_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"zigfs-admin/server/internal/zigclient"
)

func TestSystem(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/_admin/v1/system" {
			t.Fatalf("unexpected path %q", request.URL.Path)
		}
		if request.Header.Get("Authorization") != "Bearer internal-token" {
			t.Fatal("missing internal admin token")
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"version":"0.1.0","uptime":10,"storage_used":20,"objects":3,"buckets":2}`))
	}))
	defer server.Close()

	client := zigclient.New(server.URL, "internal-token", time.Second)
	response, err := client.System(context.Background())
	if err != nil {
		t.Fatalf("system request failed: %v", err)
	}
	if response.Version != "0.1.0" || response.Objects != 3 {
		t.Fatalf("unexpected response: %+v", response)
	}
}
