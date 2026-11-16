package zigclient_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"zigfs-admin/server/internal/zigclient"
)

func TestSessionPreservesNullableAccountStatus(t *testing.T) {
	for _, value := range []string{"true", "false", "null"} {
		t.Run(value, func(t *testing.T) {
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/_admin/v1/auth/session" {
					t.Errorf("unexpected path: %s", r.URL.Path)
				}
				w.Header().Set("Content-Type", "application/json")
				w.Write([]byte(`{"authenticated":true,"username":"alice","account_enabled":` + value + `}`))
			}))
			defer upstream.Close()
			response, err := zigclient.New(upstream.URL, time.Second).Session(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			if value == "null" {
				if response.AccountEnabled != nil {
					t.Fatal("unknown became enabled/disabled")
				}
			} else if response.AccountEnabled == nil || *response.AccountEnabled != (value == "true") {
				t.Fatalf("lost account state: %+v", response.AccountEnabled)
			}
		})
	}
}
