package gateway

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	goruntime "runtime"
	"strings"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

const localDNSAddress = "127.0.0.1:15353"

// RunLocalDNS serves only configured home.arpa names on the local machine.
// Both transports are required by system resolvers. It never forwards queries.
func (m *Manager) RunLocalDNS(ctx context.Context) {
	if goruntime.GOOS != "darwin" {
		return
	}
	m.runLocalDNS(ctx, localDNSAddress)
}

func (m *Manager) runLocalDNS(ctx context.Context, address string) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	udp, err := net.ListenPacket("udp4", address)
	if err != nil {
		m.setDNSError(err)
		return
	}
	defer udp.Close()
	tcp, err := net.Listen("tcp4", address)
	if err != nil {
		m.setDNSError(err)
		return
	}
	defer tcp.Close()
	m.mu.Lock()
	m.dnsRunning = true
	m.dnsError = ""
	m.mu.Unlock()
	defer func() {
		m.mu.Lock()
		m.dnsRunning = false
		m.mu.Unlock()
	}()
	go func() {
		<-ctx.Done()
		udp.Close()
		tcp.Close()
	}()
	slots := make(chan struct{}, 32)
	go func() {
		for {
			conn, err := tcp.Accept()
			if err != nil {
				return
			}
			select {
			case slots <- struct{}{}:
			default:
				conn.Close()
				continue
			}
			go func() {
				defer func() { <-slots }()
				defer conn.Close()
				conn.SetDeadline(time.Now().Add(3 * time.Second))
				var size [2]byte
				if _, err := io.ReadFull(conn, size[:]); err != nil {
					return
				}
				request := make([]byte, int(binary.BigEndian.Uint16(size[:])))
				if _, err := io.ReadFull(conn, request); err != nil {
					return
				}
				response := m.dnsReply(request)
				if response == nil {
					return
				}
				binary.BigEndian.PutUint16(size[:], uint16(len(response)))
				conn.Write(append(size[:], response...))
			}()
		}
	}()
	buffer := make([]byte, 4096)
	for {
		n, peer, err := udp.ReadFrom(buffer)
		if err != nil {
			return
		}
		if response := m.dnsReply(buffer[:n]); response != nil {
			udp.WriteTo(response, peer)
		}
	}
}

func (m *Manager) setDNSError(err error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.dnsError = err.Error()
}

func localDomain(domain string) bool {
	return validDomain(domain) && strings.HasSuffix(domain, ".zigfs.home.arpa")
}

func (m *Manager) dnsReply(packet []byte) []byte {
	var request dnsmessage.Message
	if request.Unpack(packet) != nil || request.Response || request.OpCode != 0 || len(request.Questions) != 1 {
		return nil
	}
	question := request.Questions[0]
	name := strings.ToLower(strings.TrimSuffix(question.Name.String(), "."))
	known := false
	var answer [4]byte
	m.mu.Lock()
	for _, deployment := range []*Deployment{m.state.Candidate, m.state.Active} {
		if deployment != nil && localDomain(name) && (name == deployment.Config.AdminDomain || name == deployment.Config.S3Domain) {
			target := net.ParseIP(deployment.Config.DNSAddress()).To4()
			if target != nil {
				copy(answer[:], target)
				known = true
			}
			break
		}
	}
	m.mu.Unlock()
	response := dnsmessage.Message{Header: dnsmessage.Header{ID: request.ID, Response: true, Authoritative: true, RecursionDesired: request.RecursionDesired}, Questions: request.Questions}
	if !known || question.Class != dnsmessage.ClassINET {
		response.RCode = dnsmessage.RCodeNameError
	} else if question.Type == dnsmessage.TypeA {
		response.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: question.Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 5}, Body: &dnsmessage.AResource{A: answer}}}
	}
	// AAAA returns NODATA: the HTTPS listener may be IPv4-only.
	result, err := response.Pack()
	if err != nil {
		return nil
	}
	return result
}
