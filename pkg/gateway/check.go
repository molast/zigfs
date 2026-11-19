package gateway

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"net"
	"net/http"
	"time"
)

// Check verifies the local TLS listener with real certificate verification, and
// separately probes the configured upstream. It does not claim client DNS trust.
func (m *Manager) Check(ctx context.Context) error {
	m.mu.Lock()
	d := m.state.Candidate
	if d == nil {
		d = m.state.Active
	}
	ca := m.state.CA
	if d == nil {
		m.mu.Unlock()
		return errors.New("gateway is not configured")
	}
	m.mu.Unlock()
	roots, err := x509.SystemCertPool()
	if err != nil {
		roots = x509.NewCertPool()
	}
	if d.Config.CertificateMode == "local" && ca != nil {
		roots.AppendCertsFromPEM([]byte(ca.Certificate))
	}
	host, port, _ := net.SplitHostPort(d.Config.ListenAddress)
	if host == "" || host == "0.0.0.0" {
		host = "127.0.0.1"
	}
	if host == "::" {
		host = "::1"
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: roots}
	transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		return (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, network, net.JoinHostPort(host, port))
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	for _, domain := range []string{d.Config.AdminDomain, d.Config.S3Domain} {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, d.Config.URL(domain)+"/_gateway/probe", nil)
		if err != nil {
			return err
		}
		response, err := client.Do(req)
		if err != nil {
			return errors.New("local HTTPS check failed; verify certificate chain and listener")
		}
		body, err := io.ReadAll(io.LimitReader(response.Body, 1024))
		response.Body.Close()
		if err != nil || response.StatusCode != 200 || string(body) != d.ID {
			return errors.New("local HTTPS probe returned an unexpected response")
		}
	}
	endpoint := m.endpoint()
	if err := validateEndpoint(endpoint); err != nil {
		return err
	}
	upstreamTransport := http.DefaultTransport.(*http.Transport).Clone()
	defer upstreamTransport.CloseIdleConnections()
	upstream := &http.Client{Transport: upstreamTransport, Timeout: 10 * time.Second, CheckRedirect: client.CheckRedirect}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint+"/health/ready", nil)
	if err != nil {
		return err
	}
	response, err := upstream.Do(req)
	if err != nil {
		return errors.New("ZigFS upstream is unreachable")
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		return errors.New("ZigFS upstream is not ready")
	}
	return nil
}
