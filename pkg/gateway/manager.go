package gateway

import (
	"context"
	"crypto/rand"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Manager serializes changes and publishes immutable runtime snapshots. Request
// bodies never run under its configuration lock. Persisted keys stay private.
type Manager struct {
	mu         sync.Mutex
	dir        string
	state      diskState
	admin      http.Handler
	proxy      *httputil.ReverseProxy
	endpoint   func() string
	servers    map[string]*http.Server
	routes     atomic.Pointer[[]*runtime]
	lastError  string
	loadError  error
	dnsRunning bool
	dnsError   string
}

func New(dir string, endpoint func() string) *Manager {
	state, err := readState(dir)
	m := &Manager{dir: dir, state: state, endpoint: endpoint, proxy: newProxy(endpoint), servers: map[string]*http.Server{}, loadError: err}
	if err != nil {
		m.lastError = "cannot load gateway configuration: " + err.Error()
	}
	return m
}

// Start keeps failures local to the gateway so the HTTP recovery UI stays up.
func (m *Manager) Start(admin http.Handler) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.admin = admin
	if m.loadError != nil {
		return
	}
	if err := m.renewLocked(); err != nil {
		m.lastError = err.Error()
	}
	if err := m.publish(m.state); err != nil {
		m.lastError = err.Error()
	}
}

func (m *Manager) Maintain(ctx context.Context) {
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.mu.Lock()
			if err := m.renewLocked(); err != nil {
				m.lastError = err.Error()
			}
			m.mu.Unlock()
		}
	}
}

func (m *Manager) renewLocked() error {
	next := m.state
	changed := false
	for _, slot := range []**Deployment{&next.Active, &next.Candidate} {
		if *slot == nil || (*slot).Config.CertificateMode != "local" {
			continue
		}
		block, _ := pem.Decode([]byte((*slot).Material.Certificate))
		if block == nil {
			return errors.New("invalid saved gateway certificate")
		}
		leaf, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return err
		}
		if time.Until(leaf.NotAfter) > 30*24*time.Hour {
			continue
		}
		if next.CA == nil {
			return errors.New("local CA missing; restore the gateway backup")
		}
		d := **slot
		d.Material, err = issueCertificate(d.Config, *next.CA, time.Now())
		if err != nil {
			return err
		}
		*slot = &d
		changed = true
	}
	if !changed {
		return nil
	}
	next.Revision++
	if err := m.commit(next); err != nil {
		return err
	}
	return m.publish(next)
}

func (m *Manager) Status() Status {
	m.mu.Lock()
	defer m.mu.Unlock()
	status := Status{LocalDNS: m.localStatusLocked(), Revision: m.state.Revision, Active: deploymentStatus(m.state.Active), Candidate: deploymentStatus(m.state.Candidate), Pending: m.state.Transition != nil, Error: m.lastError}
	if m.state.CA != nil {
		block, _ := pem.Decode([]byte(m.state.CA.Certificate))
		if block != nil {
			if cert, err := x509.ParseCertificate(block.Bytes); err == nil {
				status.CAFingerprint = fingerprint(cert.Raw)
				status.CAExpiresAt = &cert.NotAfter
			}
		}
	}
	return status
}

func deploymentStatus(d *Deployment) *DeploymentStatus {
	if d == nil {
		return nil
	}
	result := &DeploymentStatus{ID: d.ID, Config: d.Config, AdminURL: d.Config.URL(d.Config.AdminDomain), S3URL: d.Config.URL(d.Config.S3Domain)}
	block, _ := pem.Decode([]byte(d.Material.Certificate))
	if block != nil {
		if cert, err := x509.ParseCertificate(block.Bytes); err == nil {
			result.ExpiresAt = cert.NotAfter
			result.Fingerprint = fingerprint(cert.Raw)
			result.DNSNames = append([]string(nil), cert.DNSNames...)
		}
	}
	return result
}

func (m *Manager) CA() (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.state.CA == nil {
		return "", errors.New("no local CA has been generated")
	}
	return m.state.CA.Certificate, nil
}

func (m *Manager) checkRevision(revision uint64) error {
	if m.loadError != nil {
		return errors.New(m.lastError)
	}
	if revision != m.state.Revision {
		return ErrConflict
	}
	return nil
}

