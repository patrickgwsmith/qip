package warc

import (
	"bytes"
	"crypto/sha256"
	"encoding/base32"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"net/textproto"
	"sort"
	"strconv"
	"strings"
)

const (
	Version            = "WARC/1.1"
	CaptureTime        = "2000-01-01T00:00:00Z"
	PayloadDigestField = "WARC-Payload-Digest"
)

// PayloadDigest returns the labelled SHA-256 digest of an HTTP body or
// resource block, as lowercase hex.
func PayloadDigest(payload []byte) string {
	sum := sha256.Sum256(payload)
	return "sha256:" + hex.EncodeToString(sum[:])
}

// PayloadDigester adds a sha256 WARC-Payload-Digest to every response and
// resource record that lacks one, and rejects records whose sha256 digest no
// longer matches their payload. Payloads unchanged since the previous Apply
// are compared byte-for-byte instead of being hashed again.
type PayloadDigester struct {
	verified map[string][]byte
}

func NewPayloadDigester() *PayloadDigester {
	return &PayloadDigester{}
}

func (d *PayloadDigester) Apply(archive []byte) ([]byte, error) {
	verified := make(map[string][]byte, len(d.verified))
	var out []byte
	copied := 0
	cursor := 0
	recordNumber := 0
	for cursor < len(archive) {
		recordNumber++
		headerEnd := bytes.Index(archive[cursor:], []byte("\r\n\r\n"))
		if headerEnd < 0 {
			return nil, fmt.Errorf("WARC record %d is missing its header terminator", recordNumber)
		}
		headerEnd += cursor
		contentLength := -1
		warcType := ""
		targetURI := ""
		digest := ""
		haveDigest := false
		for _, line := range bytes.Split(archive[cursor:headerEnd], []byte("\r\n"))[1:] {
			colon := bytes.IndexByte(line, ':')
			if colon <= 0 || line[0] == ' ' || line[0] == '\t' {
				continue
			}
			name := strings.TrimSpace(string(line[:colon]))
			value := strings.TrimSpace(string(line[colon+1:]))
			switch {
			case strings.EqualFold(name, "Content-Length"):
				n, err := strconv.Atoi(value)
				if err != nil || n < 0 {
					return nil, fmt.Errorf("WARC record %d has invalid Content-Length %q", recordNumber, value)
				}
				contentLength = n
			case strings.EqualFold(name, "WARC-Type"):
				warcType = value
			case strings.EqualFold(name, "WARC-Target-URI"):
				targetURI = value
			case strings.EqualFold(name, PayloadDigestField):
				haveDigest = true
				digest = value
			}
		}
		if contentLength < 0 {
			return nil, fmt.Errorf("WARC record %d is missing content-length", recordNumber)
		}
		blockStart := headerEnd + 4
		blockEnd := blockStart + contentLength
		if blockEnd > len(archive) {
			return nil, fmt.Errorf("WARC record %d block exceeds the archive", recordNumber)
		}
		next := min(blockEnd+4, len(archive))

		var payload []byte
		switch strings.ToLower(warcType) {
		case "response":
			block := archive[blockStart:blockEnd]
			if _, after, ok := bytes.Cut(block, []byte("\r\n\r\n")); ok {
				payload = after
			}
		case "resource":
			payload = archive[blockStart:blockEnd]
		}
		if payload == nil {
			cursor = next
			continue
		}

		algorithm, value, _ := strings.Cut(digest, ":")
		switch {
		case haveDigest && strings.EqualFold(algorithm, "sha256"):
			key := value
			if previous, ok := d.verified[key]; !ok || !bytes.Equal(previous, payload) {
				sum := sha256.Sum256(payload)
				if !digestValueMatches(value, sum[:]) {
					return nil, fmt.Errorf("WARC record %d %s has a %s that does not match its payload", recordNumber, targetURI, PayloadDigestField)
				}
			}
			verified[key] = payload
		case haveDigest:
			// Leave other algorithms alone; a record carries one payload digest.
		default:
			labelled := PayloadDigest(payload)
			verified[strings.TrimPrefix(labelled, "sha256:")] = payload
			if out == nil {
				out = make([]byte, 0, len(archive)+(len(archive)/1024))
			}
			out = append(out, archive[copied:headerEnd]...)
			out = append(out, "\r\n"+PayloadDigestField+": "+labelled...)
			copied = headerEnd
		}
		cursor = next
	}
	d.verified = verified
	if out == nil {
		return archive, nil
	}
	return append(out, archive[copied:]...), nil
}

// digestValueMatches accepts hex, base32 or base64 digest values, since WARC
// does not fix an encoding for sha256.
func digestValueMatches(value string, sum []byte) bool {
	if decoded, err := hex.DecodeString(value); err == nil {
		return bytes.Equal(decoded, sum)
	}
	trimmed := strings.TrimRight(value, "=")
	if decoded, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(strings.ToUpper(trimmed)); err == nil {
		return bytes.Equal(decoded, sum)
	}
	if decoded, err := base64.RawStdEncoding.DecodeString(trimmed); err == nil {
		return bytes.Equal(decoded, sum)
	}
	if decoded, err := base64.RawURLEncoding.DecodeString(trimmed); err == nil {
		return bytes.Equal(decoded, sum)
	}
	return false
}

