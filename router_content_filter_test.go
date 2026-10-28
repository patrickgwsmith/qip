package main

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"testing"

	qinternal "github.com/royalicing/qip/internal"
)

func TestRouterFileStateFiltersContentButKeepsParentContext(t *testing.T) {
	contentRoot := t.TempDir()
	for relPath, body := range map[string]string{
		"index.html":           "<h1>Home</h1>",
		"blog.html":            "<h1>Blog</h1>",
		"blog/post.html":       "<h1>Post</h1>",
		"blog/drafts/wip.html": "<h1>Draft</h1>",
		".env":                 "SECRET=1",
	} {
		fullPath := filepath.Join(contentRoot, relPath)
		if err := os.MkdirAll(filepath.Dir(fullPath), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(fullPath, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	filter, err := qinternal.NewContentPathFilter([]string{"blog/post"}, []string{"blog/drafts"})
	if err != nil {
		t.Fatal(err)
	}
	files, err := loadRouterFileState(context.Background(), RouterFileLayout{ContentRoot: contentRoot, ContentFilter: filter}, qinternal.DefaultRouteOptions())
	if err != nil {
		t.Fatal(err)
	}
	state := &RouterServerState{RouterFileState: files}

	paths := kindredCheckPagePaths(state, state.routeOptions)
	if want := []string{"/blog/post", "/blog/post.html"}; !slices.Equal(paths, want) {
		t.Fatalf("routed paths=%v, want %v", paths, want)
	}
	if got, want := filteredParentPaths(state, paths), []string{"/", "/blog"}; !slices.Equal(got, want) {
		t.Fatalf("filtered parent paths=%v, want %v", got, want)
	}
	response, ok, err := resolveRouterBaseResponse(context.Background(), state, "/blog", 0, RouterServerTimeouts{})
	if err != nil || !ok || string(response.Body) != "<h1>Blog</h1>" {
		t.Fatalf("expected /blog to resolve as parent context, got ok=%v err=%v body=%q", ok, err, response.Body)
	}
	if _, ok := qinternal.ResolveContentRoute(state.contentRoutes, "/blog/drafts/wip", state.routeOptions); ok {
		t.Fatal("expected excluded draft not to be routed")
	}
}
