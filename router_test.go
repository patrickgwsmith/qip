package main

import (
	"context"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	qinternal "github.com/royalicing/qip/internal"
)

func TestBuildRouteListEntries(t *testing.T) {
	state := &RouterServerState{
		RouterFileState: &RouterFileState{
			contentRoutes: map[string]qinternal.ContentRoute{
				"/about":        {FilePath: "docs/about.md", SourceMIME: "text/markdown"},
				"/about/":       {FilePath: "docs/about.md", SourceMIME: "text/markdown"},
				"/images/logo":  {FilePath: "docs/images/logo.png", SourceMIME: "image/png"},
				"/images/logo/": {FilePath: "docs/images/logo.png", SourceMIME: "image/png"},
			},
			routeOptions: qinternal.DefaultRouteOptions(),
		},
		recipeChains: map[string]*qinternal.Pipeline{
			"text/markdown": &qinternal.Pipeline{},
		},
	}

	got := buildRouteListEntries(state)
	want := []routeListEntry{
		{Method: "GET", Path: "/about", ContentType: "text/html"},
		{Method: "HEAD", Path: "/about", ContentType: "text/html"},
		{Method: "GET", Path: "/images/logo", ContentType: "image/png"},
		{Method: "HEAD", Path: "/images/logo", ContentType: "image/png"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("entries=%v, want %v", got, want)
	}
}

func TestBuildRouteListEntriesIncludesURIListRedirect(t *testing.T) {
	state := &RouterServerState{
		RouterFileState: &RouterFileState{
			contentRoutes: map[string]qinternal.ContentRoute{
				"/how-it-works":     {FilePath: "site/how-it-works.uri", SourceMIME: "text/uri-list"},
				"/how-it-works.uri": {FilePath: "site/how-it-works.uri", SourceMIME: "text/uri-list"},
			},
			routeOptions: qinternal.DefaultRouteOptions(),
		},
	}

	got := buildRouteListEntries(state)
	want := []routeListEntry{
		{Method: "GET", Path: "/how-it-works", ContentType: "text/uri-list"},
		{Method: "HEAD", Path: "/how-it-works", ContentType: "text/uri-list"},
		{Method: "GET", Path: "/how-it-works.uri", ContentType: "text/uri-list"},
		{Method: "HEAD", Path: "/how-it-works.uri", ContentType: "text/uri-list"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("entries=%v, want %v", got, want)
	}
}

func TestDevHandlerServesURIListRedirect(t *testing.T) {
	contentRoot := t.TempDir()
	redirectPath := filepath.Join(contentRoot, "how-it-works.uri")
	if err := os.WriteFile(redirectPath, []byte("# move\n/docs/how-it-works\n"), 0o644); err != nil {
		t.Fatalf("write redirect file: %v", err)
	}
	redirectWASM, err := os.ReadFile("application/warc/warc-text-uri-list-to-redirect.wasm")
	if err != nil {
		t.Fatalf("read redirect recipe: %v", err)
	}

	state, err := buildRouterServerState(context.Background(), &RouterFileState{
		contentRoutes: map[string]qinternal.ContentRoute{
			"/how-it-works":     {FilePath: redirectPath, SourceMIME: "text/uri-list"},
			"/how-it-works.uri": {FilePath: redirectPath, SourceMIME: "text/uri-list"},
		},
		routeOptions:  qinternal.DefaultRouteOptions(),
		recipeDigests: map[string][][32]byte{},
		recipeFiles: recipeFileSet{
			applicationWARCRecipeMIME: {{
				path:     "recipes/application/warc/05-text-uri-list-to-redirect.wasm",
				filename: "05-text-uri-list-to-redirect.wasm",
				order:    5,
				body:     redirectWASM,
			}},
		},
	}, newQIPRuntime(options{}))
	if err != nil {
		t.Fatalf("buildRouterServerState: %v", err)
	}
	defer state.close(context.Background())
	stateSlot := newRouterServerStateSlot(state)
	handler := newRouterRequestHandler("test", stateSlot, nil, nil, qinternal.DefaultRouteOptions(), RouterServerTimeouts{})

	resp, err := qinternal.ServeInProcessHTTP(handler, http.MethodGet, "/how-it-works", nil)
	if err != nil {
		t.Fatalf("ServeInProcessHTTP: %v", err)
	}
	if resp.StatusCode != http.StatusFound {
		t.Fatalf("status=%d, want %d", resp.StatusCode, http.StatusFound)
	}
	if got := resp.Header.Get("Location"); got != "/docs/how-it-works" {
		t.Fatalf("Location=%q, want %q", got, "/docs/how-it-works")
	}
	if got := resp.Header.Get("ETag"); got != "" {
		t.Fatalf("ETag=%q, want empty", got)
	}
}

func TestDevHandlerServesURIListAsContentWithoutRedirectRecipe(t *testing.T) {
	state := &RouterServerState{
		RouterFileState: &RouterFileState{
			contentRoutes: map[string]qinternal.ContentRoute{
				"/old": {FilePath: "old.uri", SourceMIME: "text/uri-list"},
			},
			contentRead: func(context.Context, qinternal.ContentRoute) ([]byte, error) {
				return []byte("/new\n"), nil
			},
			routeOptions:  qinternal.DefaultRouteOptions(),
			recipeDigests: map[string][][32]byte{},
		},
		recipeChains: map[string]*qinternal.Pipeline{},
	}
	stateSlot := newRouterServerStateSlot(state)
	handler := newRouterRequestHandler("test", stateSlot, nil, nil, qinternal.DefaultRouteOptions(), RouterServerTimeouts{})

	resp, err := qinternal.ServeInProcessHTTP(handler, http.MethodGet, "/old", nil)
	if err != nil {
		t.Fatalf("ServeInProcessHTTP: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d, want %d", resp.StatusCode, http.StatusOK)
	}
	if got := resp.Header.Get("Content-Type"); got != "text/uri-list; charset=utf-8" {
		t.Fatalf("Content-Type=%q", got)
	}
	if got := string(resp.Body); got != "/new\n" {
		t.Fatalf("body=%q", got)
	}
	if got := resp.Header.Get("ETag"); got == "" {
		t.Fatal("ETag is empty for non-HTML content")
	}
}

func TestDevHandlerDoesNotAddETagToHTML(t *testing.T) {
	state := &RouterServerState{
		RouterFileState: &RouterFileState{
			contentRoutes: map[string]qinternal.ContentRoute{
				"/page.html": {FilePath: "page.html", SourceMIME: "text/html"},
			},
			contentRead: func(context.Context, qinternal.ContentRoute) ([]byte, error) {
				return []byte("<h1>Page</h1>"), nil
			},
			routeOptions:  qinternal.DefaultRouteOptions(),
			recipeDigests: map[string][][32]byte{},
		},
		recipeChains: map[string]*qinternal.Pipeline{},
	}
	stateSlot := newRouterServerStateSlot(state)
	handler := newRouterRequestHandler("test", stateSlot, nil, nil, qinternal.DefaultRouteOptions(), RouterServerTimeouts{})

	resp, err := qinternal.ServeInProcessHTTP(handler, http.MethodGet, "/page.html", nil)
	if err != nil {
		t.Fatalf("ServeInProcessHTTP: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d, want %d", resp.StatusCode, http.StatusOK)
	}
	if got := resp.Header.Get("ETag"); got != "" {
		t.Fatalf("ETag=%q, want empty", got)
	}
}

func TestBuildRouteListEntriesMarkdownExtensionServesRaw(t *testing.T) {
	state := &RouterServerState{
		RouterFileState: &RouterFileState{
			contentRoutes: map[string]qinternal.ContentRoute{
				"/guide":    {FilePath: "docs/guide.md", SourceMIME: "text/markdown"},
				"/guide.md": {FilePath: "docs/guide.md", SourceMIME: "text/markdown"},
			},
			routeOptions: qinternal.DefaultRouteOptions(),
		},
		recipeChains: map[string]*qinternal.Pipeline{
			"text/markdown": &qinternal.Pipeline{},
		},
	}

	got := buildRouteListEntries(state)
	want := []routeListEntry{
		{Method: "GET", Path: "/guide", ContentType: "text/html"},
		{Method: "HEAD", Path: "/guide", ContentType: "text/html"},
		{Method: "GET", Path: "/guide.md", ContentType: "text/markdown"},
		{Method: "HEAD", Path: "/guide.md", ContentType: "text/markdown"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("entries=%v, want %v", got, want)
	}
}

func TestBuildRouteListEntriesUsesRecipeOutputContentType(t *testing.T) {
	state := &RouterServerState{
		RouterFileState: &RouterFileState{
			contentRoutes: map[string]qinternal.ContentRoute{
				"/guide":    {FilePath: "docs/guide.md", SourceMIME: "text/markdown"},
				"/guide.md": {FilePath: "docs/guide.md", SourceMIME: "text/markdown"},
			},
			routeOptions: qinternal.DefaultRouteOptions(),
		},
		recipeChains: map[string]*qinternal.Pipeline{
			"text/markdown": &qinternal.Pipeline{},
		},
		recipeOutput: map[string]string{
			"text/markdown": "application/xhtml+xml",
		},
	}

	got := buildRouteListEntries(state)
	want := []routeListEntry{
		{Method: "GET", Path: "/guide", ContentType: "application/xhtml+xml"},
		{Method: "HEAD", Path: "/guide", ContentType: "application/xhtml+xml"},
		{Method: "GET", Path: "/guide.md", ContentType: "text/markdown"},
		{Method: "HEAD", Path: "/guide.md", ContentType: "text/markdown"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("entries=%v, want %v", got, want)
	}
}

func TestBuildRouteListEntriesIncludesComponentAssets(t *testing.T) {
	state := &RouterServerState{
		RouterFileState: &RouterFileState{
			contentRoutes: map[string]qinternal.ContentRoute{
				"/guide": {FilePath: "docs/guide.md", SourceMIME: "text/markdown"},
			},
			routeOptions: qinternal.DefaultRouteOptions(),
			componentAssets: map[string]componentAsset{
				"/bytes/base64-encode.wasm": {contentType: "application/wasm"},
			},
			componentRequestPaths: []string{"/bytes/base64-encode.wasm"},
		},
	}

	got := buildRouteListEntries(state)
	want := []routeListEntry{
		{Method: "GET", Path: "/bytes/base64-encode.wasm", ContentType: "application/wasm"},
		{Method: "HEAD", Path: "/bytes/base64-encode.wasm", ContentType: "application/wasm"},
		{Method: "GET", Path: "/guide", ContentType: "text/markdown"},
		{Method: "HEAD", Path: "/guide", ContentType: "text/markdown"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("entries=%v, want %v", got, want)
	}
}

func TestBuildRouteListEntriesIncludesElementAssets(t *testing.T) {
	state := &RouterServerState{RouterFileState: &RouterFileState{
		contentRoutes:       map[string]qinternal.ContentRoute{},
		routeOptions:        qinternal.DefaultRouteOptions(),
		elementRequestPaths: []string{"/elements/copy-code.js"},
	}}

	want := []routeListEntry{
		{Method: "GET", Path: "/elements/copy-code.js", ContentType: "text/javascript"},
		{Method: "HEAD", Path: "/elements/copy-code.js", ContentType: "text/javascript"},
	}
	if got := buildRouteListEntries(state); !reflect.DeepEqual(got, want) {
		t.Fatalf("entries=%v, want %v", got, want)
	}
}

func TestResolveRecipeSourceResponse(t *testing.T) {
	state := &RouterServerState{
		RouterFileState: &RouterFileState{
			recipeSourceAssets: []qinternal.RecipeSourceAsset{
				{
					RequestPath: "/view-source/recipes/text/markdown/10-markdown-basic.zig",
					Body:        []byte("const x = 1;"),
					ContentType: "text/plain; charset=utf-8",
				},
			},
			recipeSourceByPath: map[string]qinternal.RecipeSourceAsset{
				"/view-source/recipes/text/markdown/10-markdown-basic.zig": {
					RequestPath: "/view-source/recipes/text/markdown/10-markdown-basic.zig",
					Body:        []byte("const x = 1;"),
					ContentType: "text/plain; charset=utf-8",
				},
				"/view-source/text/trim.zig": {
					RequestPath: "/view-source/text/trim.zig",
					Body:        []byte("const std = @import(\"std\");"),
					ContentType: "text/plain; charset=utf-8",
				},
			},
			recipeSourceIndex: []byte("<!doctype html><h1>/view-source</h1><h2>Recipes</h2><h2>Content</h2>"),
		},
	}

	indexResp, ok := resolveRecipeSourceResponse("/view-source", state)
	if !ok {
		t.Fatal("expected index response")
	}
	if indexResp.StatusCode != http.StatusOK {
		t.Fatalf("index status=%d, want %d", indexResp.StatusCode, http.StatusOK)
	}
	if got := indexResp.Header.Get("Content-Type"); got != "text/html; charset=utf-8" {
		t.Fatalf("index content-type=%q, want %q", got, "text/html; charset=utf-8")
	}
	if _, ok := resolveRecipeSourceResponse("/view-source/recipes", state); ok {
		t.Fatalf("did not expect /view-source/recipes to resolve as an index page")
	}

	assetResp, ok := resolveRecipeSourceResponse("/view-source/recipes/text/markdown/10-markdown-basic.zig", state)
	if !ok {
		t.Fatal("expected asset response")
	}
	if got := assetResp.Header.Get("Content-Type"); got != "text/plain; charset=utf-8" {
		t.Fatalf("asset content-type=%q, want %q", got, "text/plain; charset=utf-8")
	}
	if string(assetResp.Body) != "const x = 1;" {
		t.Fatalf("asset body=%q", string(assetResp.Body))
	}

	if _, ok := resolveRecipeSourceResponse("/view-source/recipes/missing.zig", state); ok {
		t.Fatal("expected missing asset to not resolve")
	}

	componentAssetResp, ok := resolveRecipeSourceResponse("/view-source/text/trim.zig", state)
	if !ok {
		t.Fatal("expected component source asset response")
	}
	if got := componentAssetResp.Header.Get("Content-Type"); got != "text/plain; charset=utf-8" {
		t.Fatalf("component asset content-type=%q, want %q", got, "text/plain; charset=utf-8")
	}
	if string(componentAssetResp.Body) != "const std = @import(\"std\");" {
		t.Fatalf("component asset body=%q", string(componentAssetResp.Body))
	}
}
