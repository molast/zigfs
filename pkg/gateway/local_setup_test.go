package gateway

import (
	"os/exec"
	goruntime "runtime"
	"strings"
	"testing"
	"time"
)

func TestLocalSetupExport(t *testing.T) {
	if goruntime.GOOS != "darwin" {
		t.Skip("macOS helper")
	}
	m := New(t.TempDir(), func() string { return "http://127.0.0.1:9000" })
	if _, err := m.LocalSetup(); err == nil {
		t.Fatal("unprepared setup accepted")
	}
	ca, err := newCA(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	m.state.CA = ca
	m.state.Candidate = &Deployment{Config: Config{AdminDomain: "admin.zigfs.home.arpa", S3Domain: "s3.zigfs.home.arpa", CertificateMode: "local"}}
	script, err := m.LocalSetup()
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(script, ca.Key) || strings.Contains(script, "PRIVATE KEY") {
		t.Fatal("private key exported")
	}
	check := exec.Command("/bin/bash", "-n")
	check.Stdin = strings.NewReader(script)
	if output, err := check.CombinedOutput(); err != nil {
		t.Fatalf("shell syntax: %v %s", err, output)
	}
	m.state.Candidate.Config.AdminDomain = "admin.example.com"
	if _, err := m.LocalSetup(); err == nil {
		t.Fatal("unmanaged suffix accepted")
	}
	m.state.Candidate.Config.AdminDomain = "evil.zigfs.home.arpa;touch /tmp/test"
	if _, err := m.LocalSetup(); err == nil {
		t.Fatal("shell metacharacters accepted")
	}
}
