package config

import (
	"errors"
	"os"
	"strings"
	"time"
)

type Config struct {
	ListenAddress   string
	ZigEndpoint     string
	ZigAdminToken   string
	WebAdminToken   string
	WebRoot         string
	UpstreamTimeout time.Duration
}

func Load() (Config, error) {
	config := Config{
		ListenAddress:   envOrDefault("ZIGFS_ADMIN_LISTEN", ":9001"),
		ZigEndpoint:     strings.TrimRight(envOrDefault("ZIGFS_ENDPOINT", "http://127.0.0.1:9000"), "/"),
		ZigAdminToken:   os.Getenv("ZIGFS_ADMIN_TOKEN"),
		WebAdminToken:   os.Getenv("ZIGFS_WEB_ADMIN_TOKEN"),
		WebRoot:         envOrDefault("ZIGFS_WEB_ROOT", "../web/dist"),
		UpstreamTimeout: 5 * time.Second,
	}

	if config.WebAdminToken == "" {
		return Config{}, errors.New("ZIGFS_WEB_ADMIN_TOKEN is required")
	}
	return config, nil
}

func envOrDefault(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
