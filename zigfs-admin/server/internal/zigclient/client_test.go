package zigclient_test

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"zigfs-admin/server/internal/contract"
	"zigfs-admin/server/internal/managementauth"
	"zigfs-admin/server/internal/port"
	"zigfs-admin/server/internal/zigclient"
)

func TestPresignObjectForwardsCopySourceContract(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/_admin/v1/objects/presign" || request.Method != http.MethodPost {
			t.Fatalf("unexpected request %s %q", request.Method, request.URL.Path)
		}
		var body contract.PresignObjectRequest
		if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
			t.Fatalf("decode request: %v", err)
		}
		if body.CopySourceBucket != "versions" || body.CopySourceKey != "release.txt" || body.CopySourceVersionID != "version-1" {
			t.Fatalf("copy source was not forwarded: %+v", body)
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"url":"http://s3.example/versions/release.txt?signature=test","expires_at":"2026-09-08T08:00:00Z","required_headers":{"x-amz-copy-source":"/versions/release.txt?versionId=version-1"}}`))
	}))
	defer server.Close()

	client := zigclient.New(server.URL, time.Second)
	response, err := client.PresignObject(context.Background(), contract.PresignObjectRequest{
		AccessKey:           "test-key",
		Bucket:              "versions",
		Key:                 "release.txt",
		Method:              http.MethodPut,
		ExpiresSecond:       60,
		CopySourceBucket:    "versions",
		CopySourceKey:       "release.txt",
		CopySourceVersionID: "version-1",
	})
	if err != nil {
		t.Fatalf("presign request failed: %v", err)
	}
	if response.RequiredHeaders["x-amz-copy-source"] != "/versions/release.txt?versionId=version-1" {
		t.Fatalf("required headers were not preserved: %+v", response.RequiredHeaders)
	}
}

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

	client := zigclient.New(server.URL, time.Second)
	ctx := managementauth.WithToken(context.Background(), "internal-token")
	response, err := client.System(ctx)
	if err != nil {
		t.Fatalf("system request failed: %v", err)
	}
	if response.Version != "0.1.0" || response.Objects != 3 {
		t.Fatalf("unexpected response: %+v", response)
	}
}

func TestListBucketEventsForwardsFilters(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/_admin/v1/buckets/project-assets/events" || request.URL.Query().Get("cursor") != "5" || request.URL.Query().Get("from") != "100" || request.URL.Query().Get("to") != "200" || request.URL.Query().Get("action") != "update" || request.URL.Query().Get("outcome") != "ok" || request.URL.Query().Get("limit") != "25" {
			t.Fatalf("unexpected events query: %s", request.URL.String())
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"items":[],"next_cursor":"6"}`))
	}))
	defer server.Close()

	client := zigclient.New(server.URL, time.Second)
	response, err := client.ListBucketEvents(context.Background(), "project-assets", "5", "100", "200", "update", "ok", 25)
	if err != nil {
		t.Fatalf("events request failed: %v", err)
	}
	if response.NextCursor != "6" {
		t.Fatalf("unexpected response: %+v", response)
	}
}

func TestPreservesZigFSErrorContract(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		writer.WriteHeader(http.StatusConflict)
		_, _ = writer.Write([]byte(`{"code":"BucketNotEmpty","message":"bucket is not empty","request_id":"zig-request","details":{}}`))
	}))
	defer server.Close()

	client := zigclient.New(server.URL, time.Second)
	err := client.DeleteBucket(context.Background(), "project-assets")
	var statusError *port.StatusError
	if !errors.As(err, &statusError) {
		t.Fatalf("expected StatusError, got %v", err)
	}
	if statusError.StatusCode != http.StatusConflict || statusError.Code != "BucketNotEmpty" || statusError.RequestID != "zig-request" {
		t.Fatalf("unexpected status error: %+v", statusError)
	}
}

