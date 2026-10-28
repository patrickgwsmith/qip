package main

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	qinternal "github.com/royalicing/qip/internal"
)

// stampRecordCountStage appends the archive's response record count to every
// HTML body, so its output depends on records outside a page's Kindred Routes
// whenever stamp is true.
type stampRecordCountStage struct {
	stamp bool
}

func (s stampRecordCountStage) Process(_ context.Context, input qinternal.Content, _ uint64) (qinternal.Content, error) {
	_, raw, err := ensureRawContent(input)
	if err != nil {
		return nil, err
	}
	records, err := parseWARCResponseRecords(raw)
	if err != nil {
		return nil, err
	}
	var out bytes.Buffer
	for _, record := range records {
		response := record.response
		if s.stamp && strings.HasPrefix(response.Header.Get("Content-Type"), "text/html") {
			response.Body = fmt.Appendf(bytes.Clone(response.Body), "<!-- %d records -->", len(records))
		}
		response.Header.Del("Content-Length")
		built, err := buildMinimalWARCResponseRecord(record.targetURI, response)
		if err != nil {
			return nil, err
		}
		out.Write(built)
	}
	return qinternal.NewRawBytesContentWithType(out.Bytes(), applicationWARCRecipeMIME), nil
}

func (stampRecordCountStage) Close(context.Context) error { return nil }

// blockOnSharedArchiveStage passes through archives with one record and
// blocks until canceled on any larger archive, like a recipe stuck in a loop.
type blockOnSharedArchiveStage struct{}

func (blockOnSharedArchiveStage) Process(ctx context.Context, input qinternal.Content, _ uint64) (qinternal.Content, error) {
	_, raw, err := ensureRawContent(input)
	if err != nil {
		return nil, err
	}
	records, err := parseWARCResponseRecords(raw)
	if err != nil {
		return nil, err
	}
	if len(records) > 1 {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	return input, nil
}

func (blockOnSharedArchiveStage) Close(context.Context) error { return nil }

func runKindredCheckFixture(t *testing.T, stamp bool) error {
	return runKindredCheckFixtureWith(t, stamp, nil, time.Minute)
}

func runKindredCheckFixtureWith(t *testing.T, stamp bool, stage qinternal.Stage, timeout time.Duration) error {
	t.Helper()
	pages := map[string]string{
		"/":      "<h1>Home</h1>",
		"/a":     "<h1>A</h1>",
		"/b":     "<h1>B</h1>",
		"/b/one": "<h1>B one</h1>",
	}
	resolveBase := func(requestPath string) (qinternal.InProcessHTTPResponse, bool, error) {
		body, ok := pages[requestPath]
		if !ok {
			return qinternal.InProcessHTTPResponse{}, false, nil
		}
		return qinternal.InProcessHTTPResponse{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{"text/html; charset=utf-8"}},
			Body:       []byte(body),
		}, true, nil
	}
	resolveNone := func(string) (qinternal.InProcessHTTPResponse, bool, error) {
		return qinternal.InProcessHTTPResponse{}, false, nil
	}
	requestPaths := []string{"/", "/a", "/b", "/b/one"}
	const origin = "https://example.com"

	var full bytes.Buffer
	for _, requestPath := range requestPaths {
		response, _, _ := resolveBase(requestPath)
		record, err := buildMinimalWARCResponseRecord(origin+requestPath, response)
		if err != nil {
			t.Fatal(err)
		}
		full.Write(record)
	}
	pipeline := &qinternal.Pipeline{Stages: []qinternal.Stage{stampRecordCountStage{stamp: stamp}}}
	transformed, err := processApplicationWARCArchive(context.Background(), pipeline, full.Bytes(), 0)
	if err != nil {
		t.Fatal(err)
	}
	if stage != nil {
		pipeline = &qinternal.Pipeline{Stages: []qinternal.Stage{stage}}
	}
	return checkKindredWARC(context.Background(), pipeline, origin, requestPaths, transformed, resolveBase, resolveNone, nil, resolveNone, timeout)
}

func TestCheckKindredWARCPassesWhenPagesOnlyUseKindredRoutes(t *testing.T) {
	if err := runKindredCheckFixture(t, false); err != nil {
		t.Fatalf("checkKindredWARC: %v", err)
	}
}

func TestCheckKindredWARCReportsPagesThatReadOtherRoutes(t *testing.T) {
	err := runKindredCheckFixture(t, true)
	if err == nil {
		t.Fatal("checkKindredWARC succeeded, want a mismatch for every page")
	}
	message := err.Error()
	// The whole-site archive has 4 records. "/" sees only itself, "/a" and
	// "/b" also see "/", and "/b/one" sees "/", "/b" and itself.
	for _, want := range []string{
		"4 of 4 pages differ",
		`  /: body differs from byte 18: whole-site WARC has "4 records -->", only Kindred Routes has "1 records -->" (31 vs 31 bytes)`,
		`  /a: body differs from byte 15: whole-site WARC has "4 records -->", only Kindred Routes has "2 records -->" (28 vs 28 bytes)`,
		`  /b/one: body differs from byte 19: whole-site WARC has "4 records -->", only Kindred Routes has "3 records -->" (32 vs 32 bytes)`,
	} {
		if !strings.Contains(message, want) {
			t.Errorf("error is missing %q:\n%s", want, message)
		}
	}
}

func TestCheckKindredWARCStopsOnTimeout(t *testing.T) {
	// "/" sees only itself and passes. "/a", "/b" and "/b/one" each see more
	// than one record and block until their timeout.
	err := runKindredCheckFixtureWith(t, false, blockOnSharedArchiveStage{}, 50*time.Millisecond)
	if err == nil {
		t.Fatal("checkKindredWARC succeeded, want a timeout")
	}
	message := err.Error()
	if !strings.HasPrefix(message, "Kindred Routes check stopped: /") || !strings.HasSuffix(message, ": WARC recipes did not finish within 50ms") {
		t.Fatalf("error = %q, want a Kindred Routes timeout", message)
	}
	if strings.Contains(message, "differ") {
		t.Fatalf("error = %q, want only the timeout, not a list of differing pages", message)
	}
}

func TestDescribeKindredResponseDifferenceIgnoresContentLengthAlone(t *testing.T) {
	want := qinternal.InProcessHTTPResponse{StatusCode: 200, Header: http.Header{"Content-Length": []string{"2"}}, Body: []byte("hi")}
	got := qinternal.InProcessHTTPResponse{StatusCode: 200, Header: http.Header{}, Body: []byte("hi")}
	if detail := describeKindredResponseDifference(want, got); detail != "" {
		t.Fatalf("difference = %q, want none", detail)
	}
	got.Header.Set("Content-Type", "text/plain")
	if detail := describeKindredResponseDifference(want, got); !strings.Contains(detail, "header Content-Type") {
		t.Fatalf("difference = %q, want a Content-Type header difference", detail)
	}
}
