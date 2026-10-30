package qinternal

import (
	"fmt"
	"html"
	"io/fs"
	"mime"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"
)

type RecipeSourceAsset struct {
	RequestPath string
	Body        []byte
	ContentType string
}

func CollectRecipeSourceAssets(recipesRoot string) ([]RecipeSourceAsset, error) {
	return collectViewSourceAssets(recipesRoot, "/view-source/recipes/")
}

func CollectComponentSourceAssets(componentsRoot string) ([]RecipeSourceAsset, error) {
	assets, err := collectViewSourceAssets(componentsRoot, "/view-source/components/")
	if err != nil {
		return nil, err
	}
	// Component .wasm is already served at its own path, which the index links instead.
	out := assets[:0]
	for _, asset := range assets {
		if strings.ToLower(path.Ext(asset.RequestPath)) != ".wasm" {
			out = append(out, asset)
		}
	}
	return out, nil
}

// maxViewSourceFileSize skips large generated data files (font metrics, compat
// tables) that would bloat the site archive and that nobody reads as source.
const maxViewSourceFileSize = 1 << 20

func collectViewSourceAssets(root string, requestPrefix string) ([]RecipeSourceAsset, error) {
	assets := make([]RecipeSourceAsset, 0, 32)
	if root == "" {
		return assets, nil
	}
	// Follow symlinks: site/_recipes and the folders in site/_components are symlinks.
	err := WalkFilesFollowingSymlinks(root, "source", func(fullPath string, info fs.FileInfo) error {
		if info.Size() > maxViewSourceFileSize {
			return nil
		}
		relPath, err := filepath.Rel(root, fullPath)
		if err != nil {
			return err
		}
		relPath = filepath.ToSlash(relPath)
		if hasHiddenPathSegment(relPath) || isInsideCargoTarget(root, relPath) {
			return nil
		}
		body, err := os.ReadFile(fullPath)
		if err != nil {
			return err
		}
		assets = append(assets, RecipeSourceAsset{
			RequestPath: requestPrefix + relPath,
			Body:        body,
			ContentType: detectViewSourceContentType(relPath, body),
		})
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("failed to enumerate source files: %w", err)
	}
	sort.Slice(assets, func(i, j int) bool {
		return assets[i].RequestPath < assets[j].RequestPath
	})
	return assets, nil
}

func BuildViewSourceIndexHTML(recipeAssets []RecipeSourceAsset, markdownRequestPaths []string, componentRequestPaths []string, componentSourceAssets []RecipeSourceAsset) []byte {
	markdownRequestPaths = FilterMarkdownRequestPaths(markdownRequestPaths)
	componentRequestPaths = filterComponentRequestPaths(componentRequestPaths)
	componentSourceAssets = filterViewSourceAssetsByPrefix(componentSourceAssets, "/view-source/components/")
	componentEntries := buildComponentViewSourceEntries(componentRequestPaths, componentSourceAssets)

	var b strings.Builder
	b.Grow(1280 + len(recipeAssets)*96 + len(markdownRequestPaths)*64 + len(componentEntries)*96)
	b.WriteString("<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>/view-source</title><style>")
	b.WriteString(":root{font-family:system-ui,sans-serif}body{margin:0;padding:1.5rem 1rem;display:flex;justify-content:center}main{width:100%;max-width:44rem;line-height:1.5}h1{margin:0 0 1rem}h2{margin:1.5rem 0 .5rem}ul{padding-left:1.25rem}")
	b.WriteString("</style></head><body><main><h1>View Source</h1>")
	b.WriteString("<h2>Content</h2><ul>")
	for _, requestPath := range markdownRequestPaths {
		href := requestPathForHref(requestPath)
		label := requestPath
		b.WriteString("<li><a href=\"")
		b.WriteString(html.EscapeString(href))
		b.WriteString("\">")
		b.WriteString(html.EscapeString(label))
		b.WriteString("</a></li>")
	}
	b.WriteString("</ul>")
	b.WriteString("<h2>Recipes</h2><ul>")
	for _, asset := range recipeAssets {
		href := requestPathForHref(asset.RequestPath)
		label := strings.TrimPrefix(asset.RequestPath, "/view-source/recipes/")
		b.WriteString("<li><a href=\"")
		b.WriteString(html.EscapeString(href))
		b.WriteString("\">")
		b.WriteString(html.EscapeString(label))
		b.WriteString("</a></li>")
	}
	b.WriteString("</ul>")
	b.WriteString("<h2>Components</h2><ul>")
	for _, entry := range componentEntries {
		b.WriteString("<li><a href=\"")
		b.WriteString(html.EscapeString(entry.href))
		b.WriteString("\">")
		b.WriteString(html.EscapeString(entry.label))
		b.WriteString("</a></li>")
	}
	b.WriteString("</ul></main></body></html>\n")
	return []byte(b.String())
}

type componentViewSourceEntry struct {
	label string
	href  string
}

func buildComponentViewSourceEntries(componentRequestPaths []string, componentSourceAssets []RecipeSourceAsset) []componentViewSourceEntry {
	entriesByLabel := make(map[string]componentViewSourceEntry, len(componentRequestPaths)+len(componentSourceAssets))
	for _, asset := range componentSourceAssets {
		label := strings.TrimPrefix(asset.RequestPath, "/view-source/components/")
		entriesByLabel[label] = componentViewSourceEntry{
			label: label,
			href:  requestPathForHref(asset.RequestPath),
		}
	}
	// Prefer direct component endpoints for matching labels.
	for _, requestPath := range componentRequestPaths {
		label := strings.TrimPrefix(requestPath, "/")
		entriesByLabel[label] = componentViewSourceEntry{
			label: label,
			href:  requestPathForHref(requestPath),
		}
	}

	labels := make([]string, 0, len(entriesByLabel))
	for label := range entriesByLabel {
		labels = append(labels, label)
	}
	sort.Strings(labels)

	entries := make([]componentViewSourceEntry, 0, len(labels))
	for _, label := range labels {
		entries = append(entries, entriesByLabel[label])
	}
	return entries
}

func CollectMarkdownRequestPathsFromRoutes(routes map[string]ContentRoute) []string {
	paths := make([]string, 0, len(routes))
	for requestPath, route := range routes {
		if route.SourceMIME != "text/markdown" {
			continue
		}
		if !isMarkdownRequestPath(requestPath) {
			continue
		}
		paths = append(paths, requestPath)
	}
	return FilterMarkdownRequestPaths(paths)
}

func FilterMarkdownRequestPaths(paths []string) []string {
	out := make([]string, 0, len(paths))
	seen := make(map[string]struct{}, len(paths))
	for _, requestPath := range paths {
		if !isMarkdownRequestPath(requestPath) {
			continue
		}
		normalized := requestPath
		if !strings.HasPrefix(normalized, "/") {
			normalized = "/" + normalized
		}
		if _, ok := seen[normalized]; ok {
			continue
		}
		seen[normalized] = struct{}{}
		out = append(out, normalized)
	}
	sort.Strings(out)
	return out
}

func filterComponentRequestPaths(paths []string) []string {
	out := make([]string, 0, len(paths))
	seen := make(map[string]struct{}, len(paths))
	for _, requestPath := range paths {
		if !strings.HasPrefix(requestPath, "/") || !strings.HasSuffix(requestPath, ".wasm") {
			continue
		}
		normalized := path.Clean(requestPath)
		if normalized == "." || normalized == ".." || strings.HasPrefix(normalized, "../") {
			continue
		}
		if !strings.HasPrefix(normalized, "/") {
			normalized = "/" + normalized
		}
		if _, ok := seen[normalized]; ok {
			continue
		}
		seen[normalized] = struct{}{}
		out = append(out, normalized)
	}
	sort.Strings(out)
	return out
}

func filterViewSourceAssetsByPrefix(assets []RecipeSourceAsset, prefix string) []RecipeSourceAsset {
	out := make([]RecipeSourceAsset, 0, len(assets))
	seen := make(map[string]struct{}, len(assets))
	for _, asset := range assets {
		if !strings.HasPrefix(asset.RequestPath, prefix) {
			continue
		}
		if _, ok := seen[asset.RequestPath]; ok {
			continue
		}
		seen[asset.RequestPath] = struct{}{}
		out = append(out, asset)
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].RequestPath < out[j].RequestPath
	})
	return out
}

