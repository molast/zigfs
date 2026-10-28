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
