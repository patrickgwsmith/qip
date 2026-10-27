package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"mime"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	qcmd "github.com/royalicing/qip/cmd"
	qinternal "github.com/royalicing/qip/internal"
)

type routeListEntry struct {
	Method      string
	Path        string
	ContentType string
}

type routeTraceRecorder struct {
	steps []qinternal.PipelineTraceStep
}

func (r *routeTraceRecorder) Record(step qinternal.PipelineTraceStep) {
	r.steps = append(r.steps, step)
}

func formatByteCount(n int) string {
	if n < 1024 {
		return fmt.Sprintf("%dB", n)
	}
	if n < 1024*1024 {
		return fmt.Sprintf("%.1fKiB", float64(n)/1024)
	}
	return fmt.Sprintf("%.1fMiB", float64(n)/(1024*1024))
}

func formatTraceDuration(d time.Duration) string {
	if d < time.Millisecond {
		return fmt.Sprintf("%.3fms", float64(d)/float64(time.Millisecond))
	}
	return fmt.Sprintf("%dms", d.Milliseconds())
}

func formatTraceContent(encoding qinternal.Encoding, contentType string, bytes int) string {
	if contentType == "" {
		contentType = "-"
	}
	return fmt.Sprintf("%s/%s/%s", encoding.String(), contentType, formatByteCount(bytes))
}

func logRouteTrace(logPrefix string, recorder *routeTraceRecorder) {
	if recorder == nil || len(recorder.steps) == 0 {
		return
	}
	for _, step := range recorder.steps {
		log.Printf(
			"%s: recipe[%d] %s input=%s output=%s duration=%s",
			logPrefix,
			step.StageIndex+1,
			step.StageLabel,
			formatTraceContent(step.InputEncoding, step.InputContentType, step.InputBytes),
			formatTraceContent(step.OutputEncoding, step.OutputContentType, step.OutputBytes),
			formatTraceDuration(step.Duration),
		)
	}
}

func validateRouteAssetRoots(recipesRoot string, componentsRoot string) error {
	if err := qinternal.ValidateOptionalDirectory("recipes", recipesRoot); err != nil {
		return err
	}
	if err := qinternal.ValidateOptionalDirectory("components", componentsRoot); err != nil {
		return err
	}
	return nil
}

func resolveRouteProjectConfig(contentRoot string, recipesRoot string, componentsRoot string) (qinternal.RouterProjectConfig, error) {
	projectConfig, err := qinternal.ResolveRouterProjectConfig(qinternal.RouterProjectConfig{
		ContentRoot:    contentRoot,
		RecipesRoot:    recipesRoot,
		ComponentsRoot: componentsRoot,
	})
	if err != nil {
		return qinternal.RouterProjectConfig{}, err
	}
	if err := validateRouteAssetRoots(projectConfig.RecipesRoot, projectConfig.ComponentsRoot); err != nil {
		return qinternal.RouterProjectConfig{}, err
	}
	if err := qinternal.ValidateOptionalDirectory("elements", projectConfig.ElementsRoot); err != nil {
		return qinternal.RouterProjectConfig{}, err
	}
	return projectConfig, nil
}

