package qinternal

import (
	"net/http"
	"os"
	"path/filepath"
	"testing"
)

func TestNewRequestHandlerRedirectsTrailingSlashNever(t *testing.T) {
	resolveCalled := false
	handler := NewRequestHandler(RequestHandlerConfig{
		LogPrefix:    "test",
		RouteOptions: RouteOptions{TrailingSlashMode: TrailingSlashModeNever},
		Resolve: func(r *http.Request, requestID uint64) (RoutedResponse, error) {
			resolveCalled = true
			return RoutedResponse{StatusCode: http.StatusOK}, nil
		},
	})

	resp, err := ServeInProcessHTTP(handler, http.MethodGet, "/foo/", nil)
	if err != nil {
		t.Fatalf("ServeInProcessHTTP: %v", err)
	}
	if resp.StatusCode != http.StatusPermanentRedirect {
		t.Fatalf("status=%d, want %d", resp.StatusCode, http.StatusPermanentRedirect)
	}
	if got := resp.Header.Get("Location"); got != "/foo" {
		t.Fatalf("Location=%q, want %q", got, "/foo")
	}
	if resolveCalled {
		t.Fatal("Resolve should not be called for canonical redirect")
	}
}

func TestBuildContentRoutesSkipsReservedRouterDirectories(t *testing.T) {
	root := t.TempDir()
	mustWrite := func(rel string) {
		full := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		if err := os.WriteFile(full, []byte("x"), 0o644); err != nil {
			t.Fatalf("write: %v", err)
		}
	}
	mustWrite("index.md")
	mustWrite("_recipes/text/markdown/10-markdown.wasm")
	mustWrite("_forms/contact.wasm")
	mustWrite("_components/gui/game.wasm")
	mustWrite("_elements/qip-edit.js")
	mustWrite("_og/card.png")
	mustWrite("CNAME")
	mustWrite("docs/CNAME")

	routes, err := BuildContentRoutes(root, DefaultRouteOptions())
	if err != nil {
		t.Fatalf("BuildContentRoutes: %v", err)
	}
	for _, requestPath := range []string{
		"/_recipes/text/markdown/10-markdown.wasm",
		"/_components/gui/game.wasm",
		"/_elements/qip-edit.js",
		"/CNAME",
	} {
		if _, ok := routes[requestPath]; ok {
			t.Fatalf("reserved path %s was routed", requestPath)
		}
	}
	if _, ok := routes["/_og/card.png"]; !ok {
		t.Fatalf("non-reserved underscore path was not routed")
	}
	if _, ok := routes["/_forms/contact.wasm"]; !ok {
		t.Fatalf("ordinary _forms path was not routed")
	}
	if _, ok := routes["/docs/CNAME"]; !ok {
		t.Fatalf("nested CNAME was not routed")
	}
}

func TestReadRouterHostFile(t *testing.T) {
	root := t.TempDir()
	host, err := ReadRouterHostFile(root)
	if err != nil || host != "" {
		t.Fatalf("missing CNAME: host=%q err=%v", host, err)
	}
	write := func(body string) {
		if err := os.WriteFile(filepath.Join(root, ReservedHostFile), []byte(body), 0o644); err != nil {
			t.Fatalf("write: %v", err)
		}
	}
	write("example.com\n")
	host, err = ReadRouterHostFile(root)
	if err != nil || host != "https://example.com" {
		t.Fatalf("host=%q err=%v, want https://example.com", host, err)
	}
	for _, body := range []string{"", "https://example.com", "example.com/docs", "example.com:8080", "a.com\nb.com"} {
		write(body)
		if _, err := ReadRouterHostFile(root); err == nil {
			t.Fatalf("CNAME %q was accepted", body)
		}
	}
}

func TestResolveRouterProjectConfigDiscoversAndAllowsOverrides(t *testing.T) {
	root := t.TempDir()
	for _, rel := range []string{ReservedRecipesDir, ReservedComponentsDir, ReservedElementsDir} {
		if err := os.Mkdir(filepath.Join(root, rel), 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", rel, err)
		}
	}

	config, err := ResolveRouterProjectConfig(RouterProjectConfig{ContentRoot: root})
	if err != nil {
		t.Fatalf("ResolveRouterProjectConfig: %v", err)
	}
	if config.RecipesRoot != filepath.Join(root, ReservedRecipesDir) {
		t.Fatalf("recipes root=%q", config.RecipesRoot)
	}
	if config.ComponentsRoot != filepath.Join(root, ReservedComponentsDir) {
		t.Fatalf("components root=%q", config.ComponentsRoot)
	}
	if config.ElementsRoot != filepath.Join(root, ReservedElementsDir) {
		t.Fatalf("elements root=%q", config.ElementsRoot)
	}

	override, err := ResolveRouterProjectConfig(RouterProjectConfig{
		ContentRoot: root,
		RecipesRoot: "custom-recipes",
	})
	if err != nil {
		t.Fatalf("ResolveRouterProjectConfig override: %v", err)
	}
	if override.RecipesRoot != "custom-recipes" {
		t.Fatalf("recipes override=%q", override.RecipesRoot)
	}
}