func (m *Manager) Prepare(input PrepareRequest) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.checkRevision(input.Revision); err != nil {
		return err
	}
	if m.state.Transition != nil {
		return errors.New("resolve the pending application before preparing another configuration")
	}
	if err := input.Config.Validate(); err != nil {
		return err
	}
	if active := m.state.Active; active != nil {
		overlaps := input.Config.AdminDomain == active.Config.AdminDomain || input.Config.S3Domain == active.Config.S3Domain
		if overlaps && input.Config.ListenAddress == active.Config.ListenAddress &&
			(input.Config.CertificateMode == "import" || active.Config.CertificateMode != input.Config.CertificateMode) {
			return errors.New("stage a certificate trust change on a different listener port to keep the active HTTPS entry available")
		}
		if input.Config.AdminDomain == active.Config.S3Domain || input.Config.S3Domain == active.Config.AdminDomain {
			return errors.New("an active Admin domain cannot become an S3 domain, or vice versa; disable the gateway first")
		}
	}
	next := m.state
	d := &Deployment{Config: input.Config}
	id := make([]byte, 16)
	if _, err := rand.Read(id); err != nil {
		return err
	}
	d.ID = hex.EncodeToString(id)
	var err error
	if input.Config.CertificateMode == "local" {
		if next.CA == nil {
			next.CA, err = newCA(time.Now())
			if err != nil {
				return err
			}
		}
		d.Material, err = issueCertificate(input.Config, *next.CA, time.Now())
	} else {
		d.Material = Material{Certificate: input.CertificatePEM, Key: input.PrivateKeyPEM}
	}
	if err != nil {
		return err
	}
	if _, err = validateCertificate(d.Config, d.Material, time.Now()); err != nil {
		return err
	}
	next.Candidate = d
	next.Revision++
	// Bind first. Failed binds or saves must leave current routes operational.
	opened, err := m.openListeners(next)
	if err != nil {
		return err
	}
	if err = m.commit(next); err != nil {
		m.closeOpened(opened)
		return err
	}
	return m.publish(next)
}

// Apply journals the intended network transition before the remote write. If a
// response is lost, retry reconciles against actual ZigFS state. No blind undo.
func (m *Manager) Apply(revision uint64, disable bool, fallback string, read func() (Network, error), write func(Network) error) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.checkRevision(revision); err != nil {
		return err
	}
	next := m.state
	if next.Transition == nil {
		if !disable && next.Candidate == nil {
			return errors.New("prepare a candidate first")
		}
		before, err := read()
		if err != nil {
			return err
		}
		after := before
		if disable {
			if err := validateFallback(fallback, next); err != nil {
				return err
			}
			after.Endpoint = fallback
		} else {
			if err := m.publish(next); err != nil {
				return err
			}
			after.Endpoint = next.Candidate.Config.URL(next.Candidate.Config.S3Domain)
			after.VirtualHosted = false
		}
		next.Transition = &Transition{Before: before, After: after, Disable: disable}
		next.Revision++
		if err := m.commit(next); err != nil {
			return err
		}
	}
	transition := next.Transition
	actual, err := read()
	if err != nil {
		m.lastError = "network application pending; retry or roll back"
		return err
	}
	if !reflect.DeepEqual(actual, transition.After) {
		if !reflect.DeepEqual(actual, transition.Before) {
			return errors.New("network settings changed elsewhere; resolve the pending transition before retrying")
		}
		if err = write(transition.After); err != nil {
			m.lastError = "network application pending; retry or roll back"
			return err
		}
	}
	if transition.Disable {
		next.Active = nil
	} else {
		next.Active = next.Candidate
	}
	next.Candidate = nil
	next.Transition = nil
	next.Revision++
	if err = m.commit(next); err != nil {
		m.lastError = "network updated but gateway commit failed; retry application"
		return err
	}
	return m.publish(next)
}