func routePathCmd(args []string, method string, usage string, logPrefix string) {
	opts := options{
		contentTypeChecking: ContentTypeCheckingStrong,
	}
	var recipesRoot string
	var componentsRoot string
	var modeRaw string

	fs := flag.NewFlagSet("router "+strings.ToLower(method), flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var routeVerbose bool
	fs.BoolVar(&routeVerbose, "v", false, "enable verbose logging")
	fs.BoolVar(&routeVerbose, "verbose", false, "enable verbose logging")
	fs.StringVar(&recipesRoot, "recipes", "", "recipe QIP components root directory")
	fs.StringVar(&componentsRoot, "components", "", "browser-loadable QIP components root directory")
	fs.StringVar(&modeRaw, "mode", string(modeDev), "runtime mode: dev or prod")
	if err := fs.Parse(normalizeRouteArgs(args)); err != nil {
		if err == flag.ErrHelp {
			fmt.Println(usage)
			return
		}
		gameOver("%s %v", usage, err)
	}

	mode, err := parseRuntimeMode(modeRaw)
	if err != nil {
		gameOver("%v", err)
	}

	opts.verbose = routeVerbose
	opts.mode = mode

	rest := fs.Args()
	if len(rest) != 2 {
		gameOver("%s", usage)
	}
	contentRoot := rest[0]
	requestPath := rest[1]
	if requestPath == "" {
		requestPath = "/"
	}

	if err := validateContentRootArg(contentRoot); err != nil {
		gameOver("%v", err)
	}
	projectConfig, err := resolveRouteProjectConfig(contentRoot, recipesRoot, componentsRoot)
	if err != nil {
		gameOver("%v", err)
	}
	recipesRoot = projectConfig.RecipesRoot
	componentsRoot = projectConfig.ComponentsRoot

	routeOptions := qinternal.DefaultRouteOptions()
	state, err := loadRouterServerState(context.Background(), RouterFileLayout{
		ContentRoot:    contentRoot,
		RecipesRoot:    recipesRoot,
		ComponentsRoot: componentsRoot,
		ElementsRoot:   projectConfig.ElementsRoot,
	}, newQIPRuntime(opts), routeOptions)
	if err != nil {
		gameOver("%v", err)
	}
	stateSlot := newRouterServerStateSlot(state)
	defer func() {
		current := stateSlot.clear()
		if current != nil {
			current.close(context.Background())
		}
	}()

	handlerTimeouts := RouterServerTimeouts{
		contentRecipe:   defaultRouteRecipeTimeout,
		applicationWARC: defaultRouteWARCTransformTimeout,
	}
	handler := newRouterRequestHandler(logPrefix, stateSlot, nil, nil, routeOptions, handlerTimeouts)
	requestCtx := context.Background()
	var traceRecorder *routeTraceRecorder
	if routeVerbose {
		traceRecorder = &routeTraceRecorder{}
		requestCtx = qinternal.WithPipelineTrace(requestCtx, traceRecorder.Record)
	}
	response, err := qinternal.ServeInProcessHTTPWithContext(handler, requestCtx, method, requestPath, nil)
	if err != nil {
		gameOver("%v", err)
	}
	logRouteTrace(logPrefix, traceRecorder)

	if contentType := response.Header.Get("Content-Type"); contentType != "" {
		log.Printf("%s: Content-Type: %s", logPrefix, contentType)
	}
	if etag := response.Header.Get("ETag"); etag != "" {
		log.Printf("%s: ETag: %s", logPrefix, etag)
	}
	if location := response.Header.Get("Location"); location != "" {
		log.Printf("%s: Location: %s", logPrefix, location)
	}
	contentLength := response.Header.Get("Content-Length")
	if contentLength == "" {
		contentLength = strconv.Itoa(len(response.Body))
	}
	log.Printf("%s: Content-Length: %s", logPrefix, contentLength)

	if method != http.MethodHead && len(response.Body) > 0 {
		if _, err := os.Stdout.Write(response.Body); err != nil {
			gameOver("Error writing response body: %v", err)
		}
	}

	if response.StatusCode >= http.StatusBadRequest {
		statusText := http.StatusText(response.StatusCode)
		if statusText == "" {
			gameOver("%d", response.StatusCode)
		}
		gameOver("%d %s", response.StatusCode, statusText)
	}
}

func routeKindredCmd(args []string) {
	routePathCmdWithState(args, usageRouteKindred, func(ctx context.Context, state *RouterServerState, requestPath string, routeOptions qinternal.RouteOptions, timeouts RouterServerTimeouts) error {
		canonical, redirect := qinternal.CanonicalRequestPath(requestPath, routeOptions)
		if redirect {
			requestPath = canonical
		}
		response, ok, err := resolveRouterBaseResponse(ctx, state, requestPath, 0, timeouts)
		if err != nil {
			return err
		}
		if !ok {
			return fmt.Errorf("route not found: %s", requestPath)
		}
		routes, err := qinternal.KindredRoutes(requestPath, response, func(parentPath string) (qinternal.InProcessHTTPResponse, bool, error) {
			return resolveRouterBaseResponse(ctx, state, parentPath, 0, timeouts)
		}, func(staticPath string) (qinternal.InProcessHTTPResponse, bool, error) {
			return resolveKindredStaticRoute(ctx, state, staticPath)
		})
		if err != nil {
			return err
		}
		for _, route := range routes {
			if route.RequestPath == requestPath {
				continue
			}
			fmt.Printf("GET %s\n", route.RequestPath)
		}
		return nil
	})
}

func routePathCmdWithState(args []string, usage string, run func(context.Context, *RouterServerState, string, qinternal.RouteOptions, RouterServerTimeouts) error) {
	opts := options{
		contentTypeChecking: ContentTypeCheckingStrong,
	}
	var recipesRoot string
	var componentsRoot string
	var modeRaw string

	fs := flag.NewFlagSet("router kindred", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var routeVerbose bool
	fs.BoolVar(&routeVerbose, "v", false, "enable verbose logging")
	fs.BoolVar(&routeVerbose, "verbose", false, "enable verbose logging")
	fs.StringVar(&recipesRoot, "recipes", "", "recipe QIP components root directory")
	fs.StringVar(&componentsRoot, "components", "", "browser-loadable QIP components root directory")
	fs.StringVar(&modeRaw, "mode", string(modeDev), "runtime mode: dev or prod")
	if err := fs.Parse(normalizeRouteArgs(args)); err != nil {
		if err == flag.ErrHelp {
			fmt.Println(usage)
			return
		}
		gameOver("%s %v", usage, err)
	}

	mode, err := parseRuntimeMode(modeRaw)
	if err != nil {
		gameOver("%v", err)
	}
	opts.verbose = routeVerbose
	opts.mode = mode

	rest := fs.Args()
	if len(rest) != 2 {
		gameOver("%s", usage)
	}
	contentRoot := rest[0]
	requestPath := rest[1]
	if requestPath == "" {
		requestPath = "/"
	}
	if err := validateContentRootArg(contentRoot); err != nil {
		gameOver("%v", err)
	}
	projectConfig, err := resolveRouteProjectConfig(contentRoot, recipesRoot, componentsRoot)
	if err != nil {
		gameOver("%v", err)
	}

	routeOptions := qinternal.DefaultRouteOptions()
	timeouts := RouterServerTimeouts{
		contentRecipe:   defaultRouteRecipeTimeout,
		applicationWARC: defaultRouteWARCTransformTimeout,
	}
	state, err := loadRouterServerState(context.Background(), RouterFileLayout{
		ContentRoot:    contentRoot,
		RecipesRoot:    projectConfig.RecipesRoot,
		ComponentsRoot: projectConfig.ComponentsRoot,
		ElementsRoot:   projectConfig.ElementsRoot,
	}, newQIPRuntime(opts), routeOptions)
	if err != nil {
		gameOver("%v", err)
	}
	defer state.close(context.Background())
	if err := run(context.Background(), state, requestPath, routeOptions, timeouts); err != nil {
		gameOver("%v", err)
	}
}

func routeListCmd(args []string) {
	opts := options{
		contentTypeChecking: ContentTypeCheckingStrong,
	}
	var recipesRoot string
	var componentsRoot string
	var modeRaw string

	fs := flag.NewFlagSet("router list", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var routeVerbose bool
	fs.BoolVar(&routeVerbose, "v", false, "enable verbose logging")
	fs.BoolVar(&routeVerbose, "verbose", false, "enable verbose logging")
	fs.StringVar(&recipesRoot, "recipes", "", "recipe QIP components root directory")
	fs.StringVar(&componentsRoot, "components", "", "browser-loadable QIP components root directory")
	fs.StringVar(&modeRaw, "mode", string(modeDev), "runtime mode: dev or prod")
	if err := fs.Parse(normalizeRouteArgs(args)); err != nil {
		if err == flag.ErrHelp {
			fmt.Println(usageRouteList)
			return
		}
		gameOver("%s %v", usageRouteList, err)
	}

	mode, err := parseRuntimeMode(modeRaw)
	if err != nil {
		gameOver("%v", err)
	}

	opts.verbose = routeVerbose
	opts.mode = mode

	rest := fs.Args()
	if len(rest) != 1 {
		gameOver("%s", usageRouteList)
	}
	contentRoot := rest[0]

	if err := validateContentRootArg(contentRoot); err != nil {
		gameOver("%v", err)
	}
	projectConfig, err := resolveRouteProjectConfig(contentRoot, recipesRoot, componentsRoot)
	if err != nil {
		gameOver("%v", err)
	}
	recipesRoot = projectConfig.RecipesRoot
	componentsRoot = projectConfig.ComponentsRoot

	routeOptions := qinternal.DefaultRouteOptions()
	state, err := loadRouterServerState(context.Background(), RouterFileLayout{
		ContentRoot:    contentRoot,
		RecipesRoot:    recipesRoot,
		ComponentsRoot: componentsRoot,
		ElementsRoot:   projectConfig.ElementsRoot,
	}, newQIPRuntime(opts), routeOptions)
	if err != nil {
		gameOver("%v", err)
	}
	defer state.close(context.Background())

	entries := buildRouteListEntries(state)
	for _, entry := range entries {
		fmt.Printf("%-4s %s  %s\n", entry.Method, entry.Path, entry.ContentType)
	}
}

func buildRouteListEntries(state *RouterServerState) []routeListEntry {
	if state == nil {
		return nil
	}

	canonicalRoutes := make(map[string]qinternal.ContentRoute, len(state.contentRoutes))
	for requestPath := range state.contentRoutes {
		canonicalPath, _ := qinternal.CanonicalRequestPath(requestPath, state.routeOptions)
		if _, exists := canonicalRoutes[canonicalPath]; exists {
			continue
		}
		route, ok := qinternal.ResolveContentRoute(state.contentRoutes, canonicalPath, state.routeOptions)
		if !ok {
			continue
		}
		canonicalRoutes[canonicalPath] = route
	}

	paths := make([]string, 0, len(canonicalRoutes))
	for requestPath := range canonicalRoutes {
		paths = append(paths, requestPath)
	}
	sort.Strings(paths)

	entries := make([]routeListEntry, 0, len(paths)*2)
	for _, requestPath := range paths {
		route := canonicalRoutes[requestPath]
		hasRecipes := shouldApplyRecipesForRequestPath(requestPath, route, state.recipeChains)
		contentType := routerResponseContentType(route.SourceMIME, hasRecipes, qinternal.NewRawBytesContent(nil), nil)
		if hasRecipes {
			if recipeType := state.recipeOutput[route.SourceMIME]; recipeType != "" {
				contentType = recipeType
			}
		}
		contentType = mediaTypeOnly(contentType)
		entries = append(entries, routeListEntry{
			Method:      http.MethodGet,
			Path:        requestPath,
			ContentType: contentType,
		})
		entries = append(entries, routeListEntry{
			Method:      http.MethodHead,
			Path:        requestPath,
			ContentType: contentType,
		})
	}
	for _, requestPath := range state.componentRequestPaths {
		asset, ok := state.componentAssets[requestPath]
		if !ok {
			continue
		}
		contentType := mediaTypeOnly(asset.contentType)
		entries = append(entries, routeListEntry{
			Method:      http.MethodGet,
			Path:        requestPath,
			ContentType: contentType,
		})
		entries = append(entries, routeListEntry{
			Method:      http.MethodHead,
			Path:        requestPath,
			ContentType: contentType,
		})
	}
	for _, requestPath := range state.elementRequestPaths {
		contentType := "text/javascript"
		if state.recipeChains[contentType] != nil && state.recipeOutput[contentType] != "" {
			contentType = mediaTypeOnly(state.recipeOutput[contentType])
		}
		entries = append(entries, routeListEntry{Method: http.MethodGet, Path: requestPath, ContentType: contentType})
		entries = append(entries, routeListEntry{Method: http.MethodHead, Path: requestPath, ContentType: contentType})
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].Path != entries[j].Path {
			return entries[i].Path < entries[j].Path
		}
		return entries[i].Method < entries[j].Method
	})
	return entries
}

func mediaTypeOnly(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return "application/octet-stream"
	}
	mediaType, _, err := mime.ParseMediaType(value)
	if err == nil && mediaType != "" {
		return mediaType
	}
	if cut := strings.IndexByte(value, ';'); cut != -1 {
		value = strings.TrimSpace(value[:cut])
	}
	if value == "" {
		return "application/octet-stream"
	}
	return value
}

