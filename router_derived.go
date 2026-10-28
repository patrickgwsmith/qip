package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"sort"
	"sync"
	"time"

	qinternal "github.com/royalicing/qip/internal"
)

type devDerivedRouteSet struct {
	mu        sync.Mutex
	known     map[string]struct{}
	responses map[string]qinternal.InProcessHTTPResponse
	started   bool
	done      chan struct{}
	err       error
	build     func(context.Context) (map[string]qinternal.InProcessHTTPResponse, error)
	ctx       context.Context
	cancel    context.CancelFunc
	wg        sync.WaitGroup
	logf      func(string, ...any)
}

func discoverDevDerivedRoutes(ctx context.Context, state *RouterServerState, timeouts RouterServerTimeouts) (*devDerivedRouteSet, error) {
	pipeline := state.recipeChains[applicationWARCRecipeMIME]
	if pipeline == nil {
		return nil, nil
	}

	home, ok, err := resolveRouterBaseResponse(ctx, state, "/", 0, timeouts)
	if err != nil {
		return nil, fmt.Errorf("resolve route-discovery homepage: %w", err)
	}
	if !ok {
		return nil, nil
	}
	probe, err := buildMinimalWARCResponseRecord(buildWARCRequestURI("qip.local", "/"), home)
	if err != nil {
		return nil, fmt.Errorf("build route-discovery WARC: %w", err)
	}
	execCtx, cancel := withExecutionTimeout(ctx, timeouts.applicationWARC)
	defer cancel()
	transformed, err := processApplicationWARCArchive(execCtx, pipeline, probe, 0)
	if err != nil {
		return nil, fmt.Errorf("run route-discovery WARC: %w", err)
	}
	responses, err := extractWARCResponsesByPath(transformed, "qip.local")
	if err != nil {
		return nil, fmt.Errorf("read route-discovery WARC: %w", err)
	}
	delete(responses, "/")
	if len(responses) == 0 {
		return nil, nil
	}

	known := make(map[string]struct{}, len(responses))
	basePaths := make(map[string]struct{})
	for _, requestPath := range listRouterArchivePaths(state) {
		basePaths[requestPath] = struct{}{}
	}
	for requestPath := range responses {
		if _, exists := basePaths[requestPath]; exists {
			continue
		}
		known[requestPath] = struct{}{}
	}
	if len(known) == 0 {
		return nil, nil
	}

	buildCtx, buildCancel := context.WithCancel(context.Background())
	derived := &devDerivedRouteSet{
		known:     known,
		responses: make(map[string]qinternal.InProcessHTTPResponse),
		done:      make(chan struct{}),
		ctx:       buildCtx,
		cancel:    buildCancel,
		logf:      log.Printf,
	}
	derived.build = func(ctx context.Context) (map[string]qinternal.InProcessHTTPResponse, error) {
		return buildDevDerivedRoutes(ctx, state, timeouts, derived.logf)
	}
	return derived, nil
}

func (routes *devDerivedRouteSet) start() {
	if routes == nil {
		return
	}
	routes.mu.Lock()
	if routes.started {
		routes.mu.Unlock()
		return
	}
	routes.started = true
	routes.wg.Add(1)
	routes.mu.Unlock()

	go func() {
		defer routes.wg.Done()
		start := time.Now()
		responses, err := routes.build(routes.ctx)
		duration := time.Since(start)

		routes.mu.Lock()
		if err == nil {
			routes.responses = responses
		}
		routes.err = err
		close(routes.done)
		logf := routes.logf
		routes.mu.Unlock()

		if logf == nil {
			return
		}
		if err != nil {
			logf("dev: full-site WARC failed duration_ms=%d error=%v", duration.Milliseconds(), err)
			return
		}
		logf("dev: full-site WARC ready derived_routes=%d duration_ms=%d", len(responses), duration.Milliseconds())
	}()
}

