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

func TestDisplayPreferencesForwardingAndSession(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer session-token" {
			t.Error("missing session")
		}
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/_admin/v1/settings/display":
			if r.Method == http.MethodPut {
				var value map[string]string
				if err := json.NewDecoder(r.Body).Decode(&value); err != nil || value["timezone"] != "Asia/Shanghai" || value["date_format"] != "ymd" {
					t.Errorf("invalid forwarded body: %v %v", value, err)
				}
			}
			_, _ = w.Write([]byte(`{"timezone":"Asia/Shanghai","date_format":"ymd","supported_timezones":["browser","UTC","Asia/Shanghai"]}`))
		case "/_admin/v1/auth/session":
			_, _ = w.Write([]byte(`{"authenticated":true,"username":"reader","expires_at":1900000000,"auth_source":"sts","root_access_key":null,"session_access_key":"TestSessionKey12345","display_preferences":{"timezone":"Asia/Shanghai","date_format":"ymd"}}`))
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
		}
	}))
	defer server.Close()
	client := zigclient.New(server.URL, time.Second)
	ctx := managementauth.WithToken(context.Background(), "session-token")
	for _, method := range []string{http.MethodGet, http.MethodPut} {
		var input json.RawMessage
		if method == http.MethodPut {
			input = json.RawMessage(`{"timezone":"Asia/Shanghai","date_format":"ymd"}`)
		}
		result, err := client.DisplaySettings(ctx, method, input)
		if err != nil || !json.Valid(result) {
			t.Fatalf("display preferences failed: %s %v", result, err)
		}
	}
	session, err := client.Session(ctx)
	if err != nil || session.AuthSource != "sts" || session.RootAccessKey != nil || session.SessionAccessKey == nil || *session.SessionAccessKey != "TestSessionKey12345" || session.DisplayPreferences == nil || session.DisplayPreferences.Timezone != "Asia/Shanghai" || session.DisplayPreferences.DateFormat != "ymd" {
		t.Fatalf("session dropped display preferences: %+v %v", session, err)
	}
}
