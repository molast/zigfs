// Package gateway owns the optional HTTPS edge listener. It never accesses the
// ZigFS data directory or interprets S3 credentials and object bodies.
package gateway

import (
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

var ErrConflict = errors.New("gateway configuration changed; refresh and retry")

type Config struct {
	ListenAddress   string `json:"listen_address"`
	AdminDomain     string `json:"admin_domain"`
	S3Domain        string `json:"s3_domain"`
	ExternalPort    int    `json:"external_port"`
	CertificateMode string `json:"certificate_mode"`
}

func (c Config) Validate() error {
	if err := validateListenAddress(c.ListenAddress); err != nil {
		return err
	}
	if !validDomain(c.AdminDomain) || !validDomain(c.S3Domain) || c.AdminDomain == c.S3Domain {
		return errors.New("two distinct lowercase DNS names are required")
	}
	if c.ExternalPort < 1 || c.ExternalPort > 65535 {
		return errors.New("invalid external HTTPS port")
	}
	if c.CertificateMode != "local" && c.CertificateMode != "import" {
		return errors.New("invalid certificate mode")
	}
	return nil
}

func validDomain(s string) bool {
	if len(s) > 253 || !strings.Contains(s, ".") || net.ParseIP(s) != nil || s != strings.ToLower(s) {
		return false
	}
	for _, label := range strings.Split(s, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, c := range label {
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
				return false
			}
		}
	}
	return true
}

func (c Config) URL(domain string) string {
	if c.ExternalPort == 443 {
		return "https://" + domain
	}
	return "https://" + net.JoinHostPort(domain, strconv.Itoa(c.ExternalPort))
}

type PrepareRequest struct {
	Revision       uint64 `json:"revision"`
	Config         Config `json:"config"`
	CertificatePEM string `json:"certificate_pem,omitempty"`
	PrivateKeyPEM  string `json:"private_key_pem,omitempty"`
}

// Material is private persisted state, never serialized by the public API.
// Each complete generation is stored atomically so certificate and key cannot diverge.
type Material struct {
	Certificate string `json:"certificate"`
	Key         string `json:"key"`
}

type Deployment struct {
	ID       string   `json:"id"`
	Config   Config   `json:"config"`
	Material Material `json:"material"`
}

type Network struct {
	Endpoint       string   `json:"s3_public_endpoint"`
	VirtualHosted  bool     `json:"s3_virtual_hosted_style"`
	TrustedProxies []string `json:"trusted_proxies"`
}

type Transition struct {
	Before  Network `json:"before"`
	After   Network `json:"after"`
	Disable bool    `json:"disable"`
}

type diskState struct {
	Version    int         `json:"version"`
	Revision   uint64      `json:"revision"`
	CA         *Material   `json:"ca,omitempty"`
	Active     *Deployment `json:"active,omitempty"`
	Candidate  *Deployment `json:"candidate,omitempty"`
	Transition *Transition `json:"transition,omitempty"`
}

type DeploymentStatus struct {
	ID          string    `json:"id"`
	Config      Config    `json:"config"`
	AdminURL    string    `json:"admin_url"`
	S3URL       string    `json:"s3_url"`
	ExpiresAt   time.Time `json:"expires_at"`
	Fingerprint string    `json:"fingerprint"`
	DNSNames    []string  `json:"dns_names"`
}

type Status struct {
	LocalDNS      LocalStatus       `json:"local_dns"`
	Revision      uint64            `json:"revision"`
	Active        *DeploymentStatus `json:"active"`
	Candidate     *DeploymentStatus `json:"candidate"`
	Pending       bool              `json:"pending"`
	Error         string            `json:"error,omitempty"`
	CAFingerprint string            `json:"ca_fingerprint,omitempty"`
	CAExpiresAt   *time.Time        `json:"ca_expires_at,omitempty"`
}

func readState(dir string) (diskState, error) {
	s := diskState{Version: 1}
	data, err := os.ReadFile(filepath.Join(dir, "state.json"))
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return s, err
	}
	if len(data) > 512*1024 {
		return s, errors.New("gateway state is too large")
	}
	if err := json.Unmarshal(data, &s); err != nil {
		return s, err
	}
	if s.Version != 1 {
		return s, errors.New("unsupported gateway state version")
	}
	for _, d := range []*Deployment{s.Active, s.Candidate} {
		if d != nil {
			if err := d.Config.Validate(); err != nil {
				return s, err
			}
		}
	}
	return s, nil
}

func saveState(dir string, s diskState) error {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	if err := os.Chmod(dir, 0700); err != nil {
		return err
	}
	data, err := json.Marshal(s)
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(dir, ".gateway-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if _, err = file.Write(data); err != nil {
		return err
	}
	if err = file.Sync(); err != nil {
		return err
	}
	if err = file.Close(); err != nil {
		return err
	}
	return replaceStateFile(file.Name(), filepath.Join(dir, "state.json"))
}
