package qinternal

import (
	"context"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
	"unicode/utf8"
)

type InProcessHTTPResponse struct {
	StatusCode int
	Header     http.Header
	Body       []byte
}

type ContentRoute struct {
	FilePath   string
	SourceMIME string
}

type ContentRouteEntry struct {
	RelPath  string
	FilePath string
}

type TrailingSlashMode string

const (
	TrailingSlashModeNever  TrailingSlashMode = "never"
	TrailingSlashModeAlways TrailingSlashMode = "always"
)

type RouteOptions struct {
	TrailingSlashMode TrailingSlashMode
}

func DefaultRouteOptions() RouteOptions {
	return RouteOptions{
		TrailingSlashMode: TrailingSlashModeNever,
	}
}

type RoutedResponse struct {
	StatusCode             int
	Header                 http.Header
	Body                   []byte
	ModuleDurations        []time.Duration
	InstantiationDurations []time.Duration
}

type RequestHandlerConfig struct {
	LogPrefix      string
	RouteOptions   RouteOptions
	Reload         func()
	Resolve        func(r *http.Request, requestID uint64) (RoutedResponse, error)
	WriteError     func(http.ResponseWriter, error)
	FormatDuration func(total time.Duration, moduleDurations []time.Duration, instantiationDurations []time.Duration) string
	Logf           func(format string, args ...any)
}

func NewRequestHandler(config RequestHandlerConfig) http.Handler {
	logf := config.Logf
	if logf == nil {
		logf = func(string, ...any) {}
	}
	writeError := config.WriteError
	if writeError == nil {
		writeError = func(w http.ResponseWriter, err error) {
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
	}
	formatDuration := config.FormatDuration
	if formatDuration == nil {
		formatDuration = func(total time.Duration, moduleDurations []time.Duration, instantiationDurations []time.Duration) string {
			return fmt.Sprintf("duration_ms=%d", total.Milliseconds())
		}
	}
	routeOptions := normalizeRouteOptions(config.RouteOptions)

	mux := http.NewServeMux()
	var requestID uint64
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		reqID := atomic.AddUint64(&requestID, 1)
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			emptyDurations := []time.Duration{}
			emptyInst := []time.Duration{}
			w.WriteHeader(http.StatusMethodNotAllowed)
			logf("%s: %s %s %s", config.LogPrefix, r.Method, r.URL.Path, formatDuration(time.Since(start), emptyDurations, emptyInst))
			return
		}

		if canonicalPath, changed := CanonicalRequestPath(r.URL.Path, routeOptions); changed {
			location := canonicalPath
			if r.URL.RawQuery != "" {
				location += "?" + r.URL.RawQuery
			}
			w.Header().Set("Location", location)
			w.WriteHeader(http.StatusPermanentRedirect)
			emptyDurations := []time.Duration{}
			emptyInst := []time.Duration{}
			logf("%s: %s %s status=%d %s", config.LogPrefix, r.Method, r.URL.Path, http.StatusPermanentRedirect, formatDuration(time.Since(start), emptyDurations, emptyInst))
			return
		}

		if config.Reload != nil {
			config.Reload()
		}

		response, err := config.Resolve(r, reqID)
		if err != nil {
			writeError(w, err)
			logf("%s: %s %s error=%v %s", config.LogPrefix, r.Method, r.URL.Path, err, formatDuration(time.Since(start), response.ModuleDurations, response.InstantiationDurations))
			return
		}

		for name, values := range response.Header {
			for _, value := range values {
				w.Header().Add(name, value)
			}
		}
		if len(response.Body) > 0 && w.Header().Get("Content-Length") == "" {
			w.Header().Set("Content-Length", strconv.Itoa(len(response.Body)))
		}
		if response.StatusCode == 0 {
			response.StatusCode = http.StatusOK
		}
		w.WriteHeader(response.StatusCode)
		if r.Method != http.MethodHead && len(response.Body) > 0 {
			if _, err := w.Write(response.Body); err != nil {
				logf("%s: %s %s write_error=%v %s", config.LogPrefix, r.Method, r.URL.Path, err, formatDuration(time.Since(start), response.ModuleDurations, response.InstantiationDurations))
				return
			}
		}

		logf("%s: %s %s status=%d %s", config.LogPrefix, r.Method, r.URL.Path, response.StatusCode, formatDuration(time.Since(start), response.ModuleDurations, response.InstantiationDurations))
	})

	return mux
}

