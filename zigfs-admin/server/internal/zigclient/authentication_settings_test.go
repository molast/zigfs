package zigclient_test

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"zigfs-admin/server/internal/managementauth"
	"zigfs-admin/server/internal/port"
	"zigfs-admin/server/internal/zigclient"
)

func TestAuthenticationSettingsForwarding(t *testing.T) {
	for _, method := range []string{http.MethodGet, http.MethodPut} {
		t.Run(method, func(t *testing.T) {
			response := `{"current":{"admin_session_ttl_seconds":28800,"request_time_skew_seconds":900},"pending":{"admin_session_ttl_seconds":3600,"request_time_skew_seconds":60},"restart_required":true}`
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != method || r.URL.Path != "/_admin/v1/settings/authentication" || r.Header.Get("Authorization") != "Bearer session-token" {
					t.Errorf("incorrect forwarding: %s %s", r.Method, r.URL.Path)
				}
				if method == http.MethodPut {
					var value map[string]int
					if err := json.NewDecoder(r.Body).Decode(&value); err != nil || value["admin_session_ttl_seconds"] != 3600 || value["request_time_skew_seconds"] != 60 {
						t.Errorf("incorrect body: %v %v", value, err)
					}
				}
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write([]byte(response))
			}))
			defer server.Close()
			var input json.RawMessage
			if method == http.MethodPut {
				input = json.RawMessage(`{"admin_session_ttl_seconds":3600,"request_time_skew_seconds":60}`)
			}
			result, err := zigclient.New(server.URL, time.Second).AuthenticationSettings(managementauth.WithToken(context.Background(), "session-token"), method, input)
			if err != nil || string(result) != response {
				t.Fatalf("response not preserved: %s %v", result, err)
			}
		})
	}
}

func TestAuthenticationSettingsPreservesValidationCode(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"code":"InvalidSessionLifetime","message":"invalid lifetime","request_id":"auth-validation"}`))
	}))
	defer server.Close()
	_, err := zigclient.New(server.URL, time.Second).AuthenticationSettings(context.Background(), http.MethodPut, json.RawMessage(`{"admin_session_ttl_seconds":0,"request_time_skew_seconds":0}`))
	var status *port.StatusError
	if !errors.As(err, &status) || status.Code != "InvalidSessionLifetime" || status.StatusCode != 400 || status.RequestID != "auth-validation" {
		t.Fatalf("validation error not preserved: %v", err)
	}
}