func TestGroupForwardingPreservesAssignmentsAndUpstreamConflict(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/_admin/v1/groups/team" || r.Header.Get("Authorization") != "Bearer test-token" {
			t.Errorf("unexpected forwarding: %s", r.URL.Path)
		}
		if r.Method == http.MethodDelete {
			w.WriteHeader(http.StatusConflict)
			_, _ = w.Write([]byte(`{"code":"Conflict","message":"retry"}`))
			return
		}
		var group contract.ManagedGroup
		if err := json.NewDecoder(r.Body).Decode(&group); err != nil {
			t.Error(err)
		}
		if group.Enabled || len(group.Members) != 1 || group.Members[0] != "alice" || len(group.Policies) != 1 {
			t.Errorf("lost fields: %+v", group)
		}
		_ = json.NewEncoder(w).Encode(group)
	}))
	defer server.Close()
	client := zigclient.New(server.URL, time.Second)
	ctx := managementauth.WithToken(context.Background(), "test-token")
	saved, err := client.UpdateGroup(ctx, contract.ManagedGroup{Name: "team", Enabled: false, Members: []string{"alice"}, Policies: []string{"readonly"}})
	if err != nil || saved.Name != "team" {
		t.Fatalf("update: %+v %v", saved, err)
	}
	var upstream *port.StatusError
	if err := client.DeleteGroup(ctx, "team"); !errors.As(err, &upstream) || upstream.StatusCode != http.StatusConflict {
		t.Fatalf("expected conflict: %v", err)
	}
}

func TestUserWriteForwardsPasswordAndEmptyGroupsWithoutExposingSecrets(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/_admin/v1/users/alice" || r.Method != http.MethodPatch {
			t.Errorf("unexpected route: %s", r.URL.Path)
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Error(err)
		}
		if body["password"] != "test-password" {
			t.Error("password not forwarded")
		}
		groups, ok := body["groups"].([]any)
		if !ok || len(groups) != 0 {
			t.Error("explicit empty groups must be preserved")
		}
		if _, ok := body["updated_at"]; ok {
			t.Error("client cannot set update time")
		}
		_, _ = w.Write([]byte(`{"name":"alice","enabled":true,"policies":[],"groups":[],"updated_at":123}`))
	}))
	defer server.Close()
	password := "test-password"
	groups := []string{}
	value, err := zigclient.New(server.URL, time.Second).UpdateUser(context.Background(), contract.UserWrite{Name: "alice", Enabled: true, Policies: []string{}, Password: &password, Groups: &groups})
	if err != nil || value.UpdatedAt != 123 {
		t.Fatalf("update: %+v %v", value, err)
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	var body map[string]any
	_ = json.Unmarshal(encoded, &body)
	if _, ok := body["password"]; ok {
		t.Error("password appeared in response")
	}
}

