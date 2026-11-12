package config

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestDotEnvLoadAndPrecedence(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".env")
	t.Setenv("ZIGFS_ENV_FILE", path)
	t.Setenv("ZIGFS_ADMIN_CONFIG", filepath.Join(dir, "listener.json"))
	if err := os.WriteFile(path, []byte("# shared file\r\nZIGFS_ROOT_PASSWORD='literal$()#=secret' # comment\r\nZIGFS_ENDPOINT='http://file.test:9000'\nZIGFS_UPSTREAM_TIMEOUT=23m # comment\n"), 0600); err != nil {
		t.Fatal(err)
	}
	values, err := readDotEnv()
	if err != nil || values["ZIGFS_ROOT_PASSWORD"] != "literal$()#=secret" {
		t.Fatalf("literal parsing failed: %v", err)
	}
	// Ensure the file itself feeds Load before testing process overrides.
	t.Setenv("ZIGFS_ENDPOINT", "")
	t.Setenv("ZIGFS_UPSTREAM_TIMEOUT", "")
	if err := os.Unsetenv("ZIGFS_ENDPOINT"); err != nil {
		t.Fatal(err)
	}
	if err := os.Unsetenv("ZIGFS_UPSTREAM_TIMEOUT"); err != nil {
		t.Fatal(err)
	}
	fileConfig, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if fileConfig.ZigEndpoint != "http://file.test:9000" || fileConfig.UpstreamTimeout != 23*time.Minute {
		t.Fatal("file values not loaded")
	}
	t.Setenv("ZIGFS_ENDPOINT", "http://process.test:9000")
	t.Setenv("ZIGFS_UPSTREAM_TIMEOUT", "25m")
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.ZigEndpoint != "http://process.test:9000" || cfg.UpstreamTimeout != 25*time.Minute {
		t.Fatal("process did not override file")
	}
}

func TestDotEnvRejectsInvalidOrMissingExplicitFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".env")
	t.Setenv("ZIGFS_ENV_FILE", path)
	if _, err := readDotEnv(); err == nil {
		t.Fatal("missing explicit file accepted")
	}
	for _, value := range []string{"lowercase=value", "ZIGFS_ENDPOINT='unclosed", "ZIGFS_ENDPOINT='closed'trailing", "server:"} {
		if err := os.WriteFile(path, []byte(value), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := readDotEnv(); err == nil {
			t.Fatal("invalid file accepted")
		}
	}
}