func detectViewSourceContentType(relPath string, body []byte) string {
	ext := strings.ToLower(filepath.Ext(relPath))
	// TODO: this should be in a single, central location
	switch ext {
	case ".wasm":
		return "application/wasm"
	case ".zig":
		return "text/plain; charset=utf-8"
	case ".c", ".h":
		return "text/x-c; charset=utf-8"
	case ".css":
		return "text/css; charset=utf-8"
	case ".js", ".mjs":
		return "text/javascript; charset=utf-8"
	case ".json":
		return "application/json"
	case ".md", ".markdown":
		return "text/markdown; charset=utf-8"
	case ".html", ".htm":
		return "text/html; charset=utf-8"
	}

	if byExt := mime.TypeByExtension(ext); byExt != "" {
		return byExt
	}
	if utf8.Valid(body) {
		return "text/plain; charset=utf-8"
	}
	return "application/octet-stream"
}

func hasHiddenPathSegment(relPath string) bool {
	for part := range strings.SplitSeq(relPath, "/") {
		if strings.HasPrefix(part, ".") {
			return true
		}
	}
	return false
}

// isInsideCargoTarget reports whether relPath is under a Rust build output
// folder, a target/ next to a Cargo.toml. It is gitignored, not source.
func isInsideCargoTarget(root string, relPath string) bool {
	parts := strings.Split(relPath, "/")
	for i := 0; i < len(parts)-1; i++ {
		if parts[i] != "target" {
			continue
		}
		cargoPath := filepath.Join(root, filepath.FromSlash(strings.Join(parts[:i], "/")), "Cargo.toml")
		if info, err := os.Stat(cargoPath); err == nil && info.Mode().IsRegular() {
			return true
		}
	}
	return false
}

func isMarkdownRequestPath(requestPath string) bool {
	ext := strings.ToLower(filepath.Ext(requestPath))
	return ext == ".md" || ext == ".markdown"
}

func requestPathForHref(requestPath string) string {
	if requestPath == "" {
		return "/"
	}
	if !strings.HasPrefix(requestPath, "/") {
		requestPath = "/" + requestPath
	}
	parts := strings.Split(strings.TrimPrefix(requestPath, "/"), "/")
	escaped := make([]string, 0, len(parts))
	for _, part := range parts {
		escaped = append(escaped, url.PathEscape(part))
	}
	return "/" + strings.Join(escaped, "/")
}