func BuildHTTPResponseRecord(targetURI string, statusCode int, headers http.Header, body []byte) ([]byte, error) {
	targetURI = strings.TrimSpace(targetURI)
	if targetURI == "" {
		return nil, errors.New("target URI must not be empty")
	}
	payload := buildHTTPResponsePayload(statusCode, headers, body)
	recordID := deterministicRecordID(targetURI, payload)

	var buf bytes.Buffer
	buf.WriteString(Version + "\r\n")
	buf.WriteString("WARC-Type: response\r\n")
	buf.WriteString("WARC-Target-URI: " + targetURI + "\r\n")
	buf.WriteString("WARC-Date: " + CaptureTime + "\r\n")
	buf.WriteString("WARC-Record-ID: " + recordID + "\r\n")
	buf.WriteString(PayloadDigestField + ": " + PayloadDigest(body) + "\r\n")
	buf.WriteString("Content-Type: application/http; msgtype=response\r\n")
	buf.WriteString("Content-Length: " + strconv.Itoa(len(payload)) + "\r\n\r\n")
	buf.Write(payload)
	buf.WriteString("\r\n\r\n")
	return buf.Bytes(), nil
}

func buildHTTPResponsePayload(statusCode int, source http.Header, body []byte) []byte {
	if statusCode == 0 {
		statusCode = http.StatusOK
	}
	statusText := http.StatusText(statusCode)
	if statusText == "" {
		statusText = "Status"
	}

	headers := source.Clone()
	if headers == nil {
		headers = make(http.Header)
	}
	headers.Del("Transfer-Encoding")
	headers.Set("Content-Length", strconv.Itoa(len(body)))

	keys := make([]string, 0, len(headers))
	for key := range headers {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	var payload bytes.Buffer
	fmt.Fprintf(&payload, "HTTP/1.1 %d %s\r\n", statusCode, statusText)
	for _, key := range keys {
		for _, value := range headers[key] {
			payload.WriteString(key + ": " + value + "\r\n")
		}
	}
	payload.WriteString("\r\n")
	payload.Write(body)
	return payload.Bytes()
}

func deterministicRecordID(targetURI string, payload []byte) string {
	hash := sha256.New()
	hash.Write([]byte("qip:warc-response:v1\x00"))
	hash.Write([]byte(targetURI))
	hash.Write([]byte{0})
	hash.Write(payload)
	sum := hash.Sum(nil)
	raw := append([]byte(nil), sum[:16]...)
	raw[6] = (raw[6] & 0x0f) | 0x80
	raw[8] = (raw[8] & 0x3f) | 0x80
	return fmt.Sprintf(
		"<urn:uuid:%x-%x-%x-%x-%x>",
		raw[0:4], raw[4:6], raw[6:8], raw[8:10], raw[10:16],
	)
}

func ValidateArchive(archive []byte) error {
	if len(archive) == 0 {
		return errors.New("WARC archive is empty")
	}
	cursor := 0
	recordNumber := 0
	for cursor < len(archive) {
		recordNumber++
		headerEnd := bytes.Index(archive[cursor:], []byte("\r\n\r\n"))
		if headerEnd < 0 {
			return fmt.Errorf("WARC record %d is missing its header terminator", recordNumber)
		}
		headerEnd += cursor
		lines := bytes.Split(archive[cursor:headerEnd], []byte("\r\n"))
		if len(lines) == 0 || string(lines[0]) != Version {
			return fmt.Errorf("WARC record %d must use %s", recordNumber, Version)
		}

		required := map[string]bool{
			"warc-type":      false,
			"warc-record-id": false,
			"warc-date":      false,
			"content-length": false,
		}
		contentLength := -1
		warcType := ""
		havePreviousField := false
		for _, line := range lines[1:] {
			if len(line) > 0 && (line[0] == ' ' || line[0] == '\t') {
				if !havePreviousField {
					return fmt.Errorf("WARC record %d has an orphaned continuation line", recordNumber)
				}
				continue
			}
			colon := bytes.IndexByte(line, ':')
			if colon <= 0 {
				return fmt.Errorf("WARC record %d has an invalid named field", recordNumber)
			}
			havePreviousField = true
			name := strings.ToLower(strings.TrimSpace(string(line[:colon])))
			value := strings.TrimSpace(string(line[colon+1:]))
			if _, ok := required[name]; ok {
				if required[name] {
					return fmt.Errorf("WARC record %d repeats %s", recordNumber, name)
				}
				required[name] = true
			}
			switch name {
			case "content-length":
				n, err := strconv.Atoi(value)
				if err != nil || n < 0 {
					return fmt.Errorf("WARC record %d has invalid Content-Length %q", recordNumber, value)
				}
				contentLength = n
			case "warc-type":
				warcType = value
			case "warc-record-id":
				if len(value) < 3 || value[0] != '<' || value[len(value)-1] != '>' || !strings.Contains(value, ":") {
					return fmt.Errorf("WARC record %d has invalid WARC-Record-ID %q", recordNumber, value)
				}
			case "warc-date":
				if !strings.HasSuffix(value, "Z") || !strings.Contains(value, "T") {
					return fmt.Errorf("WARC record %d has invalid WARC-Date %q", recordNumber, value)
				}
			}
		}
		for name, present := range required {
			if !present {
				return fmt.Errorf("WARC record %d is missing %s", recordNumber, name)
			}
		}

		blockStart := headerEnd + 4
		blockEnd := blockStart + contentLength
		if blockEnd > len(archive) {
			return fmt.Errorf("WARC record %d block exceeds the archive", recordNumber)
		}
		if blockEnd+4 > len(archive) || !bytes.Equal(archive[blockEnd:blockEnd+4], []byte("\r\n\r\n")) {
			return fmt.Errorf("WARC record %d is missing its trailing CRLF pair", recordNumber)
		}
		if strings.EqualFold(warcType, "response") {
			if err := validateHTTPPayload(archive[blockStart:blockEnd]); err != nil {
				return fmt.Errorf("WARC record %d: %w", recordNumber, err)
			}
		}
		cursor = blockEnd + 4
	}
	return nil
}

func validateHTTPPayload(payload []byte) error {
	headerEnd := bytes.Index(payload, []byte("\r\n\r\n"))
	if headerEnd < 0 {
		return errors.New("HTTP response is missing its header terminator")
	}
	lines := bytes.Split(payload[:headerEnd], []byte("\r\n"))
	if len(lines) == 0 || !bytes.HasPrefix(lines[0], []byte("HTTP/")) {
		return errors.New("HTTP response is missing its status line")
	}
	contentLength := -1
	for _, line := range lines[1:] {
		colon := bytes.IndexByte(line, ':')
		if colon <= 0 {
			return errors.New("HTTP response has an invalid header")
		}
		name := textproto.CanonicalMIMEHeaderKey(strings.TrimSpace(string(line[:colon])))
		if name != "Content-Length" {
			continue
		}
		if contentLength >= 0 {
			return errors.New("HTTP response repeats Content-Length")
		}
		n, err := strconv.Atoi(strings.TrimSpace(string(line[colon+1:])))
		if err != nil || n < 0 {
			return errors.New("HTTP response has invalid Content-Length")
		}
		contentLength = n
	}
	if contentLength < 0 {
		return errors.New("HTTP response is missing Content-Length")
	}
	bodyLength := len(payload) - (headerEnd + 4)
	if contentLength != bodyLength {
		return fmt.Errorf("HTTP Content-Length is %d, body is %d bytes", contentLength, bodyLength)
	}
	return nil
}

// RemoveResponseRecords returns archive without the response records whose
// WARC-Target-URI is in targetURIs. Other records are copied unchanged.
func RemoveResponseRecords(archive []byte, targetURIs map[string]struct{}) ([]byte, error) {
	if len(targetURIs) == 0 {
		return archive, nil
	}
	out := make([]byte, 0, len(archive))
	cursor := 0
	recordNumber := 0
	for cursor < len(archive) {
		recordNumber++
		headerEnd := bytes.Index(archive[cursor:], []byte("\r\n\r\n"))
		if headerEnd < 0 {
			return nil, fmt.Errorf("WARC record %d is missing its header terminator", recordNumber)
		}
		headerEnd += cursor
		contentLength := -1
		warcType := ""
		targetURI := ""
		for _, line := range bytes.Split(archive[cursor:headerEnd], []byte("\r\n"))[1:] {
			colon := bytes.IndexByte(line, ':')
			if colon <= 0 || line[0] == ' ' || line[0] == '\t' {
				continue
			}
			name := strings.TrimSpace(string(line[:colon]))
			value := strings.TrimSpace(string(line[colon+1:]))
			switch {
			case strings.EqualFold(name, "Content-Length"):
				n, err := strconv.Atoi(value)
				if err != nil || n < 0 {
					return nil, fmt.Errorf("WARC record %d has invalid Content-Length %q", recordNumber, value)
				}
				contentLength = n
			case strings.EqualFold(name, "WARC-Type"):
				warcType = value
			case strings.EqualFold(name, "WARC-Target-URI"):
				targetURI = value
			}
		}
		if contentLength < 0 {
			return nil, fmt.Errorf("WARC record %d is missing content-length", recordNumber)
		}
		blockEnd := headerEnd + 4 + contentLength
		if blockEnd > len(archive) {
			return nil, fmt.Errorf("WARC record %d block exceeds the archive", recordNumber)
		}
		next := min(blockEnd+4, len(archive))
		if _, remove := targetURIs[targetURI]; !remove || !strings.EqualFold(warcType, "response") {
			out = append(out, archive[cursor:next]...)
		}
		cursor = next
	}
	return out, nil
}
