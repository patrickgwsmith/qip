package cmd

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"

	qinternal "github.com/royalicing/qip/internal"
	qwarc "github.com/royalicing/qip/internal/warc"
)

type RouteWARCRequest struct {
	ContentRoot    string
	RequestPath    string
	RouteCount     int
	RecipesRoot    string
	ComponentsRoot string
	ModeRaw        string
	Host           string
	Verbose        bool
	ViewSource     bool
	CheckKindred   bool
	ContentFilter  qinternal.ContentPathFilter
}

type RouteConfig struct {
	UsageRoute     string
	UsageRouteWarc string
	DefaultMode    string
	ListWARCPaths  func(context.Context, RouteWARCRequest) ([]string, error)
	// ListWARCContextPaths lists parent pages that the content filter leaves
	// out but whose layouts apply to archived pages. They are archived for
	// the WARC recipes and removed from the final archive.
	ListWARCContextPaths func(context.Context, RouteWARCRequest, []string) ([]string, error)
	ResolveWARC          func(context.Context, RouteWARCRequest) (qinternal.InProcessHTTPResponse, error)
	TransformWARC        func(context.Context, RouteWARCRequest, []byte) ([]byte, error)
	Stdout               io.Writer
	WriteFile            func(string, []byte, os.FileMode) error
	Verbosef             func(format string, args ...any)
}

func RunRoute(args []string, config RouteConfig) error {
	if config.ListWARCPaths == nil {
		return errors.New("route path lister is required")
	}
	if config.ResolveWARC == nil {
		return errors.New("route resolver is required")
	}
	if config.Stdout == nil {
		config.Stdout = os.Stdout
	}
	if config.WriteFile == nil {
		config.WriteFile = os.WriteFile
	}
	if config.DefaultMode == "" {
		config.DefaultMode = "dev"
	}

	if len(args) == 0 {
		return errors.New(config.UsageRoute)
	}
	switch args[0] {
	case "warc":
		return runRouteWARC(args[1:], config)
	default:
		return errors.New(config.UsageRoute)
	}
}

