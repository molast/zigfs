package config

import (
	"encoding/json"
	"errors"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
)

type ListenerState struct {
	AdminListenAddress string   `json:"admin_listen_address"`
	Endpoints          []string `json:"endpoints"`
}

func ValidateListenAddress(value string) error {
	host, port, err := net.SplitHostPort(value)
	if err != nil {
		return errors.New("InvalidListenAddress")
	}
	if host != "" && net.ParseIP(host) == nil {
		return errors.New("InvalidListenAddress")
	}
	n, err := strconv.Atoi(port)
	if err != nil || n < 1 || n > 65535 {
		return errors.New("InvalidListenAddress")
	}
	return nil
}
func ValidateEndpoint(value string) error {
	u, err := url.Parse(value)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" {
		return errors.New("InvalidUpstreamEndpoint")
	}
	if port := u.Port(); port != "" {
		n, err := strconv.Atoi(port)
		if err != nil || n < 1 || n > 65535 {
			return errors.New("InvalidUpstreamEndpoint")
		}
	}
	return nil
}
func ReadListenerState(path string) (ListenerState, error) {
	var value ListenerState
	bytes, err := os.ReadFile(path)
	if err != nil {
		return value, err
	}
	if len(bytes) > 16384 {
		return value, errors.New("listener configuration too large")
	}
	if err = json.Unmarshal(bytes, &value); err != nil {
		return value, err
	}
	if err = ValidateListenAddress(value.AdminListenAddress); err != nil {
		return value, err
	}
	if len(value.Endpoints) == 0 || len(value.Endpoints) > 2 {
		return value, errors.New("invalid endpoint candidates")
	}
	for _, endpoint := range value.Endpoints {
		if err = ValidateEndpoint(endpoint); err != nil {
			return value, err
		}
	}
	return value, nil
}
func SaveListenerState(path string, value ListenerState) error {
	if err := ValidateListenAddress(value.AdminListenAddress); err != nil {
		return err
	}
	for _, endpoint := range value.Endpoints {
		if err := ValidateEndpoint(endpoint); err != nil {
			return err
		}
	}
	bytes, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".listener-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if _, err = file.Write(bytes); err != nil {
		return err
	}
	if err = file.Sync(); err != nil {
		return err
	}
	if err = file.Close(); err != nil {
		return err
	}
	if err = os.Rename(file.Name(), path); err != nil {
		return err
	}
	dir, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
