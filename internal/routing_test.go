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

	routes, err := BuildContentRoutes(root, DefaultRouteOptions())
	if err != nil {
		t.Fatalf("BuildContentRoutes: %v", err)
	}
	for _, requestPath := range []string{
		"/_recipes/text/markdown/10-markdown.wasm",
		"/_components/gui/game.wasm",
		"/_elements/qip-edit.js",
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