func (routes *devDerivedRouteSet) resolve(ctx context.Context, requestPath string) (qinternal.InProcessHTTPResponse, bool, error) {
	if routes == nil {
		return qinternal.InProcessHTTPResponse{}, false, nil
	}
	routes.mu.Lock()
	if response, ok := routes.responses[requestPath]; ok {
		routes.mu.Unlock()
		return response, true, nil
	}
	_, known := routes.known[requestPath]
	done := routes.done
	started := routes.started
	routes.mu.Unlock()
	if !known {
		return qinternal.InProcessHTTPResponse{}, false, nil
	}
	if !started {
		routes.start()
	}

	select {
	case <-ctx.Done():
		return qinternal.InProcessHTTPResponse{}, true, ctx.Err()
	case <-done:
	}

	routes.mu.Lock()
	defer routes.mu.Unlock()
	if routes.err != nil {
		return qinternal.InProcessHTTPResponse{}, true, fmt.Errorf("full-site WARC build: %w", routes.err)
	}
	response, ok := routes.responses[requestPath]
	if !ok {
		return qinternal.InProcessHTTPResponse{}, true, fmt.Errorf("full-site WARC did not produce discovered route %q", requestPath)
	}
	return response, true, nil
}

func (routes *devDerivedRouteSet) close() {
	if routes == nil {
		return
	}
	routes.cancel()
	routes.wg.Wait()
}

func buildDevDerivedRoutes(
	ctx context.Context,
	state *RouterServerState,
	timeouts RouterServerTimeouts,
	logf func(string, ...any),
) (map[string]qinternal.InProcessHTTPResponse, error) {
	paths := listRouterArchivePaths(state)
	if len(paths) == 0 {
		return nil, errors.New("no route paths found to archive")
	}

	renderStart := time.Now()
	renderTrace := &routeTraceRecorder{}
	renderCtx := qinternal.WithPipelineTrace(ctx, renderTrace.Record)
	contextPaths := make(map[string]struct{})
	for _, requestPath := range filteredParentPaths(state, paths) {
		contextPaths[requestPath] = struct{}{}
		paths = append(paths, requestPath)
	}
	sort.Strings(paths)
	var archive bytes.Buffer
	inputPaths := make(map[string]struct{}, len(paths))
	for _, requestPath := range paths {
		response, ok, err := resolveRouterArchiveBaseResponse(renderCtx, state, requestPath, timeouts)
		if err != nil {
			return nil, fmt.Errorf("resolve full-site route %q: %w", requestPath, err)
		}
		if !ok {
			return nil, fmt.Errorf("full-site route %q disappeared during build", requestPath)
		}
		if _, ok := contextPaths[requestPath]; ok && !qinternal.IsKindredParentResponse(response) {
			continue
		}
		record, err := buildMinimalWARCResponseRecord(buildWARCRequestURI("qip.local", requestPath), response)
		if err != nil {
			return nil, fmt.Errorf("build full-site WARC record for %q: %w", requestPath, err)
		}
		archive.Write(record)
		inputPaths[requestPath] = struct{}{}
	}
	if logf != nil {
		logf(
			"dev: full-site WARC phase=render-routes routes=%d bytes=%d duration_ms=%d",
			len(paths),
			archive.Len(),
			time.Since(renderStart).Milliseconds(),
		)
		logSlowestRenderRecipes(logf, renderTrace.steps, 5)
	}

	pipeline := state.recipeChains[applicationWARCRecipeMIME]
	execCtx, cancel := withExecutionTimeout(ctx, scaleRouteWARCTransformTimeout(timeouts.applicationWARC, len(paths)))
	defer cancel()
	traceRecorder := &routeTraceRecorder{}
	execCtx = qinternal.WithPipelineTrace(execCtx, traceRecorder.Record)
	transformStart := time.Now()
	transformed, err := processApplicationWARCArchive(execCtx, pipeline, archive.Bytes(), 0)
	if err != nil {
		return nil, err
	}
	if logf != nil {
		for _, step := range traceRecorder.steps {
			logf(
				"dev: full-site WARC recipe[%d]=%s input=%s output=%s duration=%s",
				step.StageIndex+1,
				step.StageLabel,
				formatTraceContent(step.InputEncoding, step.InputContentType, step.InputBytes),
				formatTraceContent(step.OutputEncoding, step.OutputContentType, step.OutputBytes),
				formatTraceDuration(step.Duration),
			)
		}
		logf(
			"dev: full-site WARC phase=transform bytes=%d duration_ms=%d",
			len(transformed),
			time.Since(transformStart).Milliseconds(),
		)
	}
	parseStart := time.Now()
	responses, err := extractWARCResponsesByPath(transformed, "qip.local")
	if err != nil {
		return nil, err
	}
	for requestPath := range inputPaths {
		delete(responses, requestPath)
	}
	if logf != nil {
		logf(
			"dev: full-site WARC phase=parse-derived-routes routes=%d duration_ms=%d",
			len(responses),
			time.Since(parseStart).Milliseconds(),
		)
	}
	return responses, nil
}