func ServeInProcessHTTP(handler http.Handler, method string, requestPath string, headers http.Header) (InProcessHTTPResponse, error) {
	return ServeInProcessHTTPWithContext(handler, context.Background(), method, requestPath, headers)
}

func ServeInProcessHTTPWithContext(handler http.Handler, ctx context.Context, method string, requestPath string, headers http.Header) (InProcessHTTPResponse, error) {
	if handler == nil {
		return InProcessHTTPResponse{}, fmt.Errorf("handler is nil")
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if method == "" {
		method = http.MethodGet
	}
	if requestPath == "" {
		requestPath = "/"
	}
	if !strings.HasPrefix(requestPath, "/") {
		requestPath = "/" + requestPath
	}

	req := httptest.NewRequest(method, "http://qip.local"+requestPath, nil).WithContext(ctx)
	for key, values := range headers {
		for _, value := range values {
			req.Header.Add(key, value)
		}
	}

	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, req)
	resp := recorder.Result()
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return InProcessHTTPResponse{}, fmt.Errorf("failed to read in-process response body: %w", err)
	}
	if method == http.MethodHead {
		if resp.Header.Get("Content-Length") == "" && len(body) > 0 {
			resp.Header.Set("Content-Length", strconv.Itoa(len(body)))
		}
		body = nil
	}

	return InProcessHTTPResponse{
		StatusCode: resp.StatusCode,
		Header:     resp.Header.Clone(),
		Body:       body,
	}, nil
}

func CanonicalRequestPath(requestPath string, options RouteOptions) (string, bool) {
	options = normalizeRouteOptions(options)
	original := requestPath
	if requestPath == "" {
		requestPath = "/"
	}
	if !strings.HasPrefix(requestPath, "/") {
		requestPath = "/" + requestPath
	}

	canonical := path.Clean(requestPath)
	if canonical == "." {
		canonical = "/"
	}
	if !strings.HasPrefix(canonical, "/") {
		canonical = "/" + canonical
	}

	if canonical != "/" {
		switch options.TrailingSlashMode {
		case TrailingSlashModeNever:
			canonical = strings.TrimSuffix(canonical, "/")
			if canonical == "" {
				canonical = "/"
			}
		case TrailingSlashModeAlways:
			if !strings.HasSuffix(canonical, "/") {
				canonical += "/"
			}
		}
	}

	if original == "" {
		return canonical, canonical != "/"
	}
	return canonical, canonical != original
}

func normalizeRouteOptions(options RouteOptions) RouteOptions {
	switch options.TrailingSlashMode {
	case TrailingSlashModeNever, TrailingSlashModeAlways:
		return options
	default:
		return DefaultRouteOptions()
	}
}

