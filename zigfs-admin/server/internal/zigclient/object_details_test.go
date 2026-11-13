package zigclient_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"zigfs-admin/server/internal/contract"
	"zigfs-admin/server/internal/managementauth"
	"zigfs-admin/server/internal/zigclient"
)

func TestObjectLegalHoldPreservesNullVersionAndFalse(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPatch || r.URL.Path != "/_admin/v1/buckets/photos/legal-hold" || r.Header.Get("Authorization") != "Bearer session-token" {
			t.Errorf("unexpected forwarding: %s %s", r.Method, r.URL.Path)
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if body["key"] != "photos/a.png" || body["version_id"] != "null" || body["enabled"] != false {
			t.Errorf("unexpected body: %v", body)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"key":"photos/a.png","version_id":"null","legal_hold":false}`))
	}))
	defer server.Close()
	client := zigclient.New(server.URL, time.Second)
	result, err := client.SetObjectLegalHold(managementauth.WithToken(context.Background(), "session-token"), "photos", contract.SetObjectLegalHoldRequest{Key: "photos/a.png", VersionID: "null", Enabled: false})
	if err != nil || result.VersionID != "null" || result.LegalHold {
		t.Fatalf("result=%+v err=%v", result, err)
	}
}
