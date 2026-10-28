package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"runtime"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	qinternal "github.com/royalicing/qip/internal"
)

const maxReportedKindredMismatches = 20

type kindredMismatch struct {
	requestPath string
	detail      string
}

// memoKindredResolver caches a resolver's results. Each page's Kindred Routes
// overlap heavily (every page has "/" as a parent), so without this the check
// would rerun the same content recipes once per page.
func memoKindredResolver(resolve qinternal.KindredRouteResolver) qinternal.KindredRouteResolver {
	type entry struct {
		once     sync.Once
		response qinternal.InProcessHTTPResponse
		ok       bool
		err      error
	}
	var mu sync.Mutex
	entries := make(map[string]*entry)
	return func(requestPath string) (qinternal.InProcessHTTPResponse, bool, error) {
		mu.Lock()
		e, found := entries[requestPath]
		if !found {
			e = &entry{}
			entries[requestPath] = e
		}
		mu.Unlock()
		e.once.Do(func() {
			e.response, e.ok, e.err = resolve(requestPath)
		})
		return e.response, e.ok, e.err
	}
}

// checkKindredWARC reruns the application/warc recipes for each page with only
// that page's Kindred Routes, as qip router dev does, and reports pages whose
// response differs from the one in the whole-site archive. A difference means
// a recipe read a record that dev mode would not have given it. A page whose
// recipes exceed timeout stops the whole check: pages already running are
// canceled and no further pages are started.
func checkKindredWARC(
	ctx context.Context,
	pipeline *qinternal.Pipeline,
	origin string,
	requestPaths []string,
	fullArchive []byte,
	resolveBase qinternal.KindredRouteResolver,
	resolveStatic qinternal.KindredRouteResolver,
	elementEntryPaths []string,
	resolveElement qinternal.KindredRouteResolver,
	timeout time.Duration,
) error {
	fullRecords, err := parseWARCResponseRecords(fullArchive)
	if err != nil {
		return fmt.Errorf("failed to parse whole-site WARC: %w", err)
	}
	fullByURI := make(map[string]qinternal.InProcessHTTPResponse, len(fullRecords))
	for _, record := range fullRecords {
		if _, ok := fullByURI[record.targetURI]; !ok {
			fullByURI[record.targetURI] = record.response
		}
	}

	ctx, stop := context.WithCancel(ctx)
	defer stop()

	resolveStatic = memoKindredResolver(resolveStatic)
	resolveElement = memoKindredResolver(resolveElement)

	errTimedOut := errors.New("timed out")
	checkPage := func(requestPath string) (string, error) {
		response, ok, err := resolveBase(requestPath)
		if err != nil {
			return "", err
		}
		if !ok {
			return "", nil
		}
		archive, err := buildKindredWARCArchive(origin, requestPath, response, resolveBase, resolveStatic, elementEntryPaths, resolveElement)
		if err != nil {
			return "", err
		}
		execCtx, cancel := withExecutionTimeout(ctx, timeout)
		defer cancel()
		transformed, err := processApplicationWARCArchive(execCtx, pipeline, archive, 0)
		if err != nil {
			if ctx.Err() == nil && execCtx.Err() == context.DeadlineExceeded {
				return "", errTimedOut
			}
			return fmt.Sprintf("WARC recipes failed with only Kindred Routes: %v", err), nil
		}
		requestURI := origin + requestPath
		got, err := extractWARCResponseRecordByTargetURI(transformed, requestURI)
		if err != nil {
			return fmt.Sprintf("WARC recipes with only Kindred Routes returned no record: %v", err), nil
		}
		want, ok := fullByURI[requestURI]
		if !ok {
			return "whole-site WARC has no record for this page", nil
		}
		return describeKindredResponseDifference(want, got), nil
	}

	workers := min(runtime.GOMAXPROCS(0), len(requestPaths))
	jobs := make(chan string)
	var mu sync.Mutex
	var mismatches []kindredMismatch
	var firstErr, timeoutErr error
	var wg sync.WaitGroup
	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for requestPath := range jobs {
				if ctx.Err() != nil {
					continue
				}
				detail, err := checkPage(requestPath)
				mu.Lock()
				if errors.Is(err, errTimedOut) {
					if timeoutErr == nil {
						timeoutErr = fmt.Errorf("Kindred Routes check stopped: %s: WARC recipes did not finish within %dms", requestPath, timeout.Milliseconds())
						stop()
					}
				} else if ctx.Err() == nil {
					if err != nil && firstErr == nil {
						firstErr = fmt.Errorf("failed to check Kindred Routes for %q: %w", requestPath, err)
					}
					if detail != "" {
						mismatches = append(mismatches, kindredMismatch{requestPath: requestPath, detail: detail})
					}
				}
				mu.Unlock()
			}
		}()
	}
