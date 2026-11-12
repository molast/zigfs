package config

import (
	"fmt"
	"os"
	"strings"
)

// readDotEnv reads literal assignments, never executing shell commands or interpolation.
func readDotEnv() (map[string]string, error) {
	path, explicit := os.LookupEnv("ZIGFS_ENV_FILE")
	if !explicit {
		path = ".env"
	}
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) && !explicit {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	values := make(map[string]string)
	for i, raw := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		key, value = strings.TrimSpace(key), strings.TrimSpace(value)
		invalid := !ok || key == ""
		for j, c := range key {
			if !(c >= 'A' && c <= 'Z' || c == '_' || j > 0 && c >= '0' && c <= '9') {
				invalid = true
			}
		}
		if invalid {
			return nil, fmt.Errorf("invalid .env assignment at line %d", i+1)
		}
		if len(value) > 0 && (value[0] == '\'' || value[0] == '"') {
			end := strings.IndexByte(value[1:], value[0])
			if end < 0 {
				return nil, fmt.Errorf("unclosed .env quote at line %d", i+1)
			}
			end++
			tail := strings.TrimSpace(value[end+1:])
			if tail != "" && !strings.HasPrefix(tail, "#") {
				return nil, fmt.Errorf("invalid .env quote at line %d", i+1)
			}
			value = value[1:end]
		} else {
			for j, c := range value {
				if c == '#' && (j == 0 || value[j-1] == ' ' || value[j-1] == '\t') {
					value = strings.TrimSpace(value[:j])
					break
				}
			}
		}
		values[key] = value
	}
	return values, nil
}
