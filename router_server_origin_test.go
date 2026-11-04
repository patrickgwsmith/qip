package main

import (
	"crypto/tls"
	"net/http/httptest"
	"testing"
)

func TestDevRequestOrigin(t *testing.T) {
	r := httptest.NewRequest("GET", "/charts/AAPL", nil)
	r.Host = "localhost:4114"
	if got := devRequestOrigin(r); got != "http://localhost:4114" {
		t.Fatalf("got %q", got)
	}
	r.TLS = &tls.ConnectionState{}
	if got := devRequestOrigin(r); got != "https://localhost:4114" {
		t.Fatalf("got %q", got)
	}
	r.TLS = nil
	for _, bad := range []string{"", "evil.com/x", "a b", "a\r\nb"} {
		r.Host = bad
		if got := devRequestOrigin(r); got != "http://qip.local" {
			t.Fatalf("host %q: got %q", bad, got)
		}
	}
}