func BuildContentRoutes(contentRoot string, options RouteOptions) (map[string]ContentRoute, error) {
	options = normalizeRouteOptions(options)
	files := make([]ContentRouteEntry, 0, 32)
	rootInfo, err := os.Stat(contentRoot)
	if err != nil {
		return nil, err
	}
	if !rootInfo.IsDir() {
		return nil, fmt.Errorf("content root %q must be a directory", contentRoot)
	}

	seenDirs := make(map[string]uint8)
	var walkDir func(readDir string, relDir string) error
	walkDir = func(readDir string, relDir string) error {
		realDir, err := filepath.EvalSymlinks(readDir)
		if err != nil {
			return err
		}
		realDir, err = filepath.Abs(realDir)
		if err != nil {
			return err
		}
		realDir = filepath.Clean(realDir)
		if seenDirs[realDir] > 0 {
			// Avoid infinite recursion on symlink cycles in the current branch.
			return nil
		}
		seenDirs[realDir]++
		defer func() {
			seenDirs[realDir]--
		}()

		entries, err := os.ReadDir(readDir)
		if err != nil {
			return err
		}
		for _, entry := range entries {
			name := entry.Name()
			if relDir == "" && IsReservedRouterDirectoryName(name) {
				continue
			}
			relPath := name
			if relDir != "" {
				relPath = path.Join(relDir, name)
			}
			if err := validateContentRelPath(relPath); err != nil {
				return err
			}

			fullPath := filepath.Join(readDir, name)
			mode := entry.Type()
			if mode.IsRegular() {
				files = append(files, ContentRouteEntry{RelPath: relPath, FilePath: fullPath})
				continue
			}
			if mode.IsDir() {
				if err := walkDir(fullPath, relPath); err != nil {
					return err
				}
				continue
			}
			if mode&fs.ModeSymlink == 0 {
				return fmt.Errorf("content entry %q must be a regular file", fullPath)
			}

			targetInfo, err := os.Stat(fullPath)
			if err != nil {
				return err
			}
			if targetInfo.Mode().IsRegular() {
				files = append(files, ContentRouteEntry{RelPath: relPath, FilePath: fullPath})
				continue
			}
			if targetInfo.IsDir() {
				if err := walkDir(fullPath, relPath); err != nil {
					return err
				}
				continue
			}
			return fmt.Errorf("content entry %q must be a regular file", fullPath)
		}
		return nil
	}

	err = walkDir(contentRoot, "")
	if err != nil {
		return nil, err
	}

	return BuildContentRoutesFromEntries(files, options)
}

func BuildContentRoutesFromEntries(entries []ContentRouteEntry, options RouteOptions) (map[string]ContentRoute, error) {
	options = normalizeRouteOptions(options)
	files := make([]ContentRouteEntry, 0, len(entries))
	for _, entry := range entries {
		if err := validateContentRelPath(entry.RelPath); err != nil {
			return nil, err
		}
		if IsReservedRouterRelPath(entry.RelPath) {
			continue
		}
		if strings.TrimSpace(entry.FilePath) == "" {
			return nil, fmt.Errorf("content path %q is missing file path", entry.RelPath)
		}
		files = append(files, entry)
	}
	sort.Slice(files, func(i, j int) bool {
		return files[i].RelPath < files[j].RelPath
	})

	routes := make(map[string]ContentRoute, len(files))
	for _, entry := range files {
		aliases := contentRequestPaths(entry.RelPath, options)
		route := ContentRoute{
			FilePath:   entry.FilePath,
			SourceMIME: detectSourceMIME(entry.RelPath),
		}
		for _, requestPath := range aliases {
			if prev, exists := routes[requestPath]; exists && prev.FilePath != route.FilePath {
				return nil, fmt.Errorf("duplicate route path %q for %q and %q", requestPath, prev.FilePath, route.FilePath)
			}
			routes[requestPath] = route
		}
	}
	return routes, nil
}

func validateContentRelPath(relPath string) error {
	if !utf8.ValidString(relPath) {
		return fmt.Errorf("content path %q must be valid UTF-8", relPath)
	}
	if strings.Contains(relPath, "\\") {
		return fmt.Errorf("content path %q must not contain backslash", relPath)
	}
	if strings.HasPrefix(relPath, "/") {
		return fmt.Errorf("content path %q must not start with /", relPath)
	}
	cleanRel := path.Clean(relPath)
	if cleanRel != relPath || cleanRel == "." || cleanRel == ".." || strings.HasPrefix(cleanRel, "../") {
		return fmt.Errorf("content path %q is not canonical", relPath)
	}
	return nil
}

