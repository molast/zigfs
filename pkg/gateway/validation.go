package gateway

import (
	"errors"
	"net"
	"net/url"
	"strconv"
)

func validateListenAddress(value string) error {
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
func validateEndpoint(value string) error {
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
