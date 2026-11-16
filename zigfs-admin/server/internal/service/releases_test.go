package service

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestReleaseChecks(t *testing.T) {
	for _, tc := range []struct {
		name, current, body string
		status              int
		newer, wantError    bool
	}{
		{"numeric version order", "0.9.0", `{"tag_name":"v0.10.0"}`, 200, true, false},
		{"same", "0.1.0", `{"tag_name":"v0.1.0"}`, 200, false, false},
		{"local newer", "1.1.0", `{"tag_name":"v1.0.0"}`, 200, false, false},
		{"prerelease to stable", "1.0.0-rc.1", `{"tag_name":"v1.0.0"}`, 200, true, false},
		{"missing release", "0.1.0", `{}`, 404, false, true},
		{"rate limited", "0.1.0", `{}`, 403, false, true},
		{"invalid tag", "0.1.0", `{"tag_name":"nightly"}`, 200, false, true},
		{"draft", "0.1.0", `{"tag_name":"v1.0.0","draft":true}`, 200, false, true},
		{"prerelease", "0.1.0", `{"tag_name":"v1.0.0-rc.1"}`, 200, false, true},
		{"invalid JSON", "0.1.0", `<html>error</html>`, 200, false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Authorization") != "Bearer test-token" {
					t.Error("missing server-side release token")
				}
				w.WriteHeader(tc.status)
				w.Write([]byte(tc.body))
			}))
			defer server.Close()
			result, err := CheckRelease(context.Background(), tc.current, server.Client(), server.URL, "test-token")
			if (err != nil) != tc.wantError {
				t.Fatalf("error = %v", err)
			}
			if err == nil && (result.UpdateAvailable != tc.newer || result.CheckedAt == 0) {
				t.Fatalf("result = %+v", result)
			}
		})
	}
}

func TestReleaseQueryHonorsCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := CheckRelease(ctx, "0.1.0", nil, "https://api.github.com/repos/molast/zigfs/releases/latest", "")
	if err == nil {
		t.Fatal("canceled query succeeded")
	}
}
