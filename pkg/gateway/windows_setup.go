package gateway

import (
	"crypto/x509"
	_ "embed"
	"encoding/base64"
	"encoding/binary"
	"encoding/pem"
	"errors"
	"strings"
	"unicode/utf16"
)

//go:embed windows_setup.ps1
var windowsSetupTemplate string

// WindowsSetup exports a public-CA-only PowerShell helper. Privileged hosts and
// trust-store operations happen only when the user runs it on the server's PC.
func (m *Manager) WindowsSetup() (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	deployment := m.state.Candidate
	if deployment == nil {
		deployment = m.state.Active
	}
	if deployment == nil || deployment.Config.CertificateMode != "local" || m.state.CA == nil {
		return "", errors.New("prepare a gateway using the local CA first")
	}
	if !localDomain(deployment.Config.AdminDomain) || !localDomain(deployment.Config.S3Domain) {
		return "", errors.New("local setup requires both names beneath zigfs.home.arpa")
	}
	if err := deployment.Config.Validate(); err != nil {
		return "", err
	}
	block, _ := pem.Decode([]byte(m.state.CA.Certificate))
	if block == nil {
		return "", errors.New("invalid local CA certificate")
	}
	certificate, err := x509.ParseCertificate(block.Bytes)
	if err != nil || !certificate.IsCA {
		return "", errors.New("invalid local CA certificate")
	}
	return strings.NewReplacer(
		"__CA_DER__", base64.StdEncoding.EncodeToString(certificate.Raw),
		"__ADMIN_DOMAIN__", deployment.Config.AdminDomain,
		"__TARGET_IP__", deployment.Config.DNSAddress(),
		"__S3_DOMAIN__", deployment.Config.S3Domain,
	).Replace(windowsSetupTemplate), nil
}

// Windows hosts may be UTF-8 (with or without BOM) or UTF-16. Match the managed
// block and this instance's CA; file presence alone is not a configured resolver.
func windowsHostsConfigured(data []byte, config Config, ca string) bool {
	text := string(data)
	if len(data) >= 2 && ((data[0] == 0xff && data[1] == 0xfe) || (data[0] == 0xfe && data[1] == 0xff)) {
		if len(data)%2 != 0 {
			return false
		}
		var order binary.ByteOrder = binary.LittleEndian
		if data[0] == 0xfe {
			order = binary.BigEndian
		}
		units := make([]uint16, (len(data)-2)/2)
		for i := range units {
			units[i] = order.Uint16(data[2+i*2:])
		}
		text = string(utf16.Decode(units))
	}
	text = strings.TrimPrefix(strings.ReplaceAll(text, "\r\n", "\n"), "\ufeff")
	block, _ := pem.Decode([]byte(ca))
	if block == nil {
		return false
	}
	begin, end := "# BEGIN ZigFS Local HTTPS", "# END ZigFS Local HTTPS"
	if strings.Count(text, begin) != 1 || strings.Count(text, end) != 1 {
		return false
	}
	expected := begin + "\n# CA SHA-256: " + strings.ToUpper(fingerprint(block.Bytes)) +
		"\n" + config.DNSAddress() + " " + config.AdminDomain + "\n" + config.DNSAddress() + " " + config.S3Domain + "\n" + end
	return strings.Contains("\n"+text+"\n", "\n"+expected+"\n")
}