func routerCmd(args []string) {
	if len(args) == 0 {
		gameOver(usageRoute)
	}
	if args[0] == "--help" || args[0] == "-h" || args[0] == "help" {
		fmt.Println(usageRoute)
		return
	}
	switch args[0] {
	case "dev":
		devCmd(args[1:])
		return
	case "get":
		routePathCmd(args[1:], http.MethodGet, usageRouteGet, "router get")
		return
	case "head":
		routePathCmd(args[1:], http.MethodHead, usageRouteHead, "router head")
		return
	case "kindred":
		routeKindredCmd(args[1:])
		return
	case "list":
		routeListCmd(args[1:])
		return
	case "warc":
	default:
		gameOver(usageRoute)
	}

	type routeRuntime struct {
		state        *RouterServerState
		routeOptions qinternal.RouteOptions
		// resolveBase caches content recipe output so --check-kindred can
		// reuse it for every page's Kindred Routes.
		resolveBase qinternal.KindredRouteResolver
	}
	handlerTimeouts := RouterServerTimeouts{
		contentRecipe:   defaultRouteRecipeTimeout,
		applicationWARC: defaultRouteWARCTransformTimeout,
	}
	warcTransformTimeout := defaultRouteWARCTransformTimeout
	var runtimeMu sync.Mutex
	var runtime *routeRuntime
	ensureRuntime := func(ctx context.Context, request qcmd.RouteWARCRequest) (*routeRuntime, error) {
		runtimeMu.Lock()
		defer runtimeMu.Unlock()
		if runtime != nil {
			return runtime, nil
		}

		mode, err := parseRuntimeMode(request.ModeRaw)
		if err != nil {
			return nil, err
		}
		opts := options{
			verbose:             request.Verbose,
			mode:                mode,
			contentTypeChecking: ContentTypeCheckingStrong,
			// --check-kindred renders each WARC recipe once per page.
			reuseInstances: request.CheckKindred,
		}

		if err := validateContentRootArg(request.ContentRoot); err != nil {
			return nil, err
		}
		projectConfig, err := resolveRouteProjectConfig(request.ContentRoot, request.RecipesRoot, request.ComponentsRoot)
		if err != nil {
			return nil, err
		}

		routeOptions := qinternal.DefaultRouteOptions()
		state, err := loadRouterServerState(ctx, RouterFileLayout{
			ContentRoot:    request.ContentRoot,
			RecipesRoot:    projectConfig.RecipesRoot,
			ComponentsRoot: projectConfig.ComponentsRoot,
			ElementsRoot:   projectConfig.ElementsRoot,
			ViewSource:     request.ViewSource,
		}, newQIPRuntime(opts), routeOptions)
		if err != nil {
			return nil, err
		}
		runtime = &routeRuntime{
			state:        state,
			routeOptions: routeOptions,
			resolveBase: memoKindredResolver(func(requestPath string) (qinternal.InProcessHTTPResponse, bool, error) {
				return resolveRouterBaseResponse(context.Background(), state, requestPath, 0, handlerTimeouts)
			}),
		}
		return runtime, nil
	}
	defer func() {
		runtimeMu.Lock()
		defer runtimeMu.Unlock()
		if runtime == nil || runtime.state == nil {
			return
		}
		runtime.state.close(context.Background())
		runtime.state = nil
	}()

	if err := qcmd.RunRoute(args, qcmd.RouteConfig{
		UsageRoute:     usageRoute,
		UsageRouteWarc: usageRouteWarc,
		DefaultMode:    string(modeDev),
		ListWARCPaths: func(ctx context.Context, request qcmd.RouteWARCRequest) ([]string, error) {
			loaded, err := ensureRuntime(ctx, request)
			if err != nil {
				return nil, err
			}

			pathSet := make(map[string]struct{}, len(loaded.state.contentRoutes))
			for requestPath := range loaded.state.contentRoutes {
				canonical, _ := qinternal.CanonicalRequestPath(requestPath, loaded.routeOptions)
				pathSet[canonical] = struct{}{}
			}
			for _, requestPath := range loaded.state.componentRequestPaths {
				pathSet[requestPath] = struct{}{}
			}
			for _, requestPath := range loaded.state.elementRequestPaths {
				pathSet[requestPath] = struct{}{}
			}

			paths := make([]string, 0, len(pathSet))
			for requestPath := range pathSet {
				paths = append(paths, requestPath)
			}
			sort.Strings(paths)
			return paths, nil
		},
		ResolveWARC: func(ctx context.Context, request qcmd.RouteWARCRequest) (qinternal.InProcessHTTPResponse, error) {
			loaded, err := ensureRuntime(ctx, request)
			if err != nil {
				return qinternal.InProcessHTTPResponse{}, err
			}
			if asset, ok := loaded.state.componentAssets[request.RequestPath]; ok {
				return qinternal.InProcessHTTPResponse{
					StatusCode: http.StatusOK,
					Header:     http.Header{"Content-Type": []string{asset.contentType}},
					Body:       asset.body,
				}, nil
			}
			if _, ok := loaded.state.elementAssets[request.RequestPath]; ok {
				response, ok, err := resolveElementAssetResponse(ctx, loaded.state, request.RequestPath, 0, handlerTimeouts)
				if err != nil {
					return qinternal.InProcessHTTPResponse{}, err
				}
				if ok {
					return response, nil
				}
			}
			var response qinternal.InProcessHTTPResponse
			var ok bool
			if request.CheckKindred {
				response, ok, err = loaded.resolveBase(request.RequestPath)
			} else {
				requestCtx := ctx
				var traceRecorder *routeTraceRecorder
				if request.Verbose {
					traceRecorder = &routeTraceRecorder{}
					requestCtx = qinternal.WithPipelineTrace(requestCtx, traceRecorder.Record)
				}
				response, ok, err = resolveRouterBaseResponse(requestCtx, loaded.state, request.RequestPath, 0, handlerTimeouts)
				logRouteTrace("router warc "+request.RequestPath, traceRecorder)
			}
			if err != nil {
				return qinternal.InProcessHTTPResponse{}, err
			}
			if !ok {
				return qinternal.InProcessHTTPResponse{
					StatusCode: http.StatusNotFound,
					Header:     http.Header{"Content-Type": []string{"text/plain; charset=utf-8"}},
					Body:       []byte("404 page not found\n"),
				}, nil
			}
			return response, nil
		},
		TransformWARC: func(ctx context.Context, request qcmd.RouteWARCRequest, warc []byte) ([]byte, error) {
			loaded, err := ensureRuntime(ctx, request)
			if err != nil {
				return nil, err
			}
			pipeline := loaded.state.recipeChains[applicationWARCRecipeMIME]
			if pipeline == nil {
				return warc, nil
			}
			execCtx, cancel := withExecutionTimeout(ctx, scaleRouteWARCTransformTimeout(warcTransformTimeout, request.RouteCount))
			defer cancel()
			var traceRecorder *routeTraceRecorder
			if request.Verbose {
				traceRecorder = &routeTraceRecorder{}
				execCtx = qinternal.WithPipelineTrace(execCtx, traceRecorder.Record)
			}
			transformed, err := processApplicationWARCArchive(execCtx, pipeline, warc, 0)
			if err != nil {
				return nil, err
			}
			logRouteTrace("router warc archive", traceRecorder)
			if request.CheckKindred {
				start := time.Now()
				pagePaths := kindredCheckPagePaths(loaded.state, loaded.routeOptions)
				err := checkKindredWARC(ctx, pipeline, qcmd.RouteWARCOrigin(request.Host), pagePaths, transformed, loaded.resolveBase, func(requestPath string) (qinternal.InProcessHTTPResponse, bool, error) {
					return resolveKindredStaticRoute(ctx, loaded.state, requestPath)
				}, loaded.state.elementEntryPaths, func(requestPath string) (qinternal.InProcessHTTPResponse, bool, error) {
					return resolveElementAssetResponse(ctx, loaded.state, requestPath, 0, handlerTimeouts)
				}, warcTransformTimeout)
				if err != nil {
					return nil, err
				}
				if request.Verbose {
					log.Printf("router warc --check-kindred: %d pages match in %s", len(pagePaths), formatTraceDuration(time.Since(start)))
				}
			}
			return transformed, nil
		},
		Verbosef: func(format string, args ...any) {
			log.Printf(format, args...)
		},
	}); err != nil {
		gameOver("%v", err)
	}
}
