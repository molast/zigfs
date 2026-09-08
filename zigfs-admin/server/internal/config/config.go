package config

import (
	"fmt"
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
	upstreamTimeout, err := durationEnvOrDefault("ZIGFS_UPSTREAM_TIMEOUT", 15*time.Minute)
	if err != nil {
		return Config{}, err
	}
	config := Config{
		ListenAddress:   envOrDefault("ZIGFS_ADMIN_LISTEN", ":9001"),
		ZigEndpoint:     strings.TrimRight(envOrDefault("ZIGFS_ENDPOINT", "http://127.0.0.1:9000"), "/"),
		WebRoot:         envOrDefault("ZIGFS_WEB_ROOT", "../web/dist"),
		UpstreamTimeout: upstreamTimeout,
	}
	return config, nil
}

func envOrDefault(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func durationEnvOrDefault(key string, fallback time.Duration) (time.Duration, error) {
	value := os.Getenv(key)
	if value == "" {
		return fallback, nil
	}
	duration, err := time.ParseDuration(value)
	if err != nil || duration <= 0 {
		return 0, fmt.Errorf("%s must be a positive Go duration", key)
	}
	return duration, nil
}
