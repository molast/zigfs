package gateway

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

// The upload cannot finish until the upstream has received its first chunk.
// A proxy that buffers the complete request would deadlock this handshake.
func TestUploadStreamsBeforeBodyCompletes(t *testing.T) {
	received := make(chan struct{})
	_, client, cfg := setup(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		first := make([]byte, 4096)
		if _, err := io.ReadFull(r.Body, first); err != nil {
			return
		}
		close(received)
		count, err := io.Copy(io.Discard, r.Body)
		if err != nil {
			return
		}
		w.Header().Set("Trailer", "X-Object-Checksum")
		fmt.Fprintf(w, "%d", count+int64(len(first)))
		w.Header().Set("X-Object-Checksum", "complete")
	}))
	client.Timeout = 5 * time.Second
	reader, writer := io.Pipe()
	defer reader.Close()
	defer writer.Close()
	done := make(chan error, 1)
	go func() {
		req, _ := http.NewRequest(http.MethodPut, cfg.URL(cfg.S3Domain)+"/bucket/stream", reader)
		response, err := client.Do(req)
		if err != nil {
			done <- err
			return
		}
		defer response.Body.Close()
		body, err := io.ReadAll(response.Body)
		if err == nil && (string(body) != "8388608" || response.Trailer.Get("X-Object-Checksum") != "complete") {
			err = fmt.Errorf("unexpected body/trailer: %s %v", body, response.Trailer)
		}
		done <- err
	}()
	if _, err := writer.Write(bytes.Repeat([]byte("a"), 4096)); err != nil {
		t.Fatal(err)
	}
	select {
	case <-received:
	case <-time.After(2 * time.Second):
		t.Fatal("first upload chunk was buffered")
	}
	chunk := bytes.Repeat([]byte("b"), 4096)
	for i := 1; i < 2048; i++ {
		if _, err := writer.Write(chunk); err != nil {
			t.Fatal(err)
		}
	}
	writer.Close()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestDownloadFlushesBeforeUpstreamCompletes(t *testing.T) {
	release := make(chan struct{})
	defer close(release)
	_, client, cfg := setup(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "first")
		w.(http.Flusher).Flush()
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	client.Timeout = 3 * time.Second
	response, err := client.Get(cfg.URL(cfg.S3Domain) + "/bucket/stream")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	first := make([]byte, 5)
	if _, err = io.ReadFull(response.Body, first); err != nil || string(first) != "first" {
		t.Fatalf("download buffered: %q %v", first, err)
	}
}

func TestUpstreamFailureHasS3ErrorAndCORS(t *testing.T) {
	_, client, cfg := setup(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, _, err := w.(http.Hijacker).Hijack()
		if err == nil {
			conn.Close()
		}
	}))
	response, err := client.Get(cfg.URL(cfg.S3Domain) + "/bucket/object")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(response.Body)
	if response.StatusCode != 502 || !strings.Contains(string(body), "GatewayUpstreamUnavailable") || response.Header.Get("Access-Control-Allow-Origin") != "*" {
		t.Fatalf("unexpected error: %d %s", response.StatusCode, body)
	}
}
