package main

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	qinternal "github.com/royalicing/qip/internal"
)

func TestDevDerivedRoutesAreDiscoveredThenBuiltOnce(t *testing.T) {
	var calls atomic.Int32
	buildStarted := make(chan struct{})
	releaseBuild := make(chan struct{})
	var startOnce sync.Once

	pipeline := &qinternal.Pipeline{
		Stages: []qinternal.Stage{&qinternal.RunStage{Driver: &qinternal.WasmRunDriver{
			RunFunc: func(ctx context.Context, input []byte, _ uint64) (qinternal.Content, error) {
				call := calls.Add(1)
				records, err := parseWARCResponseRecords(input)
				if err != nil {
					return nil, err
				}
				if call > 1 {
					startOnce.Do(func() { close(buildStarted) })
					select {
					case <-ctx.Done():
						return nil, ctx.Err()
					case <-releaseBuild:
					}
				}
				body := []byte(fmt.Sprintf("full-site-records=%d\n", len(records)))
				record, err := buildMinimalWARCResponseRecord(
					"http://qip.local/generated/index.csv",
					qinternal.InProcessHTTPResponse{
						StatusCode: http.StatusOK,
						Header:     http.Header{"Content-Type": []string{"text/csv; charset=utf-8"}},
						Body:       body,
					},
				)
				if err != nil {
					return nil, err
				}
				output := append(append([]byte(nil), input...), record...)
				return qinternal.NewRawBytesContentWithType(output, applicationWARCRecipeMIME), nil
			},
			CloseFunc: func(context.Context) error { return nil },
		}}},
	}
	state := &RouterServerState{
		RouterFileState: &RouterFileState{
			contentRoutes: map[string]qinternal.ContentRoute{
				"/":      {FilePath: "home", SourceMIME: "text/html"},
				"/about": {FilePath: "about", SourceMIME: "text/html"},
			},
			contentRead: func(_ context.Context, route qinternal.ContentRoute) ([]byte, error) {
				return []byte("<h1>" + route.FilePath + "</h1>"), nil
			},
			routeOptions:  qinternal.DefaultRouteOptions(),
			recipeDigests: map[string][][32]byte{},
		},
		recipeChains: map[string]*qinternal.Pipeline{
			applicationWARCRecipeMIME: pipeline,
		},
	}
	derived, err := discoverDevDerivedRoutes(context.Background(), state, RouterServerTimeouts{})
	if err != nil {
		t.Fatalf("discoverDevDerivedRoutes: %v", err)
	}
	if derived == nil {
		t.Fatal("expected a derived route set")
	}
	if _, ok := derived.known["/generated/index.csv"]; !ok {
		t.Fatalf("known routes=%v, want /generated/index.csv", derived.known)
	}
	var logMu sync.Mutex
	var logLines []string
	derived.logf = func(format string, args ...any) {
		logMu.Lock()
		logLines = append(logLines, fmt.Sprintf(format, args...))
		logMu.Unlock()
	}
	state.derivedRoutes = derived
	t.Cleanup(func() { state.close(context.Background()) })

	handler := newRouterRequestHandler(
		"test",
		newRouterServerStateSlot(state),
		nil,
		nil,
		qinternal.DefaultRouteOptions(),
		RouterServerTimeouts{},
	)
	type result struct {
		response qinternal.InProcessHTTPResponse
		err      error
	}
	results := make(chan result, 2)
	for range 2 {
		go func() {
			response, err := qinternal.ServeInProcessHTTP(handler, http.MethodGet, "/generated/index.csv", nil)
			results <- result{response: response, err: err}
		}()
	}
	<-buildStarted
	close(releaseBuild)

	for range 2 {
		got := <-results
		if got.err != nil {
			t.Fatalf("ServeInProcessHTTP: %v", got.err)
		}
		if body := string(got.response.Body); body != "full-site-records=2\n" {
			t.Fatalf("body=%q, want full-site build output", body)
		}
	}
	if got := calls.Load(); got != 2 {
		t.Fatalf("pipeline calls=%d, want one discovery and one shared full-site build", got)
	}

	response, err := qinternal.ServeInProcessHTTP(handler, http.MethodGet, "/generated/index.csv", nil)
	if err != nil {
		t.Fatalf("cached ServeInProcessHTTP: %v", err)
	}
	if body := string(response.Body); body != "full-site-records=2\n" {
		t.Fatalf("cached body=%q", body)
	}
	if got := calls.Load(); got != 2 {
		t.Fatalf("cached request rebuilt pipeline: calls=%d", got)
	}
	logMu.Lock()
	logOutput := strings.Join(logLines, "\n")
	logMu.Unlock()
	for _, want := range []string{
		"phase=render-routes routes=2",
		"recipe[1]=run",
		"phase=transform",
		"phase=parse-derived-routes routes=1",
		"full-site WARC ready derived_routes=1",
	} {
		if !strings.Contains(logOutput, want) {
			t.Fatalf("build log is missing %q:\n%s", want, logOutput)
		}
	}
}

func TestDevDerivedRoutesDoNotClaimUnknownPaths(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	routes := &devDerivedRouteSet{
		known:     map[string]struct{}{"/generated.csv": {}},
		responses: map[string]qinternal.InProcessHTTPResponse{},
		done:      make(chan struct{}),
		ctx:       ctx,
		cancel:    cancel,
		build: func(context.Context) (map[string]qinternal.InProcessHTTPResponse, error) {
			return nil, fmt.Errorf("should not run")
		},
	}

	_, known, err := routes.resolve(context.Background(), "/typo.csv")
	if err != nil {
		t.Fatalf("resolve unknown route: %v", err)
	}
	if known {
		t.Fatal("unknown route was claimed by the derived route set")
	}
	if routes.started {
		t.Fatal("unknown route started the full-site build")
	}
}

