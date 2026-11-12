package config

import (
	"path/filepath"
	"testing"
)

func TestListenerPersistenceAndStartup(t *testing.T) {
	path := filepath.Join(t.TempDir(), "admin", "listener.json")
	state := ListenerState{AdminListenAddress: "127.0.0.1:19001", Endpoints: []string{"http://127.0.0.1:19000", "http://127.0.0.1:29000"}}
	if err := SaveListenerState(path, state); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ZIGFS_ADMIN_CONFIG", path)
	t.Setenv("ZIGFS_ADMIN_LISTEN", ":9001")
	got, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if got.ListenAddress != state.AdminListenAddress || len(got.EndpointCandidates) != 2 {
		t.Fatal(got)
	}
	for _, bad := range []string{"host:12", "127.0.0.1:0", "[::1]:65536"} {
		if ValidateListenAddress(bad) == nil {
			t.Fatalf("accepted %q", bad)
		}
	}
	for _, bad := range []string{"file:///tmp", "http://user:pass@localhost", "http://localhost/path"} {
		if ValidateEndpoint(bad) == nil {
			t.Fatalf("accepted %q", bad)
		}
	}
}
