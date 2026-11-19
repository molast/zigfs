//go:build windows

package gateway

import (
	"fmt"
	goruntime "runtime"
	"syscall"
	"unsafe"
)

var moveGatewayState = syscall.NewLazyDLL("kernel32.dll").NewProc("MoveFileExW")

// Windows does not support the POSIX directory Sync operation. The temporary
// file has already been flushed and closed; request write-through replacement
// on the same volume instead of returning a spurious directory-sync failure.
func replaceStateFile(source, target string) error {
	from, err := syscall.UTF16PtrFromString(source)
	if err != nil {
		return err
	}
	to, err := syscall.UTF16PtrFromString(target)
	if err != nil {
		return err
	}
	const replaceExisting = 0x1
	const writeThrough = 0x8
	result, _, callErr := moveGatewayState.Call(
		uintptr(unsafe.Pointer(from)), uintptr(unsafe.Pointer(to)), replaceExisting|writeThrough,
	)
	goruntime.KeepAlive(from)
	goruntime.KeepAlive(to)
	if result == 0 {
		return fmt.Errorf("replace gateway state: %w", callErr)
	}
	return nil
}
