package config

import (
	"os"
	"strings"
	"time"
)

type Config struct {
	ListenAddress   string
	ZigEndpoint     string
	WebRoot         string
	UpstreamTimeout time.Duration
}

func Load() (Config, error) {
	config := Config{
		ListenAddress:   envOrDefault("ZIGFS_ADMIN_LISTEN", ":9001"),
		ZigEndpoint:     strings.TrimRight(envOrDefault("ZIGFS_ENDPOINT", "http://127.0.0.1:9000"), "/"),
		WebRoot:         envOrDefault("ZIGFS_WEB_ROOT", "../web/dist"),
		UpstreamTimeout: 5 * time.Second,
	}
	return config, nil
}

func envOrDefault(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
