package gateway

import (
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/pem"
	"os"
	"os/exec"
	"path/filepath"
	goruntime "runtime"
	"strings"
	"testing"
	"time"
	"unicode/utf16"
)

func windowsSetupFixture(t *testing.T) (*Manager, string) {
	t.Helper()
	m := New(t.TempDir(), func() string { return "http://localhost:9000" })
	ca, err := newCA(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	m.state.CA = ca
	m.state.Candidate = &Deployment{Config: Config{AdminDomain: "admin.zigfs.home.arpa", S3Domain: "s3.zigfs.home.arpa", CertificateMode: "local"}}
	script, err := m.WindowsSetup()
	if err != nil {
		t.Fatal(err)
	}
	return m, script
}

func TestWindowsHelperExportsPublicCAAndRejectsInvalidConfig(t *testing.T) {
	m, script := windowsSetupFixture(t)
	block, _ := pem.Decode([]byte(m.state.CA.Certificate))
	if !strings.Contains(script, base64.StdEncoding.EncodeToString(block.Bytes)) {
		t.Fatal("incorrect public CA")
	}
	if strings.Contains(script, m.state.CA.Key) || strings.Contains(script, "PRIVATE KEY") || strings.Contains(script, "__CA_DER__") {
		t.Fatal("unsafe or incomplete export")
	}
	m.state.Candidate.Config.AdminDomain = "bad.zigfs.home.arpa';exit;#"
	if _, err := m.WindowsSetup(); err == nil {
		t.Fatal("accepted script injection")
	}
	m.state.Candidate.Config.AdminDomain = "admin.example.com"
	if _, err := m.WindowsSetup(); err == nil {
		t.Fatal("accepted unmanaged domain")
	}
	m.state.Candidate = nil
	if _, err := m.WindowsSetup(); err == nil {
		t.Fatal("accepted missing deployment")
	}
}

func TestWindowsHostsStatusRequiresMatchingCAAndNames(t *testing.T) {
	m, _ := windowsSetupFixture(t)
	config := m.state.Candidate.Config
	ca := m.state.CA.Certificate
	block, _ := pem.Decode([]byte(ca))
	content := "# BEGIN ZigFS Local HTTPS\n# CA SHA-256: " + strings.ToUpper(fingerprint(block.Bytes)) + "\n127.0.0.1 " + config.AdminDomain + "\n127.0.0.1 " + config.S3Domain + "\n# END ZigFS Local HTTPS"
	for _, text := range []string{content, "# existing\r\n" + strings.ReplaceAll(content, "\n", "\r\n") + "\r\n", "\ufeff" + content} {
		if !windowsHostsConfigured([]byte(text), config, ca) {
			t.Fatal("valid block not detected")
		}
	}
	units := utf16.Encode([]rune(content))
	data := []byte{0xff, 0xfe}
	for _, unit := range units {
		data = binary.LittleEndian.AppendUint16(data, unit)
	}
	if !windowsHostsConfigured(data, config, ca) {
		t.Fatal("UTF-16 not detected")
	}
	for _, text := range []string{content + "\n" + content, strings.Replace(content, "127.0.0.1", "192.0.2.1", 1), strings.Replace(content, config.AdminDomain, "other.zigfs.home.arpa", 1)} {
		if windowsHostsConfigured([]byte(text), config, ca) {
			t.Fatal("invalid block accepted")
		}
	}
	other, err := newCA(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if windowsHostsConfigured([]byte(content), config, other.Certificate) {
		t.Fatal("another CA accepted")
	}
}

func TestWindowsHelperPowerShellSyntax(t *testing.T) {
	if goruntime.GOOS != "windows" {
		t.Skip("requires Windows PowerShell")
	}
	_, script := windowsSetupFixture(t)
	path := filepath.Join(t.TempDir(), "zigfs-local-setup.ps1")
	if err := os.WriteFile(path, []byte(script), 0600); err != nil {
		t.Fatal(err)
	}
	command := exec.Command("powershell.exe", "-NoProfile", "-Command", `$tokens=$null; $errors=$null; [System.Management.Automation.Language.Parser]::ParseFile($env:ZIGFS_PARSE_SCRIPT,[ref]$tokens,[ref]$errors) | Out-Null; if ($errors.Count -gt 0) { $errors | Out-String | Write-Output; exit 1 }`)
	command.Env = append(os.Environ(), "ZIGFS_PARSE_SCRIPT="+path)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("PowerShell parser: %v %s", err, output)
	}
}

// Execute the exported helper on Windows, but redirect hosts into a temporary
// fixture and use only the test user's root store. Never touch system hosts or
// request UAC from automated tests. Elevation itself remains a manual check.
func TestWindowsHelperInstallAndUninstall(t *testing.T) {
	if goruntime.GOOS != "windows" {
		t.Skip("requires Windows PowerShell")
	}
	m, script := windowsSetupFixture(t)
	directory := t.TempDir()
	hosts := filepath.Join(directory, "hosts")
	original := "# unrelated configuration\r\n127.0.0.1 localhost\r\n"
	if err := os.WriteFile(hosts, []byte(original), 0600); err != nil {
		t.Fatal(err)
	}
	script = strings.Replace(script,
		"if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {",
		"if ($false) {", 1)
	script = strings.Replace(script,
		"$hostsPath = Join-Path $env:SystemRoot 'System32\\drivers\\etc\\hosts'",
		"$hostsPath = '"+strings.ReplaceAll(hosts, "'", "''")+"'", 1)
	script = strings.Replace(script, "X509Store('Root', 'LocalMachine')", "X509Store('Root', 'CurrentUser')", 1)
	script = strings.Replace(script, `& "$env:SystemRoot\System32\ipconfig.exe" /flushdns`, "$global:LASTEXITCODE = 0", 1)
	if strings.Contains(script, "Join-Path $env:SystemRoot 'System32\\drivers\\etc\\hosts'") ||
		strings.Contains(script, "X509Store('Root', 'LocalMachine')") {
		t.Fatal("test system-operation substitution failed")
	}
	path := filepath.Join(directory, "helper.ps1")
	if err := os.WriteFile(path, []byte(script), 0600); err != nil {
		t.Fatal(err)
	}
	caBlock, _ := pem.Decode([]byte(m.state.CA.Certificate))
	digest := sha1.Sum(caBlock.Bytes)
	thumb := strings.ToUpper(hex.EncodeToString(digest[:]))
	t.Cleanup(func() {
		command := exec.Command("powershell.exe", "-NoProfile", "-Command",
			"Remove-Item -LiteralPath 'Cert:\\CurrentUser\\Root\\"+thumb+"' -ErrorAction SilentlyContinue")
		command.Run()
	})
	run := func(action string, succeeds bool) {
		t.Helper()
		command := exec.Command("powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path, "-Action", action)
		output, err := command.CombinedOutput()
		if (err == nil) != succeeds {
			t.Fatalf("%s: %v %s", action, err, output)
		}
	}
	read := func() []byte {
		t.Helper()
		data, err := os.ReadFile(hosts)
		if err != nil {
			t.Fatal(err)
		}
		return data
	}
	assertTrusted := func(expected bool) {
		t.Helper()
		command := exec.Command("powershell.exe", "-NoProfile", "-Command",
			"if (Test-Path -LiteralPath 'Cert:\\CurrentUser\\Root\\"+thumb+"') { exit 0 } else { exit 1 }")
		if (command.Run() == nil) != expected {
			t.Fatal("unexpected test CA trust state")
		}
	}
	run("install", true)
	assertTrusted(true)
	installed := read()
	if !strings.HasPrefix(string(installed), original) ||
		!windowsHostsConfigured(installed, m.state.Candidate.Config, m.state.CA.Certificate) {
		t.Fatal("install did not preserve existing records or create valid mapping")
	}
	run("install", true)
	if string(read()) != string(installed) {
		t.Fatal("repeat install is not idempotent")
	}
	changed := strings.Replace(string(installed), "127.0.0.1 admin.zigfs.home.arpa", "192.0.2.5 admin.zigfs.home.arpa", 1)
	if err := os.WriteFile(hosts, []byte(changed), 0600); err != nil {
		t.Fatal(err)
	}
	run("uninstall", false)
	if string(read()) != changed {
		t.Fatal("overwrote manually edited mapping")
	}
	if err := os.WriteFile(hosts, installed, 0600); err != nil {
		t.Fatal(err)
	}
	run("uninstall", true)
	assertTrusted(false)
	if strings.Contains(string(read()), "BEGIN ZigFS") || !strings.HasPrefix(string(read()), original) {
		t.Fatal("uninstall did not preserve unrelated hosts records")
	}
	run("uninstall", true)
	conflict := original + "192.0.2.1 admin.zigfs.home.arpa\r\n"
	if err := os.WriteFile(hosts, []byte(conflict), 0600); err != nil {
		t.Fatal(err)
	}
	run("install", false)
	assertTrusted(false)
	if string(read()) != conflict {
		t.Fatal("overwrote preexisting conflicting entry")
	}
}
