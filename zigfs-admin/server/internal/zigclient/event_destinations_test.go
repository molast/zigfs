package zigclient_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
	"zigfs-admin/server/internal/managementauth"
	"zigfs-admin/server/internal/zigclient"
)

func TestEventDestinationsForwarding(t *testing.T) {
	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Header.Get("Authorization") != "Bearer destination-session" {
			t.Error("missing user session")
		}
		expected := "/_admin/v1/event-destinations"
		if r.Method == http.MethodPut || r.Method == http.MethodDelete {
			expected += "/WEBHOOK_1"
		}
		if r.URL.Path != expected {
			t.Errorf("path: %s", r.URL.Path)
		}
		if r.Method == http.MethodPut || r.Method == http.MethodPost {
			var body map[string]any
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body["auth_token"] != "test-token" || body["skip_tls_verify"] != false {
				t.Error("configuration not forwarded")
			}
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"items":[],"auth_token":"","has_auth_token":true}`))
	}))
	defer server.Close()
	client := zigclient.New(server.URL, time.Second)
	ctx := managementauth.WithToken(context.Background(), "destination-session")
	for _, method := range []string{http.MethodGet, http.MethodPost, http.MethodPut, http.MethodDelete} {
		name := ""
		if method == http.MethodPut || method == http.MethodDelete {
			name = "WEBHOOK_1"
		}
		var body json.RawMessage
		if method == http.MethodPut || method == http.MethodPost {
			body = json.RawMessage(`{"name":"WEBHOOK_1","endpoint":"https://example.test/events","auth_token":"test-token","skip_tls_verify":false}`)
		}
		got, err := client.EventDestinations(ctx, method, name, body)
		if err != nil || !json.Valid(got) || strings.Contains(string(got), "test-token") {
			t.Fatalf("%s: %s %v", method, got, err)
		}
	}
	if calls != 4 {
		t.Fatalf("calls: %d", calls)
	}
}
