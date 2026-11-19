package gateway

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	goruntime "runtime"
	"strings"
	"testing"
	"time"
)

func freeAddress(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := l.Addr().String()
	l.Close()
	return address
}

func setup(t *testing.T, upstream http.Handler) (*Manager, *http.Client, Config) {
	t.Helper()
	server := httptest.NewServer(upstream)
	t.Cleanup(server.Close)
	m := New(t.TempDir(), func() string { return server.URL })
	m.Start(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("admin")) }))
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		m.Shutdown(ctx)
	})
	c := Config{ListenAddress: freeAddress(t), AdminDomain: "admin.zigfs.home.arpa", S3Domain: "s3.zigfs.home.arpa", ExternalPort: 8443, CertificateMode: "local"}
	if err := m.Prepare(PrepareRequest{Config: c}); err != nil {
		t.Fatal(err)
	}
	ca, _ := m.CA()
	roots := x509.NewCertPool()
	roots.AppendCertsFromPEM([]byte(ca))
	transport := &http.Transport{TLSClientConfig: &tls.Config{RootCAs: roots}, DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, c.ListenAddress)
	}}
	t.Cleanup(transport.CloseIdleConnections)
	return m, &http.Client{Transport: transport, Timeout: 3 * time.Second}, c
}

func TestHTTPSProxyPreservesSignedRequestAndCORS(t *testing.T) {
	target := "/photos/a%2Fb//%E4%B8%AD+%25?X-Amz-Signature=a%2Bb&x=1&x=2"
	m, client, c := setup(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health/ready" {
			w.Write([]byte("ready"))
			return
		}
		if r.RequestURI != target {
			t.Errorf("signed target changed: %s", r.RequestURI)
		}
		if r.Host != "s3.zigfs.home.arpa:8443" {
			t.Errorf("Host changed: %s", r.Host)
		}
		if r.Header.Get("X-Forwarded-For") == "attacker" {
			t.Error("spoofed forwarding header survived")
		}
		if r.Header.Get("X-Forwarded-Proto") != "https" {
			t.Error("missing HTTPS forwarding")
		}
		if r.Header.Get("Authorization") != "AWS4-HMAC-SHA256 test" {
			t.Error("authorization lost")
		}
		if r.Method == "OPTIONS" {
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Access-Control-Allow-Methods", "PUT, DELETE")
			w.WriteHeader(204)
			return
		}
		body, _ := io.ReadAll(r.Body)
		if string(body) != "object payload" {
			t.Errorf("bad body: %q", body)
		}
		w.Header().Set("ETag", `"abc"`)
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.WriteHeader(201)
	}))
	for _, method := range []string{"PUT", "OPTIONS"} {
		req, _ := http.NewRequest(method, c.URL(c.S3Domain)+target, strings.NewReader("object payload"))
		req.Header.Set("X-Forwarded-For", "attacker")
		req.Header.Set("Authorization", "AWS4-HMAC-SHA256 test")
		req.Header.Set("Origin", "https://another-admin.example")
		response, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		response.Body.Close()
		if response.Header.Get("Access-Control-Allow-Origin") != "*" {
			t.Fatal("CORS not forwarded")
		}
		if method == "OPTIONS" && response.StatusCode != 204 {
			t.Fatalf("preflight: %d", response.StatusCode)
		}
	}
	if err := m.Check(context.Background()); err != nil {
		t.Fatal(err)
	}
	response, err := client.Get(c.URL(c.AdminDomain) + "/")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if string(body) != "admin" {
		t.Fatal(string(body))
	}
	response, err = client.Get(c.URL(c.S3Domain) + "/_admin/v1/settings")
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 404 {
		t.Fatal("management exposed on S3 host")
	}
	req, _ := http.NewRequest("GET", c.URL(c.S3Domain)+"/", nil)
	req.Host = c.AdminDomain
	response, err = client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 421 {
		t.Fatal("SNI/Host mismatch accepted")
	}
}