func TestDirectoryDeletionOptions(t *testing.T) {
	for _, mode := range []string{"current", "all", "cleanup"} {
		t.Run(mode, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if mode == "cleanup" {
					if r.Method != http.MethodPost || r.URL.Path != "/_admin/v1/buckets/photos/directories/cleanup" {
						t.Errorf("unexpected cleanup route: %s %s", r.Method, r.URL)
					}
					var body contract.DeleteDirectoryRequest
					if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Key != "nested/a b/" {
						t.Errorf("invalid cleanup payload: %+v, %v", body, err)
					}
				} else {
					if r.Method != http.MethodDelete || r.URL.Path != "/_admin/v1/buckets/photos/directories" || r.URL.Query().Get("key") != "nested/a b/" {
						t.Errorf("invalid delete request: %s %s", r.Method, r.URL)
					}
					if (r.URL.Query().Get("all_versions") == "true") != (mode == "all") {
						t.Errorf("all_versions not forwarded: %s", r.URL)
					}
				}
				w.WriteHeader(http.StatusNoContent)
			}))
			defer server.Close()
			client := zigclient.New(server.URL, time.Second)
			if err := client.DeleteDirectory(context.Background(), "photos", contract.DeleteDirectoryRequest{Key: "nested/a b/", AllVersions: mode == "all", ForceCleanup: mode == "cleanup"}); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestKMSConfigurationRoundTripAndUpstreamFailure(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/_admin/v1/settings/kms" {
			t.Errorf("unexpected path %s", r.URL.Path)
		}
		if r.Method == http.MethodPut {
			var config contract.KMSConfig
			if err := json.NewDecoder(r.Body).Decode(&config); err != nil {
				t.Error(err)
			}
			if config.Backend == "vault" {
				w.WriteHeader(http.StatusServiceUnavailable)
				_, _ = w.Write([]byte(`{"code":"KmsUnavailable","message":"KMS unavailable"}`))
				return
			}
			if config.StaticSecretKey != "secret" {
				t.Error("secret was not forwarded")
			}
		}
		_ = json.NewEncoder(w).Encode(contract.KMSStatus{Configured: true, Healthy: true, Config: contract.KMSConfig{Backend: "static"}, StaticSecretKeyConfigured: true})
	}))
	defer server.Close()
	client := zigclient.New(server.URL, time.Second)
	status, err := client.SaveKMSSettings(context.Background(), contract.KMSConfig{Backend: "static", StaticSecretKey: "secret"})
	if err != nil || !status.Configured || !status.Healthy || status.Config.StaticSecretKey != "" {
		t.Fatalf("unexpected status %+v: %v", status, err)
	}
	if _, err := client.KMSSettings(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := client.SaveKMSSettings(context.Background(), contract.KMSConfig{Backend: "vault"}); err == nil {
		t.Fatal("upstream failure was swallowed")
	}
}

func TestKMSKeyManagementForwardsRequestAndProviderError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/_admin/v1/settings/kms/keys/action" || r.Method != http.MethodPost {
			t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		var input struct {
			ID     string `json:"id"`
			Action string `json:"action"`
		}
		if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
			t.Error(err)
		}
		if input.ID != "key-1" {
			t.Errorf("unexpected ID %s", input.ID)
		}
		if input.Action == "delete" {
			w.WriteHeader(http.StatusConflict)
			_, _ = w.Write([]byte(`{"code":"KmsKeyDeletionNotScheduled","message":"Schedule deletion first"}`))
			return
		}
		if input.Action != "rotate" {
			t.Errorf("unexpected action %s", input.Action)
		}
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer server.Close()
	client := zigclient.New(server.URL, time.Second)
	result, err := client.KMSKeys(context.Background(), http.MethodPost, true, json.RawMessage(`{"id":"key-1","action":"rotate"}`))
	if err != nil || string(result) != `{"ok":true}` {
		t.Fatalf("unexpected result %s: %v", result, err)
	}
	if _, err = client.KMSKeys(context.Background(), http.MethodPost, true, json.RawMessage(`{"id":"key-1","action":"delete"}`)); err == nil {
		t.Fatal("provider failure swallowed")
	}
}

