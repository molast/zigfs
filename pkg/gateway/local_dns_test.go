package gateway

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

func TestLocalDNSAnswers(t *testing.T) {
	m := New(t.TempDir(), func() string { return "http://127.0.0.1:9000" })
	m.state.Candidate = &Deployment{Config: Config{AdminDomain: "admin.zigfs.home.arpa", S3Domain: "s3.zigfs.home.arpa"}}
	for _, test := range []struct {
		name    string
		kind    dnsmessage.Type
		code    dnsmessage.RCode
		answers int
	}{
		{"admin.zigfs.home.arpa.", dnsmessage.TypeA, 0, 1},
		{"S3.ZIGFS.HOME.ARPA.", dnsmessage.TypeA, 0, 1},
		{"admin.zigfs.home.arpa.", dnsmessage.TypeAAAA, 0, 0},
		{"unknown.zigfs.home.arpa.", dnsmessage.TypeA, dnsmessage.RCodeNameError, 0},
		{"example.com.", dnsmessage.TypeA, dnsmessage.RCodeNameError, 0},
	} {
		query := dnsQuery(test.name, test.kind)
		var reply dnsmessage.Message
		if err := reply.Unpack(m.dnsReply(query)); err != nil {
			t.Fatal(err)
		}
		if reply.ID != 42 || reply.RCode != test.code || len(reply.Answers) != test.answers {
			t.Fatalf("%s: %+v", test.name, reply)
		}
		if len(reply.Answers) > 0 && reply.Answers[0].Body.(*dnsmessage.AResource).A != [4]byte{127, 0, 0, 1} {
			t.Fatal("not loopback")
		}
	}
	if m.dnsReply([]byte{0, 1}) != nil {
		t.Fatal("malformed query accepted")
	}
	m.state.Candidate = nil
	var reply dnsmessage.Message
	reply.Unpack(m.dnsReply(dnsQuery("admin.zigfs.home.arpa.", dnsmessage.TypeA)))
	if reply.RCode != dnsmessage.RCodeNameError {
		t.Fatal("removed candidate still resolves")
	}
}

func dnsQuery(name string, kind dnsmessage.Type) []byte {
	q := dnsmessage.Message{Header: dnsmessage.Header{ID: 42}, Questions: []dnsmessage.Question{{Name: dnsmessage.MustNewName(name), Type: kind, Class: dnsmessage.ClassINET}}}
	result, _ := q.Pack()
	return result
}

func TestLocalDNSTransports(t *testing.T) {
	m := New(t.TempDir(), func() string { return "http://127.0.0.1:9000" })
	m.state.Active = &Deployment{Config: Config{AdminDomain: "admin.zigfs.home.arpa"}}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	address := freeAddress(t)
	done := make(chan struct{})
	go func() { m.runLocalDNS(ctx, address); close(done) }()
	deadline := time.Now().Add(time.Second)
	for !m.Status().LocalDNS.Running {
		if m.Status().LocalDNS.Error != "" {
			t.Fatal(m.Status().LocalDNS.Error)
		}
		if time.Now().After(deadline) {
			t.Fatal("DNS did not start")
		}
		time.Sleep(time.Millisecond)
	}
	for _, transport := range []string{"udp4", "tcp4"} {
		conn, err := net.DialTimeout(transport, address, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		conn.SetDeadline(time.Now().Add(time.Second))
		query := dnsQuery("admin.zigfs.home.arpa.", dnsmessage.TypeA)
		if transport == "tcp4" {
			query = append([]byte{byte(len(query) >> 8), byte(len(query))}, query...)
		}
		if _, err := conn.Write(query); err != nil {
			t.Fatal(err)
		}
		response := make([]byte, 4096)
		var n int
		if transport == "tcp4" {
			var size [2]byte
			_, err = io.ReadFull(conn, size[:])
			if err != nil {
				t.Fatal(err)
			}
			n = int(binary.BigEndian.Uint16(size[:]))
			_, err = io.ReadFull(conn, response[:n])
		} else {
			n, err = conn.Read(response)
		}
		conn.Close()
		if err != nil {
			t.Fatal(err)
		}
		var reply dnsmessage.Message
		if err := reply.Unpack(response[:n]); err != nil || len(reply.Answers) != 1 {
			t.Fatalf("%s failed: %v", transport, err)
		}
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("DNS did not stop")
	}
}