func TestPendingApplyReconcilesLostResponseAndSurvivesRestart(t *testing.T) {
	m, _, c := setup(t, http.NotFoundHandler())
	current := Network{Endpoint: "http://old.example:9000", TrustedProxies: []string{}}
	read := func() (Network, error) { return current, nil }
	calls := 0
	write := func(n Network) error { current = n; calls++; return errors.New("response lost") }
	if err := m.Apply(m.Status().Revision, false, "", read, write); err == nil {
		t.Fatal("expected lost response")
	}
	if !m.Status().Pending {
		t.Fatal("pending journal missing")
	}
	if current.Endpoint != c.URL(c.S3Domain) {
		t.Fatal(current.Endpoint)
	}
	m.Shutdown(context.Background())
	restarted := New(m.dir, m.endpoint)
	restarted.Start(http.NotFoundHandler())
	defer restarted.Shutdown(context.Background())
	if !restarted.Status().Pending {
		t.Fatal("pending state lost on restart")
	}
	if err := restarted.Apply(restarted.Status().Revision, false, "", read, write); err != nil {
		t.Fatal(err)
	}
	if calls != 1 {
		t.Fatal("reapplied a committed remote change")
	}
	if restarted.Status().Active == nil || restarted.Status().Pending {
		t.Fatal("application not committed")
	}
	stateJSON, _ := json.Marshal(restarted.Status())
	if strings.Contains(string(stateJSON), "PRIVATE KEY") {
		t.Fatal("private key leaked in status")
	}
	info, _ := os.Stat(filepath.Join(m.dir, "state.json"))
	if goruntime.GOOS != "windows" && info.Mode().Perm() != 0600 {
		t.Fatal(info.Mode())
	}
}

func TestCandidateRollbackAndStaleRevision(t *testing.T) {
	m, _, _ := setup(t, http.NotFoundHandler())
	revision := m.Status().Revision
	if err := m.Prepare(PrepareRequest{Revision: revision - 1}); !errors.Is(err, ErrConflict) {
		t.Fatal(err)
	}
	neverRead := func() (Network, error) {
		t.Fatal("unexpected network read")
		return Network{}, nil
	}
	if err := m.Rollback(revision, neverRead, nil); err != nil {
		t.Fatal(err)
	}
	if m.Status().Candidate != nil {
		t.Fatal("candidate retained")
	}
}

func TestRollbackDoesNotOverwriteConcurrentNetworkChange(t *testing.T) {
	m, _, _ := setup(t, http.NotFoundHandler())
	current := Network{Endpoint: "http://old.example:9000"}
	read := func() (Network, error) { return current, nil }
	if err := m.Apply(m.Status().Revision, false, "", read, func(n Network) error { return errors.New("offline") }); err == nil {
		t.Fatal("expected failure")
	}
	current.Endpoint = "https://changed.example"
	writes := 0
	if err := m.Rollback(m.Status().Revision, read, func(n Network) error {
		writes++
		return nil
	}); err == nil {
		t.Fatal("concurrent change overwritten")
	}
	if writes != 0 {
		t.Fatal("wrote conflicting network configuration")
	}
}

