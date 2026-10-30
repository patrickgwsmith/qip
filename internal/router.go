package qinternal

import (
	"fmt"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

const maxKindredStaticRoutes = 256

type KindredRouteResolver func(requestPath string) (InProcessHTTPResponse, bool, error)

type KindredRoute struct {
	RequestPath string
	Response    InProcessHTTPResponse
}

// KindredRoutes returns the routes available to an application/warc recipe for
// one routed response. Parents provide layout ancestry. Direct site-relative
// src references provide sibling resources when they resolve to eligible
// non-HTML routes. Routes are included once and are not scanned recursively.
func KindredRoutes(
	requestPath string,
	response InProcessHTTPResponse,
	resolveParent KindredRouteResolver,
	resolveStatic KindredRouteResolver,
) ([]KindredRoute, error) {
	routes := make([]KindredRoute, 0)
	seen := make(map[string]struct{})

	for _, parentPath := range kindredParentRoutePaths(requestPath) {
		canonical, _ := CanonicalRequestPath(parentPath, DefaultRouteOptions())
		if canonical == requestPath {
			continue
		}
		if _, ok := seen[canonical]; ok {
			continue
		}
		seen[canonical] = struct{}{}
		if resolveParent == nil {
			continue
		}
		parentResponse, ok, err := resolveParent(canonical)
		if err != nil {
			return nil, err
		}
		if !ok || parentResponse.StatusCode != http.StatusOK || !isHTMLMediaType(parentResponse.Header.Get("Content-Type")) {
			continue
		}
		routes = append(routes, KindredRoute{RequestPath: canonical, Response: parentResponse})
	}

	if response.StatusCode == http.StatusOK && isHTMLMediaType(response.Header.Get("Content-Type")) && resolveStatic != nil {
		staticRouteCount := 0
		for _, sourcePath := range prescanHTMLSourcePaths(response.Body, requestPath) {
			canonical, _ := CanonicalRequestPath(sourcePath, DefaultRouteOptions())
			if canonical == requestPath {
				continue
			}
			if _, ok := seen[canonical]; ok {
				continue
			}
			seen[canonical] = struct{}{}
			staticRouteCount++
			if staticRouteCount > maxKindredStaticRoutes {
				return nil, fmt.Errorf("HTML for %q references more than %d Kindred Routes", requestPath, maxKindredStaticRoutes)
			}
			staticResponse, ok, err := resolveStatic(canonical)
			if err != nil {
				return nil, err
			}
			if !ok || staticResponse.StatusCode != http.StatusOK || isHTMLMediaType(staticResponse.Header.Get("Content-Type")) {
				continue
			}
			routes = append(routes, KindredRoute{RequestPath: canonical, Response: staticResponse})
		}
	}

	routes = append(routes, KindredRoute{RequestPath: requestPath, Response: response})
	return routes, nil
}

func isHTMLMediaType(contentType string) bool {
	mediaType, _, err := mime.ParseMediaType(strings.TrimSpace(contentType))
	if err != nil {
		mediaType = strings.TrimSpace(strings.SplitN(contentType, ";", 2)[0])
	}
	switch strings.ToLower(mediaType) {
	case "text/html", "application/xhtml+xml":
		return true
	default:
		return false
	}
}

func kindredParentRoutePaths(requestPath string) []string {
	canonical, _ := CanonicalRequestPath(requestPath, DefaultRouteOptions())
	if canonical == "" {
		canonical = "/"
	}
	out := []string{"/"}
	if canonical == "/" {
		return out
	}
	trimmed := strings.Trim(canonical, "/")
	if trimmed == "" {
		return out
	}
	parts := strings.Split(trimmed, "/")
	var prefix strings.Builder
	for i := 0; i < len(parts)-1; i++ {
		prefix.WriteString("/" + parts[i])
		out = append(out, prefix.String())
	}
	return out
}

const ReservedRecipesDir = "_recipes"
const ReservedComponentsDir = "_components"
const ReservedElementsDir = "_elements"

// ReservedHostFile names the site's domain, following the GitHub Pages and
// Surge convention. It is build metadata, so it is not served as a route.
const ReservedHostFile = "CNAME"

func IsReservedRouterDirectoryName(name string) bool {
	switch name {
	case ReservedRecipesDir, ReservedComponentsDir, ReservedElementsDir, ReservedHostFile:
		return true
	default:
		return false
	}
}

// ReadRouterHostFile reads the domain from contentRoot's CNAME file and
// returns it as an https:// origin. It returns "" when there is no CNAME file.
func ReadRouterHostFile(contentRoot string) (string, error) {
	filePath := filepath.Join(contentRoot, ReservedHostFile)
	data, err := os.ReadFile(filePath)
	if os.IsNotExist(err) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	domain := strings.TrimSpace(string(data))
	if domain == "" || strings.ContainsAny(domain, " \t\r\n/?#@") || strings.Contains(domain, ":") {
		return "", fmt.Errorf("%s must hold a single bare domain such as example.com, got %q", filePath, domain)
	}
	return "https://" + domain, nil
}

func IsReservedRouterRelPath(relPath string) bool {
	relPath = strings.TrimPrefix(relPath, "/")
	first, _, _ := strings.Cut(relPath, "/")
	return IsReservedRouterDirectoryName(first)
}

type RouterProjectConfig struct {
	ContentRoot string

	RecipesRoot    string
	ComponentsRoot string
	ElementsRoot   string
}

func ResolveRouterProjectConfig(config RouterProjectConfig) (RouterProjectConfig, error) {
	var err error
	if config.RecipesRoot == "" {
		config.RecipesRoot, err = discoverOptionalProjectDir(config.ContentRoot, ReservedRecipesDir, "recipes")
		if err != nil {
			return RouterProjectConfig{}, err
		}
	}
	if config.ComponentsRoot == "" {
		config.ComponentsRoot, err = discoverOptionalProjectDir(config.ContentRoot, ReservedComponentsDir, "components")
		if err != nil {
			return RouterProjectConfig{}, err
		}
	}
	if config.ElementsRoot == "" {
		config.ElementsRoot, err = discoverOptionalProjectDir(config.ContentRoot, ReservedElementsDir, "elements")
		if err != nil {
			return RouterProjectConfig{}, err
		}
	}
	return config, nil
}

func discoverOptionalProjectDir(contentRoot string, dirName string, label string) (string, error) {
	if contentRoot == "" || dirName == "" {
		return "", nil
	}
	candidate := filepath.Join(contentRoot, dirName)
	info, err := os.Stat(candidate)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", fmt.Errorf("Invalid %s directory: %v", label, err)
	}
	if !info.IsDir() {
		return "", fmt.Errorf("Invalid %s directory: %q is not a directory", label, candidate)
	}
	return candidate, nil
}

func IsDevHardRefreshRequest(r *http.Request) bool {
	if r == nil {
		return false
	}
	cacheControl := strings.ToLower(r.Header.Get("Cache-Control"))
	pragma := strings.ToLower(r.Header.Get("Pragma"))
	hasHardReloadCacheHint := strings.Contains(cacheControl, "no-cache") || strings.Contains(cacheControl, "max-age=0") || strings.Contains(pragma, "no-cache")
	if !hasHardReloadCacheHint {
		return false
	}

	dest := strings.ToLower(r.Header.Get("Sec-Fetch-Dest"))
	if dest == "document" {
		return true
	}
	if dest != "" && dest != "empty" {
		return false
	}

	accept := strings.ToLower(r.Header.Get("Accept"))
	return strings.Contains(accept, "text/html")
}

func ValidateOptionalDirectory(label string, dir string) error {
	if dir == "" {
		return nil
	}
	info, err := os.Stat(dir)
	if err != nil {
		return fmt.Errorf("Invalid %s directory: %v", label, err)
	}
	if !info.IsDir() {
		return fmt.Errorf("Invalid %s directory: %q is not a directory", label, dir)
	}
	return nil
}
