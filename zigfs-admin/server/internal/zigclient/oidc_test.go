package zigclient_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
	"zigfs-admin/server/internal/managementauth"
	"zigfs-admin/server/internal/zigclient"
)

func TestOIDCProviderDelegatesIdentityAndPreservesBlankSecret(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "PATCH" || r.URL.Path != "/_admin/v1/oidc/providers/keycloak" {
			t.Errorf("unexpected route %s %s", r.Method, r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer caller-session" {
			t.Error("caller identity not delegated")
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if body["client_secret"] != "" {
			t.Error("blank secret must be forwarded for preservation")
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"provider_id":"keycloak","client_secret":"","has_secret":true}`))
	}))
	defer server.Close()
	client := zigclient.New(server.URL, time.Second)
	response, err := client.OIDCProviders(managementauth.WithToken(context.Background(), "caller-session"), "PATCH", "keycloak", json.RawMessage(`{"provider_id":"keycloak","client_secret":""}`))
	if err != nil {
		t.Fatal(err)
	}
	var result map[string]any
	if err := json.Unmarshal(response, &result); err != nil {
		t.Fatal(err)
	}
	if result["has_secret"] != true || result["client_secret"] != "" {
		t.Fatal("unexpected secret response")
	}
}
