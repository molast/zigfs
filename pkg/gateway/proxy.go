package gateway

import (
	"crypto/tls"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
	"time"
)

type runtime struct {
	deployment  *Deployment
	certificate *tls.Certificate
}

func hostname(authority string) string {
	host, _, err := net.SplitHostPort(authority)
	if err == nil {
		return strings.ToLower(host)
	}
	return strings.ToLower(authority)
}

func (m *Manager) selectRuntime(address, host string) *runtime {
	snapshot := m.routes.Load()
	if snapshot == nil {
		return nil
	}
	for _, rt := range *snapshot {
		c := rt.deployment.Config
		if c.ListenAddress == address && (host == c.AdminDomain || host == c.S3Domain) {
			return rt
		}
	}
	return nil
}

func (m *Manager) tlsConfig(address string) *tls.Config {
	return &tls.Config{
		MinVersion: tls.VersionTLS12,
		GetCertificate: func(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
			rt := m.selectRuntime(address, strings.ToLower(hello.ServerName))
			if rt == nil {
				return nil, errors.New("unconfigured gateway server name")
			}
			if !time.Now().Before(rt.certificate.Leaf.NotAfter) {
				return nil, errors.New("gateway certificate expired")
			}
			return rt.certificate, nil
		},
	}
}

func (m *Manager) serve(address string, w http.ResponseWriter, r *http.Request) {
	host := hostname(r.Host)
	rt := m.selectRuntime(address, host)
	if rt == nil || r.TLS == nil || !strings.EqualFold(r.TLS.ServerName, host) {
		http.Error(w, "unknown gateway host", http.StatusMisdirectedRequest)
		return
	}
	c := rt.deployment.Config
	if r.URL.Path == "/_gateway/probe" && r.Method == http.MethodGet {
		// Public, credential-free reachability information only. A random deployment
		// ID lets the UI distinguish a stale proxy or another instance.
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Type", "text/plain")
		io.WriteString(w, rt.deployment.ID)
		return
	}
	if host == c.AdminDomain {
		// The forwarding middleware must not append attacker-supplied chains.
		clearForwarded(r.Header)
		m.admin.ServeHTTP(w, r)
		return
	}
	if strings.HasPrefix(r.URL.Path, "/_admin") {
		http.NotFound(w, r)
		return
	}
	m.proxy.ServeHTTP(w, r)
}

func clearForwarded(h http.Header) {
	for _, key := range []string{"Forwarded", "X-Forwarded-For", "X-Forwarded-Host", "X-Forwarded-Proto", "X-Real-IP"} {
		h.Del(key)
	}
}

func newProxy(endpoint func() string) *httputil.ReverseProxy {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.DialContext = (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext
	transport.ResponseHeaderTimeout = 15 * time.Minute
	transport.MaxIdleConnsPerHost = 64
	return &httputil.ReverseProxy{
		Transport: transport, FlushInterval: -1,
		// net/http's default proxy logger may include signed request URLs.
		ErrorLog: log.New(io.Discard, "", 0),
		Rewrite: func(p *httputil.ProxyRequest) {
			target, err := url.Parse(endpoint())
			if err != nil || target.Host == "" || (target.Scheme != "http" && target.Scheme != "https") {
				p.Out.URL.Scheme = "invalid"
				return
			}
			// Only replace the transport destination. Never re-encode RawPath/RawQuery,
			// normalize slashes, or substitute the signed Host with the upstream Host.
			p.Out.URL.Scheme = target.Scheme
			p.Out.URL.Host = target.Host
			p.Out.URL.Path = p.In.URL.Path
			p.Out.URL.RawPath = p.In.URL.RawPath
			p.Out.URL.RawQuery = p.In.URL.RawQuery
			p.Out.Host = p.In.Host
			clearForwarded(p.Out.Header)
			p.SetXForwarded()
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, _ error) {
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Content-Type", "application/xml")
			w.Header().Set("Cache-Control", "no-store")
			w.WriteHeader(http.StatusBadGateway)
			io.WriteString(w, "<Error><Code>GatewayUpstreamUnavailable</Code><Message>Unable to reach object service</Message></Error>")
		},
	}
}
