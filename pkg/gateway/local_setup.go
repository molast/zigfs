package gateway

import (
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	goruntime "runtime"
)

const resolverFile = "/etc/resolver/zigfs.home.arpa"
const resolverContents = "# Managed by ZigFS local gateway v1\nnameserver 127.0.0.1\nport 15353\n"

type LocalStatus struct {
	Platform          string `json:"platform"`
	Supported         bool   `json:"supported"`
	Running           bool   `json:"running"`
	ResolverInstalled bool   `json:"resolver_installed"`
	Address           string `json:"address"`
	Error             string `json:"error,omitempty"`
}

func (m *Manager) localStatusLocked() LocalStatus {
	result := LocalStatus{Platform: goruntime.GOOS, Supported: goruntime.GOOS == "darwin" || goruntime.GOOS == "windows", Running: m.dnsRunning, Address: localDNSAddress, Error: m.dnsError}
	if goruntime.GOOS == "windows" {
		result.Address = ""
		data, _ := os.ReadFile(filepath.Join(os.Getenv("SystemRoot"), "System32", "drivers", "etc", "hosts"))
		deployment := m.state.Candidate
		if deployment == nil {
			deployment = m.state.Active
		}
		if deployment != nil && m.state.CA != nil {
			result.ResolverInstalled = windowsHostsConfigured(data, deployment.Config, m.state.CA.Certificate)
		}
		return result
	}
	data, _ := os.ReadFile(resolverFile)
	result.ResolverInstalled = string(data) == resolverContents
	return result
}

// LocalSetup exports only the public CA. No privileged operation runs in the BFF.
// The downloaded helper is reviewable and asks for privilege only when executed.
func (m *Manager) LocalSetup() (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if goruntime.GOOS != "darwin" {
		return "", errors.New("local setup requires macOS")
	}
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
	return fmt.Sprintf(`#!/bin/bash
# ZigFS local HTTPS setup. Run: bash zigfs-local-setup.sh install
# To remove this resolver and CA trust: bash zigfs-local-setup.sh uninstall
set -euo pipefail
[ "$(uname -s)" = Darwin ] || { echo 'This helper requires macOS.'; exit 1; }
action="${1:-install}"
case "$action" in install|uninstall) ;; *) echo 'Usage: bash zigfs-local-setup.sh install|uninstall'; exit 1 ;; esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf '%%s' '%s' | /usr/bin/base64 -D > "$work/ca.crt"
cat > "$work/resolver" <<'RESOLVER'
%sRESOLVER
resolver=/etc/resolver/zigfs.home.arpa
if [ -L "$resolver" ] || { [ -e "$resolver" ] && ! cmp -s "$resolver" "$work/resolver"; }; then
 echo 'An existing resolver belongs to another configuration. Nothing changed.'
 exit 1
fi
fingerprint=$(/usr/bin/openssl x509 -in "$work/ca.crt" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')
echo "ZigFS CA SHA-1: $fingerprint"
echo "Action: $action. macOS will request administrator authorization."
sudo -v
if [ "$action" = install ]; then
 sudo /usr/bin/security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$work/ca.crt"
 sudo /bin/mkdir -p /etc/resolver
 sudo /usr/bin/install -o root -g wheel -m 644 "$work/resolver" "$resolver"
else
 sudo /usr/bin/security delete-certificate -Z "$fingerprint" /Library/Keychains/System.keychain || { echo 'Certificate removal failed. Resolver left unchanged.'; exit 1; }
 if [ -f "$resolver" ]; then sudo /bin/rm "$resolver"; fi
fi
sudo /usr/bin/dscacheutil -flushcache
sudo /usr/bin/killall -HUP mDNSResponder
echo 'Completed. Restart your browser, then verify HTTPS in ZigFS settings.'
`, base64.StdEncoding.EncodeToString([]byte(m.state.CA.Certificate)), resolverContents), nil
}