func TestImportedCertificateValidationAndLocalRenewal(t *testing.T) {
	m, _, c := setup(t, http.NotFoundHandler())
	originalCA, _ := m.CA()
	d := *m.state.Candidate
	bad := c
	bad.AdminDomain = "wrong.example"
	if _, err := validateCertificate(bad, d.Material, time.Now()); err == nil {
		t.Fatal("accepted wrong SAN")
	}
	if _, err := validateCertificate(c, d.Material, time.Now().Add(100*24*time.Hour)); err == nil {
		t.Fatal("accepted expired certificate")
	}
	old := d.Material.Certificate
	renewed, err := issueCertificate(c, *m.state.CA, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if renewed.Certificate == old {
		t.Fatal("renewal did not rotate leaf")
	}
	cert, err := validateCertificate(c, renewed, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AppendCertsFromPEM([]byte(originalCA))
	if _, err = cert.Leaf.Verify(x509.VerifyOptions{Roots: roots, DNSName: c.S3Domain}); err != nil {
		t.Fatal(err)
	}
}

func TestRenewalKeepsCAAndPersistsNewLeaf(t *testing.T) {
	m, _, c := setup(t, http.NotFoundHandler())
	then := time.Now().Add(-70 * 24 * time.Hour)
	ca, err := newCA(then)
	if err != nil {
		t.Fatal(err)
	}
	material, err := issueCertificate(c, *ca, then)
	if err != nil {
		t.Fatal(err)
	}
	m.mu.Lock()
	m.state.CA = ca
	d := *m.state.Candidate
	d.Material = material
	m.state.Candidate = &d
	err = m.renewLocked()
	m.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	if m.state.Candidate.Material.Certificate == material.Certificate {
		t.Fatal("near-expiry leaf was not renewed")
	}
	if *m.state.CA != *ca {
		t.Fatal("CA rotated during renewal")
	}
	saved, err := readState(m.dir)
	if err != nil {
		t.Fatal(err)
	}
	if saved.Candidate.Material.Certificate != m.state.Candidate.Material.Certificate {
		t.Fatal("renewal was not persisted")
	}
}

func TestFailedPreparationKeepsCandidateAndPort(t *testing.T) {
	m, client, c := setup(t, http.NotFoundHandler())
	before := m.Status()
	occupied, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer occupied.Close()
	changed := c
	changed.ListenAddress = occupied.Addr().String()
	if err = m.Prepare(PrepareRequest{Revision: before.Revision, Config: changed}); err == nil {
		t.Fatal("occupied port accepted")
	}
	if m.Status().Candidate.ID != before.Candidate.ID {
		t.Fatal("candidate changed after failure")
	}
	response, err := client.Get(c.URL(c.AdminDomain) + "/_gateway/probe")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		t.Fatal("old listener unavailable")
	}
}

func TestProxyCancellationAndRange(t *testing.T) {
	cancelled := make(chan struct{})
	started := make(chan struct{})
	_, client, c := setup(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/range" {
			if r.Header.Get("Range") != "bytes=1-3" {
				t.Error("range header lost")
			}
			w.Header().Set("Content-Range", "bytes 1-3/10")
			w.Header().Set("ETag", `"version"`)
			w.WriteHeader(206)
			w.Write([]byte("123"))
			return
		}
		close(started)
		<-r.Context().Done()
		close(cancelled)
	}))
	req, _ := http.NewRequest("GET", c.URL(c.S3Domain)+"/range", nil)
	req.Header.Set("Range", "bytes=1-3")
	response, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if response.StatusCode != 206 || string(body) != "123" || response.Header.Get("Content-Range") != "bytes 1-3/10" {
		t.Fatal("range response changed")
	}
	ctx, cancel := context.WithCancel(context.Background())
	req, _ = http.NewRequestWithContext(ctx, "GET", c.URL(c.S3Domain)+"/slow", nil)
	done := make(chan struct{})
	go func() {
		defer close(done)
		response, _ := client.Do(req)
		if response != nil {
			response.Body.Close()
		}
	}()
	<-started
	cancel()
	select {
	case <-cancelled:
	case <-time.After(3 * time.Second):
		t.Fatal("upstream request not cancelled")
	}
	<-done
}

func TestImportAndDisableValidation(t *testing.T) {
	m, _, c := setup(t, http.NotFoundHandler())
	material := m.state.Candidate.Material
	imported := c
	imported.CertificateMode = "import"
	if err := m.Prepare(PrepareRequest{Revision: m.Status().Revision, Config: imported, CertificatePEM: material.Certificate, PrivateKeyPEM: material.Key}); err != nil {
		t.Fatal(err)
	}
	if m.Status().Candidate.Config.CertificateMode != "import" {
		t.Fatal("import not staged")
	}
	imported.ExternalPort = 443
	s := diskState{Active: &Deployment{Config: imported}}
	for _, endpoint := range []string{"https://s3.zigfs.home.arpa:443", "https://S3.ZIGFS.HOME.ARPA", "https://admin.zigfs.home.arpa"} {
		if err := validateFallback(endpoint, s); err == nil {
			t.Fatalf("accepted unavailable fallback %s", endpoint)
		}
	}
	if err := validateFallback("http://127.0.0.1:9000", s); err != nil {
		t.Fatal(err)
	}
}