func logSlowestRenderRecipes(logf func(string, ...any), steps []qinternal.PipelineTraceStep, limit int) {
	if logf == nil || len(steps) == 0 || limit <= 0 {
		return
	}
	type aggregate struct {
		label    string
		runs     int
		duration time.Duration
	}
	byLabel := make(map[string]*aggregate)
	for _, step := range steps {
		item := byLabel[step.StageLabel]
		if item == nil {
			item = &aggregate{label: step.StageLabel}
			byLabel[step.StageLabel] = item
		}
		item.runs++
		item.duration += step.Duration
	}
	ordered := make([]aggregate, 0, len(byLabel))
	for _, item := range byLabel {
		ordered = append(ordered, *item)
	}
	sort.Slice(ordered, func(i, j int) bool {
		if ordered[i].duration != ordered[j].duration {
			return ordered[i].duration > ordered[j].duration
		}
		return ordered[i].label < ordered[j].label
	})
	if len(ordered) < limit {
		limit = len(ordered)
	}
	for rank, item := range ordered[:limit] {
		logf(
			"dev: full-site WARC render-recipe-rank=%d recipe=%s runs=%d duration=%s",
			rank+1,
			item.label,
			item.runs,
			formatTraceDuration(item.duration),
		)
	}
}

func listRouterArchivePaths(state *RouterServerState) []string {
	pathSet := make(map[string]struct{}, len(state.contentRoutes)+len(state.componentRequestPaths)+len(state.elementRequestPaths))
	for requestPath := range state.contentRoutes {
		canonical, _ := qinternal.CanonicalRequestPath(requestPath, state.routeOptions)
		pathSet[canonical] = struct{}{}
	}
	for _, requestPath := range state.componentRequestPaths {
		pathSet[requestPath] = struct{}{}
	}
	for _, requestPath := range state.elementRequestPaths {
		pathSet[requestPath] = struct{}{}
	}
	if len(state.recipeSourceIndex) > 0 {
		pathSet["/view-source"] = struct{}{}
		for requestPath := range state.recipeSourceByPath {
			pathSet[requestPath] = struct{}{}
		}
	}
	paths := make([]string, 0, len(pathSet))
	for requestPath := range pathSet {
		paths = append(paths, requestPath)
	}
	sort.Strings(paths)
	return paths
}

func resolveRouterArchiveBaseResponse(ctx context.Context, state *RouterServerState, requestPath string, timeouts RouterServerTimeouts) (qinternal.InProcessHTTPResponse, bool, error) {
	if response, ok := resolveRecipeSourceResponse(requestPath, state); ok {
		return qinternal.InProcessHTTPResponse{StatusCode: response.StatusCode, Header: response.Header, Body: response.Body}, true, nil
	}
	if asset, ok := state.componentAssets[requestPath]; ok {
		return qinternal.InProcessHTTPResponse{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{asset.contentType}},
			Body:       asset.body,
		}, true, nil
	}
	if _, ok := state.elementAssets[requestPath]; ok {
		return resolveElementAssetResponse(ctx, state, requestPath, 0, timeouts)
	}
	return resolveRouterBaseResponse(ctx, state, requestPath, 0, timeouts)
}

func extractWARCResponsesByPath(warc []byte, expectedHost string) (map[string]qinternal.InProcessHTTPResponse, error) {
	records, err := parseWARCResponseRecords(warc)
	if err != nil {
		return nil, err
	}
	responses := make(map[string]qinternal.InProcessHTTPResponse, len(records))
	for _, record := range records {
		parsed, err := url.Parse(record.targetURI)
		if err != nil || !parsed.IsAbs() {
			return nil, fmt.Errorf("invalid WARC target URI %q", record.targetURI)
		}
		if expectedHost != "" && parsed.Host != expectedHost {
			return nil, fmt.Errorf("WARC target URI %q does not use host %q", record.targetURI, expectedHost)
		}
		if parsed.RawQuery != "" || parsed.Fragment != "" {
			continue
		}
		requestPath := parsed.Path
		if requestPath == "" {
			requestPath = "/"
		}
		responses[requestPath] = record.response
	}
	return responses, nil
}
