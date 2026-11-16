package zigclient_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"zigfs-admin/server/internal/zigclient"
)

func TestMonitoringPreservesCapacityAndScannerTelemetry(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/_admin/v1/health":
			w.Write([]byte(`{"status":"ready","recovery":"ready","reason":"none","actions":[],"diagnostics":{"storage":{"state":"online","online":1,"offline":0,"read_only":false},"metadata":{"ready":true,"buckets":2,"objects":3,"directories":0,"listings":{"active":1,"completed":4,"failed":1,"last_duration_ms":0,"last_succeeded":false}},"http":{"active_connections":2,"accepted_connections":8,"rejected_connections":1,"s3":{"active":0,"completed":2,"failed":0,"last_duration_ms":null,"last_succeeded":null},"management":{"active":1,"completed":4,"failed":0,"last_duration_ms":1,"last_succeeded":true}}}}`))
		case "/_admin/v1/system":
			w.Write([]byte(`{"version":"0.1.0","uptime":12,"build":{"built_at":1793592000,"git_commit":"abc123","zig_version":"0.17.0","operating_system":"linux","architecture":"x86_64","mode":"ReleaseSafe"},"process":{"resident_bytes":1048576,"cpu_seconds":0.25,"sampled_at_seconds":100.5}}`))
		case "/_admin/v1/storage":
			w.Write([]byte(`{"measurement":"logical_object_bytes","total":1000,"available":600,"physical_used":300,"used":17}`))
		case "/_admin/v1/storage/scanner":
			w.Write([]byte(`{"partitions":16,"next_partition":3,"last_scan":null,"running":false,"last_completed_at":1793592000,"last_duration_ms":0,"last_attempt_succeeded":false}`))
		default:
			t.Errorf("unexpected route: %s", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	defer server.Close()
	client := zigclient.New(server.URL, time.Second)
	health, err := client.ManagementHealth(context.Background())
	if err != nil || health.Diagnostics == nil {
		t.Fatalf("missing runtime diagnostics: %+v, %v", health, err)
	}
	diagnostic := health.Diagnostics
	if diagnostic.Storage.Offline == nil || *diagnostic.Storage.Offline != 0 || diagnostic.Storage.ReadOnly == nil || *diagnostic.Storage.ReadOnly || diagnostic.Metadata.Listings.LastSucceeded == nil || *diagnostic.Metadata.Listings.LastSucceeded || diagnostic.Metadata.Listings.LastDurationMS == nil || *diagnostic.Metadata.Listings.LastDurationMS != 0 || diagnostic.HTTP.S3.LastSucceeded != nil || diagnostic.HTTP.RejectedConnections != 1 {
		t.Fatalf("diagnostic zero, false or null changed: %+v", diagnostic)
	}
	system, err := client.System(context.Background())
	if err != nil || system.Build == nil || system.Build.GitCommit != "abc123" || system.Build.Mode != "ReleaseSafe" || system.Process == nil || system.Process.ResidentBytes != 1048576 || system.Process.CPUSeconds != 0.25 || system.Process.SampledAtSeconds != 100.5 {
		t.Fatalf("build or process telemetry lost: %+v, %v", system, err)
	}
	storage, err := client.Storage(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if storage.Used != 17 || storage.PhysicalUsed == nil || *storage.PhysicalUsed != 300 || storage.Available == nil || *storage.Available != 600 {
		t.Fatalf("storage measurements were conflated: %+v", storage)
	}
	scanner, err := client.StorageScanner(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if scanner.Running || scanner.LastDurationMs == nil || *scanner.LastDurationMs != 0 || scanner.LastAttemptSucceeded == nil || *scanner.LastAttemptSucceeded || scanner.LastCompletedAt == nil {
		t.Fatalf("nullable scanner telemetry was lost: %+v", scanner)
	}
}
