package qinternal

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestBuildViewSourceIndexHTMLIncludesComponents(t *testing.T) {
	html := string(BuildViewSourceIndexHTML(
		[]RecipeSourceAsset{
			{RequestPath: "/view-source/recipes/text/markdown/10-markdown-basic.zig"},
		},
		[]string{"/guide.md"},
		[]string{
			"/text/trim.wasm",
			"/text/trim.wasm",
			"/text/ignored.txt",
		},
		[]RecipeSourceAsset{
			{RequestPath: "/view-source/components/text/trim.zig"},
			{RequestPath: "/view-source/components/text/styles.css"},
			{RequestPath: "/view-source/components/text/trim.wasm"},
			{RequestPath: "/view-source/recipes/ignored.zig"},
		},
	))

	if !strings.Contains(html, "<h2>Components</h2>") {
		t.Fatalf("missing components heading: %q", html)
	}
	contentPos := strings.Index(html, "<h2>Content</h2>")
	recipesPos := strings.Index(html, "<h2>Recipes</h2>")
	if contentPos < 0 || recipesPos < 0 || contentPos > recipesPos {
		t.Fatalf("expected Content section before Recipes section: %q", html)
	}
	if got := strings.Count(html, "<h2>Components</h2>"); got != 1 {
		t.Fatalf("components heading count=%d, want 1", got)
	}
	if !strings.Contains(html, "href=\"/text/trim.wasm\"") {
		t.Fatalf("missing component href: %q", html)
	}
	if strings.Contains(html, "href=\"/text/ignored.txt\"") {
		t.Fatalf("unexpected non-component href: %q", html)
	}
	if got := strings.Count(html, "href=\"/text/trim.wasm\""); got != 1 {
		t.Fatalf("component href count=%d, want 1", got)
	}
	if strings.Contains(html, "<h2>Component Sources</h2>") {
		t.Fatalf("unexpected component sources heading: %q", html)
	}
	if !strings.Contains(html, "href=\"/view-source/components/text/trim.zig\"") {
		t.Fatalf("missing component source href: %q", html)
	}
	if !strings.Contains(html, "href=\"/view-source/components/text/styles.css\"") {
		t.Fatalf("missing component source css href: %q", html)
	}
	if strings.Contains(html, "href=\"/view-source/components/text/trim.wasm\"") {
		t.Fatalf("expected runtime wasm href to be preferred over view-source wasm href: %q", html)
	}
	if strings.Contains(html, "href=\"/view-source/recipes/ignored.zig\"") {
		t.Fatalf("unexpected non-component source href: %q", html)
	}
}

func TestCollectViewSourceAssetsFollowsSymlinks(t *testing.T) {
	repo := t.TempDir()
	writeFile := func(rel string, body string) {
		t.Helper()
		full := filepath.Join(repo, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatalf("write %s: %v", rel, err)
		}
	}
	symlink := func(target string, rel string) {
		t.Helper()
		full := filepath.Join(repo, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		if err := os.Symlink(target, full); err != nil {
			t.Fatalf("symlink %s: %v", rel, err)
		}
	}

	// Mirrors the site: site/_recipes -> ../recipes, site/_components/gui -> ../../gui.
	writeFile("recipes/text/markdown/10-markdown-basic.zig", "const std = @import(\"std\");")
	writeFile("gui/flurry.zig", "const std = @import(\"std\");")
	writeFile("gui/flurry.wasm", "\x00asm")
	writeFile("gui/notes.md", "# Notes")
	writeFile("gui/.DS_Store", "noise")
	writeFile("gui/.zig-cache/o/x.o", "noise")
	writeFile("gui/rust-thing/Cargo.toml", "[package]")
	writeFile("gui/rust-thing/src/lib.rs", "fn main() {}")
	writeFile("gui/rust-thing/target/debug/out.rlib", "noise")
	writeFile("gui/huge-metrics.zig", strings.Repeat("x", maxViewSourceFileSize+1))
	writeFile("gui/at-limit.zig", strings.Repeat("x", maxViewSourceFileSize))
	symlink("../recipes", "site/_recipes")
	symlink("../../gui", "site/_components/gui")

	recipeAssets, err := CollectRecipeSourceAssets(filepath.Join(repo, "site", "_recipes"))
	if err != nil {
		t.Fatalf("CollectRecipeSourceAssets: %v", err)
	}
	componentAssets, err := CollectComponentSourceAssets(filepath.Join(repo, "site", "_components"))
	if err != nil {
		t.Fatalf("CollectComponentSourceAssets: %v", err)
	}

	requestPaths := func(assets []RecipeSourceAsset) []string {
		out := make([]string, 0, len(assets))
		for _, asset := range assets {
			out = append(out, asset.RequestPath)
		}
		return out
	}
	if got, want := requestPaths(recipeAssets), []string{
		"/view-source/recipes/text/markdown/10-markdown-basic.zig",
	}; !reflect.DeepEqual(got, want) {
		t.Fatalf("recipe paths=%v, want %v", got, want)
	}
	if got, want := requestPaths(componentAssets), []string{
		"/view-source/components/gui/at-limit.zig",
		"/view-source/components/gui/flurry.zig",
		"/view-source/components/gui/notes.md",
		"/view-source/components/gui/rust-thing/Cargo.toml",
		"/view-source/components/gui/rust-thing/src/lib.rs",
	}; !reflect.DeepEqual(got, want) {
		t.Fatalf("component paths=%v, want %v", got, want)
	}
}