func runRouteWARC(args []string, config RouteConfig) error {
	var recipesRoot string
	var componentsRoot string
	var modeRaw string
	hostRaw := "qip.local"
	outputPath := "-"
	viewSource := false
	checkKindred := false
	var filterFlags qinternal.ContentFilterFlags

	fs := flag.NewFlagSet("route warc", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var verbose bool
	fs.BoolVar(&verbose, "v", false, "enable verbose logging")
	fs.BoolVar(&verbose, "verbose", false, "enable verbose logging")
	fs.StringVar(&recipesRoot, "recipes", "", "recipe QIP components root directory")
	fs.StringVar(&componentsRoot, "components", "", "browser-loadable QIP components root directory")
	fs.StringVar(&modeRaw, "mode", config.DefaultMode, "runtime mode")
	fs.StringVar(&hostRaw, "host", hostRaw, "WARC-Target-URI host")
	fs.StringVar(&outputPath, "o", "-", "output WARC path ('-' for stdout)")
	fs.StringVar(&outputPath, "output", "-", "output WARC path ('-' for stdout)")
	fs.BoolVar(&viewSource, "view-source", false, "include /view-source plus recipe source files from --recipes")
	fs.BoolVar(&checkKindred, "check-kindred", false, "rerun each page's WARC recipes with only its Kindred Routes and fail if any output differs")
	var contentRoot string
	qinternal.RegisterRouterCWDFlag(fs, &contentRoot)
	filterFlags.Register(fs)
	if err := fs.Parse(normalizeRouteWarcArgs(args)); err != nil {
		if err == flag.ErrHelp {
			fmt.Println(config.UsageRouteWarc)
			return nil
		}
		return fmt.Errorf("%s %w", config.UsageRouteWarc, err)
	}

	host, err := parseRouteWARCHost(hostRaw)
	if err != nil {
		return err
	}
	contentFilter, err := filterFlags.Filter()
	if err != nil {
		return err
	}

	rest := fs.Args()
	if err := qinternal.CheckRouterPositionalContentDir("warc", rest, 0); err != nil {
		return err
	}
	if len(rest) != 0 {
		return errors.New(config.UsageRouteWarc)
	}

	projectConfig, err := qinternal.ResolveRouterProjectConfig(qinternal.RouterProjectConfig{
		ContentRoot:    contentRoot,
		RecipesRoot:    recipesRoot,
		ComponentsRoot: componentsRoot,
	})
	if err != nil {
		return err
	}
	recipesRoot = projectConfig.RecipesRoot
	componentsRoot = projectConfig.ComponentsRoot
	if viewSource && strings.TrimSpace(recipesRoot) == "" {
		return errors.New("--view-source requires --recipes <recipes_dir>")
	}
	baseRequest := RouteWARCRequest{
		ContentRoot:    contentRoot,
		RecipesRoot:    recipesRoot,
		ComponentsRoot: componentsRoot,
		ModeRaw:        modeRaw,
		Host:           host,
		Verbose:        verbose,
		ViewSource:     viewSource,
		CheckKindred:   checkKindred,
		ContentFilter:  contentFilter,
	}

	paths, err := config.ListWARCPaths(context.Background(), baseRequest)
	if err != nil {
		return err
	}
	if len(paths) == 0 {
		return errors.New("no route paths found to archive")
	}
	sort.Strings(paths)

	var contextPaths []string
	if config.ListWARCContextPaths != nil {
		contextPaths, err = config.ListWARCContextPaths(context.Background(), baseRequest, paths)
		if err != nil {
			return err
		}
	}
	contextPathSet := make(map[string]struct{}, len(contextPaths))
	for _, requestPath := range contextPaths {
		contextPathSet[requestPath] = struct{}{}
	}
	archivePaths := append(append([]string(nil), paths...), contextPaths...)
	sort.Strings(archivePaths)
	baseRequest.RouteCount = len(archivePaths)

	var warcBytes bytes.Buffer
	contextURIs := make(map[string]struct{}, len(contextPaths))
	for _, requestPath := range archivePaths {
		request := baseRequest
		request.RequestPath = requestPath

		response, err := config.ResolveWARC(context.Background(), request)
		if err != nil {
			return fmt.Errorf("failed to resolve path %q: %w", requestPath, err)
		}
		if _, ok := contextPathSet[requestPath]; ok {
			if !qinternal.IsKindredParentResponse(response) {
				continue
			}
			contextURIs[buildRouteWARCRequestURI(host, requestPath)] = struct{}{}
		}

		requestURI := buildRouteWARCRequestURI(host, requestPath)
		record, err := buildMinimalWARCResponseRecord(requestURI, response)
		if err != nil {
			return fmt.Errorf("failed to build WARC record for %q: %w", requestPath, err)
		}
		warcBytes.Write(record)
	}

	if viewSource {
		markdownPaths := qinternal.FilterMarkdownRequestPaths(paths)
		modulePaths := filterComponentRequestPaths(paths)
		sourceRecords, err := buildRecipeSourceWARCRecords(host, recipesRoot, componentsRoot, markdownPaths, modulePaths)
		if err != nil {
			return err
		}
		for _, record := range sourceRecords {
			warcBytes.Write(record)
		}
	}

	warcOutput := warcBytes.Bytes()
	if config.TransformWARC != nil {
		transformed, err := config.TransformWARC(context.Background(), baseRequest, warcOutput)
		if err != nil {
			return fmt.Errorf("failed to transform warc archive: %w", err)
		}
		warcOutput = transformed
	}
	warcOutput, err = qwarc.RemoveResponseRecords(warcOutput, contextURIs)
	if err != nil {
		return fmt.Errorf("failed to remove filtered parent pages from warc archive: %w", err)
	}
	if err := qwarc.ValidateArchive(warcOutput); err != nil {
		return fmt.Errorf("invalid final WARC archive: %w", err)
	}

	if outputPath == "" || outputPath == "-" {
		if _, err := config.Stdout.Write(warcOutput); err != nil {
			return fmt.Errorf("error writing WARC to stdout: %w", err)
		}
	} else {
		if err := config.WriteFile(outputPath, warcOutput, 0o644); err != nil {
			return fmt.Errorf("error writing WARC file: %w", err)
		}
	}

	if verbose && config.Verbosef != nil {
		config.Verbosef("route warc: host=%s paths=%d bytes=%d output=%s", host, len(paths), len(warcOutput), outputPath)
	}
	return nil
}

func parseRouteWARCHost(raw string) (string, error) {
	host := strings.TrimSpace(raw)
	if host == "" {
		return "", errors.New("host must not be empty")
	}
	if !strings.Contains(host, "://") {
		if strings.ContainsAny(host, "/?#") {
			return "", fmt.Errorf("invalid host %q", raw)
		}
		return host, nil
	}
	origin, err := url.Parse(host)
	if err != nil ||
		(origin.Scheme != "http" && origin.Scheme != "https") ||
		origin.Host == "" ||
		origin.User != nil ||
		(origin.Path != "" && origin.Path != "/") ||
		origin.RawQuery != "" ||
		origin.Fragment != "" {
		return "", fmt.Errorf("invalid host %q", raw)
	}
	return origin.Scheme + "://" + origin.Host, nil
}

// RouteWARCOrigin returns the scheme and host that prefix every
// WARC-Target-URI in a route WARC archive.
func RouteWARCOrigin(host string) string {
	if !strings.Contains(host, "://") {
		return "http://" + host
	}
	return host
}

func buildRouteWARCRequestURI(host string, requestPath string) string {
	origin := RouteWARCOrigin(host)
	if !strings.HasPrefix(requestPath, "/") {
		requestPath = "/" + requestPath
	}
	return origin + requestPath
}

func normalizeRouteWarcArgs(args []string) []string {
	flagsWithValue := map[string]struct{}{
		"--recipes":    {},
		"--components": {},
		"--mode":       {},
		"--host":       {},
		"-o":           {},
		"--output":     {},
	}
	for _, name := range qinternal.ContentFilterFlagNames {
		flagsWithValue[name] = struct{}{}
	}
	for _, name := range qinternal.RouterCWDFlagNames {
		flagsWithValue[name] = struct{}{}
	}
	return qinternal.NormalizeFlagArgs(args, flagsWithValue)
}

func buildMinimalWARCResponseRecord(targetURI string, response qinternal.InProcessHTTPResponse) ([]byte, error) {
	return qwarc.BuildHTTPResponseRecord(targetURI, response.StatusCode, response.Header, response.Body)
}

func buildRecipeSourceWARCRecords(host string, recipesRoot string, componentsRoot string, markdownRequestPaths []string, componentRequestPaths []string) ([][]byte, error) {
	recipeAssets, err := qinternal.CollectRecipeSourceAssets(recipesRoot)
	if err != nil {
		return nil, err
	}
	componentSourceAssets, err := qinternal.CollectComponentSourceAssets(componentsRoot)
	if err != nil {
		return nil, err
	}
	indexBody := qinternal.BuildViewSourceIndexHTML(recipeAssets, markdownRequestPaths, componentRequestPaths, componentSourceAssets)
	indexResponse := qinternal.InProcessHTTPResponse{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{"text/html; charset=utf-8"}},
		Body:       indexBody,
	}
	records := make([][]byte, 0, len(recipeAssets)+len(componentSourceAssets)+1)
	indexRecord, err := buildMinimalWARCResponseRecord(buildRouteWARCRequestURI(host, "/view-source"), indexResponse)
	if err != nil {
		return nil, fmt.Errorf("failed to build WARC record for %q: %w", "/view-source", err)
	}
	records = append(records, indexRecord)
	for _, asset := range recipeAssets {
		response := qinternal.InProcessHTTPResponse{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{asset.ContentType}},
			Body:       asset.Body,
		}
		record, err := buildMinimalWARCResponseRecord(buildRouteWARCRequestURI(host, asset.RequestPath), response)
		if err != nil {
			return nil, fmt.Errorf("failed to build WARC record for %q: %w", asset.RequestPath, err)
		}
		records = append(records, record)
	}
	for _, asset := range componentSourceAssets {
		response := qinternal.InProcessHTTPResponse{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{asset.ContentType}},
			Body:       asset.Body,
		}
		record, err := buildMinimalWARCResponseRecord(buildRouteWARCRequestURI(host, asset.RequestPath), response)
		if err != nil {
			return nil, fmt.Errorf("failed to build WARC record for %q: %w", asset.RequestPath, err)
		}
		records = append(records, record)
	}
	return records, nil
}

func filterComponentRequestPaths(paths []string) []string {
	out := make([]string, 0, len(paths))
	for _, p := range paths {
		if strings.HasPrefix(p, "/") && strings.HasSuffix(p, ".wasm") {
			out = append(out, p)
		}
	}
	return out
}
