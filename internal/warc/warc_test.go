package warc

import (
	"bytes"
	"net/http"
	"strconv"
	"strings"
	"testing"
)

func TestBuildHTTPResponseRecordIsDeterministicAndValid(t *testing.T) {
	headers := http.Header{
		"Content-Type":   []string{"text/plain; charset=utf-8"},
		"Content-Length": []string{"999"},
		"X-Extension":    []string{"kept"},
	}
	first, err := BuildHTTPResponseRecord("http://qip.local/a", http.StatusOK, headers, []byte("hello"))
	if err != nil {
		t.Fatal(err)
	}
	second, err := BuildHTTPResponseRecord("http://qip.local/a", http.StatusOK, headers, []byte("hello"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first, second) {
		t.Fatal("WARC response record is not reproducible")
	}
	if err := ValidateArchive(first); err != nil {
		t.Fatalf("ValidateArchive: %v", err)
	}
	for _, want := range [][]byte{
		[]byte("WARC/1.1\r\n"),
		[]byte("WARC-Date: " + CaptureTime + "\r\n"),
		[]byte("WARC-Record-ID: <urn:uuid:"),
		[]byte("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n"),
		[]byte("\r\nhello\r\n\r\n"),
		[]byte("X-Extension: kept\r\n"),
	} {
		if !bytes.Contains(first, want) {
			t.Fatalf("record is missing %q", want)
		}
	}
}

func TestValidateArchiveRejectsMissingMandatoryFields(t *testing.T) {
	archive := []byte("WARC/1.1\r\nWARC-Type: response\r\nContent-Length: 0\r\n\r\n\r\n\r\n")
	if err := ValidateArchive(archive); err == nil {
		t.Fatal("expected missing mandatory field error")
	}
}

func TestBuildHTTPResponseRecordIncludesPayloadDigest(t *testing.T) {
	record, err := BuildHTTPResponseRecord("http://qip.local/a", http.StatusOK, nil, []byte("hello"))
	if err != nil {
		t.Fatal(err)
	}
	want := "WARC-Payload-Digest: sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824\r\n"
	if !bytes.Contains(record, []byte(want)) {
		t.Fatalf("record is missing %q", want)
	}
}

func TestPayloadDigesterFillsMissingAndRejectsStaleDigests(t *testing.T) {
	payload := "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
	missing := []byte("WARC/1.1\r\nWARC-Type: response\r\nWARC-Target-URI: http://qip.local/a\r\nWARC-Date: " + CaptureTime + "\r\nWARC-Record-ID: <urn:uuid:a>\r\nContent-Length: " + strconv.Itoa(len(payload)) + "\r\n\r\n" + payload + "\r\n\r\n")
	digester := NewPayloadDigester()
	filled, err := digester.Apply(missing)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(filled, []byte("Content-Length: 43\r\nWARC-Payload-Digest: "+PayloadDigest([]byte("hello"))+"\r\n\r\n")) {
		t.Fatalf("digest was not added:\n%s", filled)
	}
	if err := ValidateArchive(filled); err != nil {
		t.Fatal(err)
	}
	again, err := digester.Apply(filled)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(again, filled) {
		t.Fatal("digested archive changed on second pass")
	}
	stale := bytes.Replace(filled, []byte("hello\r\n\r\n"), []byte("HELLO\r\n\r\n"), 1)
	if _, err := digester.Apply(stale); err == nil || !strings.Contains(err.Error(), "http://qip.local/a") {
		t.Fatalf("expected stale digest error naming the record, got %v", err)
	}
}

func TestPayloadDigesterAcceptsBase32Digests(t *testing.T) {
	payload := "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
	record := []byte("WARC/1.1\r\nWARC-Type: response\r\nWARC-Date: " + CaptureTime + "\r\nWARC-Record-ID: <urn:uuid:a>\r\nWARC-Payload-Digest: sha256:FTZE3OS7WCRQ4JXIHMVMLOPCTYNRMHS4D6TUEXTTAQZWFE4LTASA\r\nContent-Length: " + strconv.Itoa(len(payload)) + "\r\n\r\n" + payload + "\r\n\r\n")
	out, err := NewPayloadDigester().Apply(record)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(out, record) {
		t.Fatal("existing base32 digest was rewritten")
	}
}

func TestRemoveResponseRecordsKeepsOtherRecords(t *testing.T) {
	var archive []byte
	for _, target := range []string{"http://qip.local/", "http://qip.local/blog", "http://qip.local/blog/post"} {
		record, err := BuildHTTPResponseRecord(target, http.StatusOK, http.Header{"Content-Type": []string{"text/html"}}, []byte(target))
		if err != nil {
			t.Fatal(err)
		}
		archive = append(archive, record...)
	}
	out, err := RemoveResponseRecords(archive, map[string]struct{}{"http://qip.local/": {}, "http://qip.local/blog": {}})
	if err != nil {
		t.Fatal(err)
	}
	if err := ValidateArchive(out); err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(out, []byte("WARC-Target-URI: http://qip.local/blog\r\n")) || bytes.Contains(out, []byte("WARC-Target-URI: http://qip.local/\r\n")) {
		t.Fatalf("expected removed records to be gone:\n%s", out)
	}
	if !bytes.Contains(out, []byte("WARC-Target-URI: http://qip.local/blog/post\r\n")) {
		t.Fatalf("expected kept record:\n%s", out)
	}
}
