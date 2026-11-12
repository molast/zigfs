package managementauth

import (
	"context"
	"crypto/tls"
	"net/http/httptest"
	"testing"
)

func TestForwardingAppendsObservedPeer(t *testing.T) {
	request := httptest.NewRequest("GET", "/", nil)
	request.RemoteAddr = "192.0.2.10:1234"
	request.Header.Set("X-Forwarded-For", "198.51.100.9")
	request.Header.Set("X-Forwarded-Proto", "https")
	got := Forwarded(WithForwarding(context.Background(), request))
	if got.For != "198.51.100.9, 192.0.2.10" || got.Proto != "https, http" {
		t.Fatal(got)
	}
	request.TLS = &tls.ConnectionState{}
	request.Header.Add("X-Forwarded-For", "spoof")
	got = Forwarded(WithForwarding(context.Background(), request))
	if got.For != "192.0.2.10" || got.Proto != "https" {
		t.Fatal(got)
	}
}
func TestForwardingRejectsMisalignedProtocolAssertions(t *testing.T) {
	request := httptest.NewRequest("GET", "/", nil)
	request.RemoteAddr = "[::1]:1234"
	request.Header.Set("X-Forwarded-For", "198.51.100.9, 10.0.0.2")
	request.Header.Set("X-Forwarded-Proto", "https")
	got := Forwarded(WithForwarding(context.Background(), request))
	if got.Proto != "http, http, http" || got.For != "198.51.100.9, 10.0.0.2, ::1" {
		t.Fatal(got)
	}
}