func TestLogSettingsForwardingAndDownloadDenial(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/_admin/v1/settings/logs/query" {
			if r.URL.Query().Get("from") != "100" || r.URL.Query().Get("to") != "200" {
				t.Errorf("lost time range: %s", r.URL)
			}
			_, _ = w.Write([]byte(`{"content":"","truncated":false,"range":"24h"}`))
			return
		}
		if r.URL.Path == "/_admin/v1/settings/logs/download" {
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"code":"LogDownloadsDisabled","message":"Log downloads are disabled."}`))
			return
		}
		if r.URL.Path != "/_admin/v1/settings/logs" {
			t.Errorf("unexpected path %s", r.URL.Path)
		}
		if r.Method == http.MethodPut {
			var input map[string]string
			if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
				t.Fatal(err)
			}
			if input["directory"] != "logs/custom" || input["retention"] != "forever" {
				t.Errorf("lost log settings: %v", input)
			}
		}
		_, _ = w.Write([]byte(`{"directory":"logs/custom","retention":"forever"}`))
	}))
	defer server.Close()
	client := zigclient.New(server.URL, time.Second)
	for _, method := range []string{http.MethodGet, http.MethodPut} {
		var input json.RawMessage
		if method == http.MethodPut {
			input = json.RawMessage(`{"directory":"logs/custom","retention":"forever"}`)
		}
		if _, err := client.LogSettings(context.Background(), method, "", input); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := client.LogSettings(context.Background(), http.MethodGet, "query?from=100&to=200", nil); err != nil {
		t.Fatal(err)
	}
	if _, err := client.LogSettings(context.Background(), http.MethodGet, "download", nil); err == nil {
		t.Fatal("download denial swallowed")
	}
}

func TestGlobalAuditEventsForwardFilters(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/_admin/v1/audit-events" || r.URL.Query().Get("outcome") != "failure" || r.URL.Query().Get("cursor") != "50" || r.URL.Query().Get("action") != "put_object" || r.URL.Query().Get("limit") != "50" {
			t.Errorf("unexpected audit query: %s", r.URL)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"items":[{"timestamp_unix_seconds":1,"request_id":"audit-test","actor":"alice","action":"put_object","target":"/bucket/key","outcome":"failure:403"}],"next_cursor":"100"}`))
	}))
	defer server.Close()
	client := zigclient.New(server.URL, time.Second)
	result, err := client.ListBucketEvents(context.Background(), "", "50", "", "", "put_object", "failure", 50)
	if err != nil || len(result.Items) != 1 {
		t.Fatalf("global audit forwarding: %#v %v", result, err)
	}
}

func TestAuditV1ForwardsNestedSchemaAndFilters(t *testing.T) {
	payload := `{"items":[{"schema_version":"1.0","event_id":"evt_test","event_action":"PutObject","identity":{"auth_type":"s3_access_key","principal_name":"alice"},"resource":{"bucket":"photos","object_key":"a.jpg"},"response":{"status":"denied","http_status":403,"duration_ms":12}}],"next_cursor":null}`
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/_admin/v1/audit-events" || r.URL.Query().Get("category") != "security" || r.URL.Query().Get("actor") != "alice" || r.URL.Query().Get("bucket") != "photos" || r.URL.Query().Get("request_id") != "req-one" {
			t.Errorf("incorrect V1 audit query: %s", r.URL)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(payload))
	}))
	defer server.Close()
	client := zigclient.New(server.URL, time.Second)
	result, err := client.AuditEvents(context.Background(), "", "category=security&actor=alice&bucket=photos&request_id=req-one")
	if err != nil {
		t.Fatal(err)
	}
	var got, expected any
	if err := json.Unmarshal(result, &got); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(payload), &expected); err != nil {
		t.Fatal(err)
	}
	gotJSON, _ := json.Marshal(got)
	expectedJSON, _ := json.Marshal(expected)
	if string(gotJSON) != string(expectedJSON) {
		t.Fatalf("structured audit data lost: %s", result)
	}
}

func TestAuditLogSettingsUsesIndependentEndpoint(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/_admin/v1/settings/audit-logs/download" || r.URL.Query().Get("from") != "100" {
			t.Errorf("unexpected audit path %s", r.URL)
		}
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"code":"LogDownloadsDisabled","message":"Audit downloads disabled"}`))
	}))
	defer server.Close()
	client := zigclient.New(server.URL, time.Second)
	if _, err := client.AuditLogSettings(context.Background(), http.MethodGet, "download?from=100", nil); err == nil {
		t.Fatal("audit download denial swallowed")
	}
}

func TestPresignObjectForwardsDownloadAndVersion(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body contract.PresignObjectRequest
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if !body.Download || body.VersionID != "null" || body.Method != http.MethodGet {
			t.Fatalf("download options not forwarded: %+v", body)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"url":"http://s3.example/file?response-content-disposition=attachment","expires_at":"2026-09-08T08:00:00Z","required_headers":{}}`))
	}))
	defer server.Close()
	_, err := zigclient.New(server.URL, time.Second).PresignObject(context.Background(), contract.PresignObjectRequest{
		Bucket: "bucket", Key: "file", Method: http.MethodGet, ExpiresSecond: 900, Download: true, VersionID: "null",
	})
	if err != nil {
		t.Fatal(err)
	}
}
