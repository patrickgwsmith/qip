package main

import (
	"strings"
	"testing"
)

func TestDescribeInputOffsetNamesWARCRecordAndQuotesLine(t *testing.T) {
	input := "WARC/1.1\r\nWARC-Type: response\r\nWARC-Target-URI: https://qip.dev/\r\nContent-Length: 2\r\n\r\nok\r\n\r\n" +
		"WARC/1.1\r\nWARC-Type: response\r\nWARC-Target-URI: https://qip.dev/docs\r\nContent-Length: 99\r\n\r\n" +
		"HTTP/1.1 200 OK\r\n\r\n<p>Read <a href=\"/missing\">this</a>.</p>\n<p>Next</p>"
	offset := strings.Index(input, "/missing")

	got := describeInputOffset([]byte(input), offset, "application/warc")
	want := " in WARC record https://qip.dev/docs near `<p>Read <a href=\"/missing\">this</a>.</p>`"
	if got != want {
		t.Fatalf("describeInputOffset() = %q, want %q", got, want)
	}
}

func TestDescribeInputOffsetTruncatesLongLines(t *testing.T) {
	input := strings.Repeat("a", 40) + "X" + strings.Repeat("b", 60)
	got := describeInputOffset([]byte(input), 40, "")
	want := " near `…" + strings.Repeat("a", inputSnippetBefore) + "X" + strings.Repeat("b", inputSnippetAfter-1) + "…`"
	if got != want {
		t.Fatalf("describeInputOffset() = %q, want %q", got, want)
	}
}

func TestDescribeInputOffsetOmitsBinarySnippet(t *testing.T) {
	if got := describeInputOffset([]byte{0x00, 0xff, 0x01, 0x02}, 1, ""); got != "" {
		t.Fatalf("describeInputOffset() = %q, want empty", got)
	}
}

func TestDescribeInputOffsetIgnoresWARCHeadersForOtherTypes(t *testing.T) {
	input := "WARC/1.1\nWARC-Target-URI: https://qip.dev/\n\nbad"
	got := describeInputOffset([]byte(input), len(input)-3, "text/plain")
	if want := " near `bad`"; got != want {
		t.Fatalf("describeInputOffset() = %q, want %q", got, want)
	}
}
