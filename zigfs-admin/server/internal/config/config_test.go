package config

import (
	"testing"
	"time"
)

func TestLoadUsesMultipartSafeUpstreamTimeout(t *testing.T) {
	t.Setenv("ZIGFS_UPSTREAM_TIMEOUT", "")
	config, err := Load()
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	if config.UpstreamTimeout != 15*time.Minute {
		t.Fatalf("unexpected default timeout: %s", config.UpstreamTimeout)
	}

	t.Setenv("ZIGFS_UPSTREAM_TIMEOUT", "45m")
	config, err = Load()
	if err != nil {
		t.Fatalf("load configured timeout: %v", err)
	}
	if config.UpstreamTimeout != 45*time.Minute {
		t.Fatalf("unexpected configured timeout: %s", config.UpstreamTimeout)
	}
}

func TestLoadRejectsInvalidUpstreamTimeout(t *testing.T) {
	t.Setenv("ZIGFS_UPSTREAM_TIMEOUT", "0s")
	if _, err := Load(); err == nil {
		t.Fatal("expected invalid timeout error")
	}
}
