package managementauth

import (
	"context"
	"net"
	"net/http"
	"strings"
)

type forwardingKey struct{}
type Forwarding struct{ For, Proto string }

// Preserve upstream hops only as assertions to be evaluated by ZigFS. Always
// append the observed socket peer and transport; never use Gin ClientIP here.
func WithForwarding(ctx context.Context, request *http.Request) context.Context {
	peer, _, err := net.SplitHostPort(request.RemoteAddr)
	if err != nil || net.ParseIP(peer) == nil {
		return ctx
	}
	proto := "http"
	if request.TLS != nil {
		proto = "https"
	}
	result := Forwarding{For: peer, Proto: proto}
	values := request.Header.Values("X-Forwarded-For")
	protocols := request.Header.Values("X-Forwarded-Proto")
	if len(values) == 1 && len(values[0]) <= 4096 {
		hops := strings.Split(values[0], ",")
		valid := len(hops) < 64
		for _, hop := range hops {
			if net.ParseIP(strings.TrimSpace(hop)) == nil {
				valid = false
			}
		}
		if valid {
			prior := make([]string, len(hops))
			for i := range prior {
				prior[i] = "http"
			}
			if len(protocols) == 1 {
				parts := strings.Split(protocols[0], ",")
				if len(parts) == len(hops) {
					for i, part := range parts {
						if strings.TrimSpace(part) == "https" {
							prior[i] = "https"
						}
					}
				}
			}
			result.For = values[0] + ", " + peer
			result.Proto = strings.Join(prior, ", ") + ", " + proto
		}
	}
	return context.WithValue(ctx, forwardingKey{}, result)
}
func Forwarded(ctx context.Context) Forwarding {
	value, _ := ctx.Value(forwardingKey{}).(Forwarding)
	return value
}