dispatch:
	for _, requestPath := range requestPaths {
		select {
		case jobs <- requestPath:
		case <-ctx.Done():
			break dispatch
		}
	}
	close(jobs)
	wg.Wait()

	if timeoutErr != nil {
		return timeoutErr
	}
	if firstErr != nil {
		return firstErr
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if len(mismatches) == 0 {
		return nil
	}
	sort.Slice(mismatches, func(i, j int) bool { return mismatches[i].requestPath < mismatches[j].requestPath })
	var message strings.Builder
	fmt.Fprintf(&message, "%d of %d pages differ when WARC recipes see only their Kindred Routes:", len(mismatches), len(requestPaths))
	for i, mismatch := range mismatches {
		if i == maxReportedKindredMismatches {
			fmt.Fprintf(&message, "\n  … and %d more", len(mismatches)-i)
			break
		}
		fmt.Fprintf(&message, "\n  %s: %s", mismatch.requestPath, mismatch.detail)
	}
	return fmt.Errorf("%s", message.String())
}

// describeKindredResponseDifference returns "" when both responses are the
// same, otherwise a one-line description of the first difference.
func describeKindredResponseDifference(want qinternal.InProcessHTTPResponse, got qinternal.InProcessHTTPResponse) string {
	if want.StatusCode != got.StatusCode {
		return fmt.Sprintf("status %d in whole-site WARC, %d with only Kindred Routes", want.StatusCode, got.StatusCode)
	}
	if !bytes.Equal(want.Body, got.Body) {
		offset := 0
		for offset < len(want.Body) && offset < len(got.Body) && want.Body[offset] == got.Body[offset] {
			offset++
		}
		return fmt.Sprintf("body differs from byte %d: whole-site WARC has %s, only Kindred Routes has %s (%d vs %d bytes)",
			offset, kindredBodySnippet(want.Body, offset), kindredBodySnippet(got.Body, offset), len(want.Body), len(got.Body))
	}
	keys := make([]string, 0, len(want.Header)+len(got.Header))
	for key := range want.Header {
		keys = append(keys, key)
	}
	for key := range got.Header {
		keys = append(keys, key)
	}
	slices.Sort(keys)
	for _, key := range slices.Compact(keys) {
		// Content-Length follows the body, which has already been compared.
		if key == "Content-Length" {
			continue
		}
		if !slices.Equal(want.Header.Values(key), got.Header.Values(key)) {
			return fmt.Sprintf("header %s is %q in whole-site WARC, %q with only Kindred Routes", key, want.Header.Values(key), got.Header.Values(key))
		}
	}
	return ""
}

func kindredBodySnippet(body []byte, offset int) string {
	if offset >= len(body) {
		return "end of body"
	}
	end := min(offset+48, len(body))
	return fmt.Sprintf("%q", body[offset:end])
}

// kindredCheckPagePaths lists the routes that qip router dev passes through
// the application/warc recipes. Component and element assets are served
// before that step, so they are not checked.
func kindredCheckPagePaths(state *RouterServerState, routeOptions qinternal.RouteOptions) []string {
	pathSet := make(map[string]struct{}, len(state.contentRoutes))
	for requestPath := range state.contentRoutes {
		canonical, _ := qinternal.CanonicalRequestPath(requestPath, routeOptions)
		if _, ok := state.componentAssets[canonical]; ok {
			continue
		}
		if _, ok := state.elementAssets[canonical]; ok {
			continue
		}
		pathSet[canonical] = struct{}{}
	}
	paths := make([]string, 0, len(pathSet))
	for requestPath := range pathSet {
		paths = append(paths, requestPath)
	}
	sort.Strings(paths)
	return paths
}
