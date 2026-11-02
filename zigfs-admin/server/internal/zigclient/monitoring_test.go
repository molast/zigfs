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