func validateFallback(endpoint string, s diskState) error {
	if err := validateEndpoint(endpoint); err != nil {
		return err
	}
	target, _ := url.Parse(endpoint)
	port := target.Port()
	if port == "" && target.Scheme == "https" {
		port = "443"
	}
	for _, d := range []*Deployment{s.Active, s.Candidate} {
		if d == nil {
			continue
		}
		c := d.Config
		if target.Scheme == "https" && port == strconv.Itoa(c.ExternalPort) &&
			(strings.EqualFold(target.Hostname(), c.S3Domain) || strings.EqualFold(target.Hostname(), c.AdminDomain)) {
			return errors.New("fallback must not point to the gateway being disabled")
		}
	}
	return nil
}

func (m *Manager) Rollback(revision uint64, read func() (Network, error), write func(Network) error) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.checkRevision(revision); err != nil {
		return err
	}
	next := m.state
	if next.Transition != nil {
		actual, err := read()
		if err != nil {
			return err
		}
		if reflect.DeepEqual(actual, next.Transition.After) {
			if err = write(next.Transition.Before); err != nil {
				return err
			}
		} else if !reflect.DeepEqual(actual, next.Transition.Before) {
			return errors.New("network settings changed elsewhere; refusing to overwrite them")
		}
	}
	next.Candidate = nil
	next.Transition = nil
	next.Revision++
	if err := m.commit(next); err != nil {
		return err
	}
	return m.publish(next)
}

func (m *Manager) commit(next diskState) error {
	if err := saveState(m.dir, next); err != nil {
		return err
	}
	m.state = next
	m.lastError = ""
	return nil
}

func (m *Manager) openListeners(s diskState) ([]string, error) {
	var opened []string
	for _, d := range []*Deployment{s.Active, s.Candidate} {
		if d == nil || m.servers[d.Config.ListenAddress] != nil {
			continue
		}
		address := d.Config.ListenAddress
		listener, err := net.Listen("tcp", address)
		if err != nil {
			m.closeOpened(opened)
			return nil, fmt.Errorf("cannot listen on %s: %w", address, err)
		}
		server := &http.Server{
			Handler:   http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { m.serve(address, w, r) }),
			TLSConfig: m.tlsConfig(address), ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second,
			MaxHeaderBytes: 64 * 1024, ErrorLog: log.New(io.Discard, "", 0),
		}
		m.servers[address] = server
		opened = append(opened, address)
		go func() {
			if err := server.ServeTLS(listener, "", ""); err != nil && !errors.Is(err, http.ErrServerClosed) {
				m.mu.Lock()
				m.lastError = "gateway listener stopped: " + err.Error()
				m.mu.Unlock()
			}
		}()
	}
	return opened, nil
}

func (m *Manager) closeOpened(addresses []string) {
	for _, address := range addresses {
		m.servers[address].Close()
		delete(m.servers, address)
	}
}

func (m *Manager) publish(s diskState) error {
	var routes []*runtime
	// Candidate first for hosts that are unchanged; old distinct domains remain reachable.
	for _, d := range []*Deployment{s.Candidate, s.Active} {
		if d == nil {
			continue
		}
		cert, err := validateCertificate(d.Config, d.Material, time.Now())
		if err != nil {
			if d == s.Active && s.Candidate != nil {
				continue // A valid candidate can recover an expired imported certificate.
			}
			return err
		}
		routes = append(routes, &runtime{deployment: d, certificate: cert})
	}
	if _, err := m.openListeners(s); err != nil {
		return err
	}
	m.routes.Store(&routes)
	for address, server := range m.servers {
		needed := false
		for _, rt := range routes {
			if rt.deployment.Config.ListenAddress == address {
				needed = true
			}
		}
		if !needed {
			delete(m.servers, address)
			// Drain active uploads without holding the manager lock.
			go func() {
				ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
				defer cancel()
				if server.Shutdown(ctx) != nil {
					server.Close()
				}
			}()
		}
	}
	return nil
}

func (m *Manager) Shutdown(ctx context.Context) {
	m.mu.Lock()
	servers := m.servers
	m.servers = map[string]*http.Server{}
	m.mu.Unlock()
	for _, server := range servers {
		if server.Shutdown(ctx) != nil {
			server.Close()
		}
	}
	if transport, ok := m.proxy.Transport.(*http.Transport); ok {
		transport.CloseIdleConnections()
	}
}
