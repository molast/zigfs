package gateway

import (
	"context"
	"crypto/x509"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestFinalCommitFailureReconcilesAfterRestart(t *testing.T) {
	m, _, cfg := setup(t, http.NotFoundHandler())
	originalDirectory := m.dir
	blockedDirectory := filepath.Join(t.TempDir(), "not-a-directory")
	if err := os.WriteFile(blockedDirectory, []byte("blocked"), 0600); err != nil {
		t.Fatal(err)
	}
	actual := Network{Endpoint: "http://127.0.0.1:9000", TrustedProxies: []string{}}
	writes := 0
	read := func() (Network, error) { return actual, nil }
	write := func(value Network) error {
		actual = value
		writes++
		// Simulate configuration storage becoming unavailable after upstream CAS.
		m.dir = blockedDirectory
		return nil
	}
	if err := m.Apply(m.Status().Revision, false, "", read, write); err == nil {
		t.Fatal("final persistence unexpectedly succeeded")
	}
	if actual.Endpoint != cfg.URL(cfg.S3Domain) || !m.Status().Pending {
		t.Fatal("missing persisted transition")
	}
	m.Shutdown(context.Background())
	recovered := New(originalDirectory, func() string { return "http://127.0.0.1:9000" })
	recovered.Start(http.NotFoundHandler())
	defer recovered.Shutdown(context.Background())
	if err := recovered.Apply(recovered.Status().Revision, false, "", read, func(value Network) error {
		writes++
		actual = value
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if writes != 1 || recovered.Status().Pending || recovered.Status().Active == nil {
		t.Fatal("recovery rewrote network or did not finalize")
	}
}

func TestFailedPreparePreservesStateAndRoutes(t *testing.T) {
	m, client, cfg := setup(t, http.NotFoundHandler())
	before := m.Status()
	m.dir = filepath.Join(t.TempDir(), "blocked")
	if err := os.WriteFile(m.dir, []byte("blocked"), 0600); err != nil {
		t.Fatal(err)
	}
	changed := cfg
	changed.ListenAddress = freeAddress(t)
	if err := m.Prepare(PrepareRequest{Revision: before.Revision, Config: changed}); err == nil {
		t.Fatal("prepare unexpectedly persisted")
	}
	after := m.Status()
	if !reflect.DeepEqual(before.Candidate, after.Candidate) || before.Revision != after.Revision {
		t.Fatal("failed prepare changed state")
	}
	response, err := client.Get(cfg.URL(cfg.AdminDomain) + "/_gateway/probe")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(response.Body)
	if string(body) != before.Candidate.ID {
		t.Fatal("old route was replaced")
	}
}

func TestRenewalDoesNotInterruptActiveDownload(t *testing.T) {
	release := make(chan struct{})
	m, client, cfg := setup(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "before")
		w.(http.Flusher).Flush()
		select {
		case <-release:
			io.WriteString(w, "after")
		case <-r.Context().Done():
		}
	}))
	// Keep the same trusted CA, but place the leaf inside its renewal window.
	then := time.Now().Add(-70 * 24 * time.Hour)
	ca, err := newCA(then)
	if err != nil {
		t.Fatal(err)
	}
	m.state.CA = ca
	roots := x509.NewCertPool()
	roots.AppendCertsFromPEM([]byte(ca.Certificate))
	client.Transport.(*http.Transport).TLSClientConfig.RootCAs = roots
	material, err := issueCertificate(cfg, *ca, then)
	if err != nil {
		t.Fatal(err)
	}
	m.mu.Lock()
	deployment := *m.state.Candidate
	deployment.Material = material
	m.state.Candidate = &deployment
	err = m.publish(m.state)
	m.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	response, err := client.Get(cfg.URL(cfg.S3Domain) + "/bucket/large")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	first := make([]byte, 6)
	if _, err = io.ReadFull(response.Body, first); err != nil {
		t.Fatal(err)
	}
	before := m.Status().Candidate.Fingerprint
	m.mu.Lock()
	err = m.renewLocked()
	m.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	if m.Status().Candidate.Fingerprint == before {
		t.Fatal("certificate did not renew")
	}
	close(release)
	rest, err := io.ReadAll(response.Body)
	if err != nil || string(first) != "before" || string(rest) != "after" {
		t.Fatalf("active download interrupted: %q %q %v", first, rest, err)
	}
	client.Transport.(*http.Transport).CloseIdleConnections()
	probe, err := client.Get(cfg.URL(cfg.AdminDomain) + "/_gateway/probe")
	if err != nil {
		t.Fatal(err)
	}
	probe.Body.Close()
	if probe.StatusCode != 200 {
		t.Fatal("renewed certificate or route is unavailable")
	}
}

func TestCertificateStatusReportsActualSANsWithoutSharingState(t *testing.T) {
	m, _, cfg := setup(t, http.NotFoundHandler())
	status := m.Status()
	if !reflect.DeepEqual(status.Candidate.DNSNames, []string{cfg.AdminDomain, cfg.S3Domain}) {
		t.Fatalf("unexpected certificate SANs: %v", status.Candidate.DNSNames)
	}
	status.Candidate.DNSNames[0] = "changed.example"
	if m.Status().Candidate.DNSNames[0] != cfg.AdminDomain {
		t.Fatal("public status can mutate certificate state")
	}
}
