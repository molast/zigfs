//go:build !windows

package gateway

import (
	"fmt"
	"os"
	"path/filepath"
)

func replaceStateFile(source, target string) error {
	if err := os.Rename(source, target); err != nil {
		return err
	}
	directory, err := os.Open(filepath.Dir(target))
	if err != nil {
		return err
	}
	defer directory.Close()
	if err = directory.Sync(); err != nil {
		return fmt.Errorf("gateway state renamed but directory sync failed: %w", err)
	}
	return nil
}
