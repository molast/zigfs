package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type Config struct {
	ListenerFile       string
	EndpointCandidates []string
	ListenAddress      string
	ZigEndpoint        string
	WebRoot            string
	UpstreamTimeout    time.Duration
}

func Load() (Config, error) {
	values, err := readDotEnv()
	if err != nil {
		return Config{}, err
	}
	envOrDefault := func(key, fallback string) string {
		if value, exists := os.LookupEnv(key); exists {
			if value == "" {
				return fallback
			}
			return value
		}
		if value, exists := values[key]; exists && value != "" {
			return value
		}
		return fallback
	}
	upstreamTimeout, err := time.ParseDuration(envOrDefault("ZIGFS_UPSTREAM_TIMEOUT", "15m"))
	if err != nil || upstreamTimeout <= 0 {
		return Config{}, fmt.Errorf("ZIGFS_UPSTREAM_TIMEOUT must be a positive Go duration")
	}
	config := Config{
		ListenAddress:   envOrDefault("ZIGFS_ADMIN_LISTEN", ":9001"),
		ZigEndpoint:     strings.TrimRight(envOrDefault("ZIGFS_ENDPOINT", "http://127.0.0.1:9000"), "/"),
		WebRoot:         envOrDefault("ZIGFS_WEB_ROOT", "../web/dist"),
		UpstreamTimeout: upstreamTimeout,
	}
	dir, err := os.UserConfigDir()
	if err != nil {
		return Config{}, err
	}
	config.ListenerFile = envOrDefault("ZIGFS_ADMIN_CONFIG", filepath.Join(dir, "zigfs-admin", "listener.json"))
	config.EndpointCandidates = []string{config.ZigEndpoint}
	if saved, err := ReadListenerState(config.ListenerFile); err == nil {
		config.ListenAddress = saved.AdminListenAddress
		config.EndpointCandidates = saved.Endpoints
		config.ZigEndpoint = saved.Endpoints[0]
	} else if !errors.Is(err, os.ErrNotExist) {
		return Config{}, err
	}
	return config, nil
}