func TestDevDerivedRouteReportsSharedBuildFailure(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	routes := &devDerivedRouteSet{
		known:     map[string]struct{}{"/generated.csv": {}},
		responses: map[string]qinternal.InProcessHTTPResponse{},
		done:      make(chan struct{}),
		ctx:       ctx,
		cancel:    cancel,
		logf:      func(string, ...any) {},
		build: func(context.Context) (map[string]qinternal.InProcessHTTPResponse, error) {
			return nil, fmt.Errorf("index overflow")
		},
	}
	t.Cleanup(routes.close)

	_, known, err := routes.resolve(context.Background(), "/generated.csv")
	if !known {
		t.Fatal("discovered route was not claimed")
	}
	if err == nil || !strings.Contains(err.Error(), "full-site WARC build: index overflow") {
		t.Fatalf("error=%v", err)
	}
}

func TestLogSlowestRenderRecipesAggregatesAndRanksStages(t *testing.T) {
	steps := []qinternal.PipelineTraceStep{
		{StageLabel: "markdown.wasm", Duration: 3 * time.Millisecond},
		{StageLabel: "syntax.wasm", Duration: 8 * time.Millisecond},
		{StageLabel: "markdown.wasm", Duration: 7 * time.Millisecond},
		{StageLabel: "wrap.wasm", Duration: 2 * time.Millisecond},
	}
	var lines []string
	logSlowestRenderRecipes(func(format string, args ...any) {
		lines = append(lines, fmt.Sprintf(format, args...))
	}, steps, 2)

	if len(lines) != 2 {
		t.Fatalf("log lines=%d, want 2: %v", len(lines), lines)
	}
	if !strings.Contains(lines[0], "rank=1 recipe=markdown.wasm runs=2 duration=10ms") {
		t.Fatalf("first log=%q", lines[0])
	}
	if !strings.Contains(lines[1], "rank=2 recipe=syntax.wasm runs=1 duration=8ms") {
		t.Fatalf("second log=%q", lines[1])
	}
}

func TestDevDerivedRoutesWaitForUndiscoveredSiblingPaths(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	release := make(chan struct{})
	routes := &devDerivedRouteSet{
		known:     map[string]struct{}{"/_og/index.png": {}},
		responses: map[string]qinternal.InProcessHTTPResponse{},
		done:      make(chan struct{}),
		ctx:       ctx,
		cancel:    cancel,
		logf:      func(string, ...any) {},
		build: func(context.Context) (map[string]qinternal.InProcessHTTPResponse, error) {
			<-release
			return map[string]qinternal.InProcessHTTPResponse{
				"/_og/index.png":    {StatusCode: 200, Body: []byte("index")},
				"/_og/docs/qip.png": {StatusCode: 200, Body: []byte("nested")},
			}, nil
		},
	}
	t.Cleanup(routes.close)

	go func() {
		time.Sleep(10 * time.Millisecond)
		close(release)
	}()
	response, handled, err := routes.resolveMissing(context.Background(), "/_og/docs/qip.png")
	if err != nil || !handled {
		t.Fatalf("handled=%v err=%v", handled, err)
	}
	if string(response.Body) != "nested" {
		t.Fatalf("body=%q", response.Body)
	}

	response, handled, err = routes.resolveMissing(context.Background(), "/_og/missing.png")
	if err != nil || !handled {
		t.Fatalf("handled=%v err=%v", handled, err)
	}
	if response.StatusCode != 404 || !strings.Contains(string(response.Body), "finished in") {
		t.Fatalf("status=%d body=%q", response.StatusCode, response.Body)
	}
}

func TestDevDerivedRoutesMissingPathsReportBuildFailure(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	routes := &devDerivedRouteSet{
		known:     map[string]struct{}{"/_og/index.png": {}},
		responses: map[string]qinternal.InProcessHTTPResponse{},
		done:      make(chan struct{}),
		ctx:       ctx,
		cancel:    cancel,
		logf:      func(string, ...any) {},
		build: func(context.Context) (map[string]qinternal.InProcessHTTPResponse, error) {
			return nil, fmt.Errorf("index overflow")
		},
	}
	t.Cleanup(routes.close)

	response, handled, err := routes.resolveMissing(context.Background(), "/_og/docs.png")
	if err != nil || !handled {
		t.Fatalf("handled=%v err=%v", handled, err)
	}
	if response.StatusCode != 404 || !strings.Contains(string(response.Body), "full-site WARC build failed after") || !strings.Contains(string(response.Body), "index overflow") {
		t.Fatalf("status=%d body=%q", response.StatusCode, response.Body)
	}
}

func TestDevDerivedRoutesDoNotWaitForUnrelatedMissingPaths(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	routes := &devDerivedRouteSet{
		known:     map[string]struct{}{"/_og/index.png": {}, "/feed.xml": {}},
		responses: map[string]qinternal.InProcessHTTPResponse{},
		done:      make(chan struct{}),
		ctx:       ctx,
		cancel:    cancel,
		build: func(context.Context) (map[string]qinternal.InProcessHTTPResponse, error) {
			return nil, fmt.Errorf("should not run")
		},
	}

	for _, requestPath := range []string{"/typo", "/_ogx/a.png", "/docs/missing"} {
		_, handled, err := routes.resolveMissing(context.Background(), requestPath)
		if err != nil || handled {
			t.Fatalf("%s: handled=%v err=%v", requestPath, handled, err)
		}
	}
	if routes.started {
		t.Fatal("unrelated missing path started the full-site build")
	}
}