func ResolveContentRoute(routes map[string]ContentRoute, requestPath string, options RouteOptions) (ContentRoute, bool) {
	options = normalizeRouteOptions(options)
	if requestPath == "" {
		requestPath = "/"
	}
	if !strings.HasPrefix(requestPath, "/") {
		requestPath = "/" + requestPath
	}

	candidates := []string{requestPath}
	clean := path.Clean(requestPath)
	if clean == "." {
		clean = "/"
	}
	if !strings.HasPrefix(clean, "/") {
		clean = "/" + clean
	}
	if clean != requestPath {
		candidates = append(candidates, clean)
	}
	if requestPath != "/" {
		noSlash := strings.TrimSuffix(requestPath, "/")
		withSlash := noSlash + "/"
		if noSlash == "" {
			noSlash = "/"
			withSlash = "/"
		}
		if options.TrailingSlashMode == TrailingSlashModeNever {
			candidates = append(candidates, noSlash, withSlash)
		} else {
			candidates = append(candidates, withSlash, noSlash)
		}
	}

	seen := make(map[string]struct{}, len(candidates))
	for _, candidate := range candidates {
		if _, ok := seen[candidate]; ok {
			continue
		}
		seen[candidate] = struct{}{}
		if route, ok := routes[candidate]; ok {
			return route, true
		}
	}
	return ContentRoute{}, false
}

func contentRequestPaths(relPath string, options RouteOptions) []string {
	out := make([]string, 0, 4)
	appendUnique := func(value string) {
		if slices.Contains(out, value) {
			return
		}
		out = append(out, value)
	}

	appendUnique("/" + relPath)
	ext := path.Ext(relPath)
	lowerExt := strings.ToLower(ext)
	if lowerExt == ".html" || lowerExt == ".md" || lowerExt == ".markdown" || lowerExt == ".uri" || lowerExt == ".uris" {
		base := path.Base(relPath)
		if strings.EqualFold(base, "index"+ext) {
			dir := path.Dir(relPath)
			if dir == "." {
				appendUnique("/")
			} else {
				if options.TrailingSlashMode == TrailingSlashModeNever {
					appendUnique("/" + dir)
					appendUnique("/" + dir + "/")
				} else {
					appendUnique("/" + dir + "/")
					appendUnique("/" + dir)
				}
			}
		} else {
			appendUnique("/" + strings.TrimSuffix(relPath, ext))
		}
	}
	return out
}

// sourceMIMETypes is explicit so routes don't depend on the host's mime.types
// files. Keep in sync with mimeTypes in npm/qip-router/qip-router.mjs.
var sourceMIMETypes = map[string]string{
	".apng":     "image/apng",
	".avif":     "image/avif",
	".bmp":      "image/bmp",
	".c":        "text/x-c",
	".css":      "text/css",
	".csv":      "text/csv",
	".gif":      "image/gif",
	".gz":       "application/gzip",
	".h":        "text/x-c",
	".htm":      "text/html",
	".html":     "text/html",
	".ico":      "image/x-icon",
	".jp2":      "image/jp2",
	".jpeg":     "image/jpeg",
	".jpg":      "image/jpeg",
	".jxl":      "image/jxl",
	".js":       "text/javascript",
	".json":     "application/json",
	".ktx2":     "image/ktx2",
	".md":       "text/markdown",
	".markdown": "text/markdown",
	".mermaid":  "text/vnd.mermaid",
	".mjs":      "text/javascript",
	".mmd":      "text/vnd.mermaid",
	".mp3":      "audio/mpeg",
	".mp4":      "video/mp4",
	".ogg":      "audio/ogg",
	".otf":      "font/otf",
	".pdf":      "application/pdf",
	".png":      "image/png",
	".sqlite":   "application/vnd.sqlite3",
	".sqlite3":  "application/vnd.sqlite3",
	".svg":      "image/svg+xml",
	".swift":    "text/x-swift",
	".tar":      "application/x-tar",
	".tif":      "image/tiff",
	".tiff":     "image/tiff",
	".ttf":      "font/ttf",
	".txt":      "text/plain",
	".uri":      "text/uri-list",
	".uris":     "text/uri-list",
	".warc":     "application/warc",
	".wasm":     "application/wasm",
	".wav":      "audio/wav",
	".webm":     "video/webm",
	".webp":     "image/webp",
	".woff":     "font/woff",
	".woff2":    "font/woff2",
	".xml":      "application/xml",
	".zig":      "text/x-zig",
	".zip":      "application/zip",
}

func detectSourceMIME(relPath string) string {
	if mimeType, ok := sourceMIMETypes[strings.ToLower(path.Ext(relPath))]; ok {
		return mimeType
	}
	return "application/octet-stream"
}
