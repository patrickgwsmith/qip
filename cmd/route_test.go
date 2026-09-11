package cmd

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	qinternal "github.com/royalicing/qip/internal"
)

func TestNormalizeRouteWarcArgs(t *testing.T) {
	in := []string{"docs/", "--recipes", "recipes/", "--components", "components/", "--host", "example.com", "-o", "out.warc"}
	got := normalizeRouteWarcArgs(in)
	want := []string{"--recipes", "recipes/", "--components", "components/", "--host", "example.com", "-o", "out.warc", "docs/"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("args=%v, want %v", got, want)
	}

	inWithDashDash := []string{"docs/", "--", "--host"}
	gotWithDashDash := normalizeRouteWarcArgs(inWithDashDash)
	wantWithDashDash := []string{"--", "docs/", "--host"}
	if !reflect.DeepEqual(gotWithDashDash, wantWithDashDash) {
		t.Fatalf("args=%v, want %v", gotWithDashDash, wantWithDashDash)
	}
}

func TestRunRouteWARCPassesComponentsRoot(t *testing.T) {
	var gotComponentsRoot string
	err := RunRoute([]string{"warc", "--components", "components", "docs"}, RouteConfig{
		UsageRoute:     "usage route",
		UsageRouteWarc: "usage route warc",
		DefaultMode:    "dev",
		ListWARCPaths: func(ctx context.Context, request RouteWARCRequest) ([]string, error) {
			gotComponentsRoot = request.ComponentsRoot
			return []string{"/a"}, nil
		},
		ResolveWARC: func(ctx context.Context, request RouteWARCRequest) (qinternal.InProcessHTTPResponse, error) {
			return qinternal.InProcessHTTPResponse{
				StatusCode: http.StatusOK,
				Header:     http.Header{"Content-Type": []string{"text/plain"}},
				Body:       []byte("ok"),
			}, nil
		},
	})
	if err != nil {
		t.Fatalf("RunRoute: %v", err)
	}
	if gotComponentsRoot != "components" {
		t.Fatalf("components root=%q, want components", gotComponentsRoot)
	}
}

func TestRunRouteWARCArchivesAllPaths(t *testing.T) {
	var out bytes.Buffer
	var listed bool
	resolved := make([]string, 0, 2)
	err := RunRoute([]string{"warc", "docs"}, RouteConfig{
		UsageRoute:     "usage route",
		UsageRouteWarc: "usage route warc",
		DefaultMode:    "dev",
		Stdout:         &out,
		ListWARCPaths: func(ctx context.Context, request RouteWARCRequest) ([]string, error) {
			listed = true
			if request.ContentRoot != "docs" {
				t.Fatalf("content root=%q, want docs", request.ContentRoot)
			}
			return []string{"/b", "/a"}, nil
		},
		ResolveWARC: func(ctx context.Context, request RouteWARCRequest) (qinternal.InProcessHTTPResponse, error) {
			resolved = append(resolved, request.RequestPath)
			return qinternal.InProcessHTTPResponse{
				StatusCode: http.StatusOK,
				Header:     http.Header{"Content-Type": []string{"text/plain"}},
				Body:       []byte("ok-" + request.RequestPath),
			}, nil
		},
	})
	if err != nil {
		t.Fatalf("RunRoute: %v", err)
	}
	if !listed {
		t.Fatalf("expected ListWARCPaths to be called")
	}
	if !reflect.DeepEqual(resolved, []string{"/a", "/b"}) {
		t.Fatalf("resolved=%v, want [/a /b]", resolved)
	}
	if got := strings.Count(out.String(), "WARC/1.1\r\n"); got != 2 {
		t.Fatalf("record count=%d, want 2", got)
	}
	if !strings.Contains(out.String(), "WARC-Target-URI: http://qip.local/a\r\n") {
		t.Fatalf("missing URI for /a")
	}
	if !strings.Contains(out.String(), "WARC-Target-URI: http://qip.local/b\r\n") {
		t.Fatalf("missing URI for /b")
	}
}

func TestRunRouteWARCTransformsArchive(t *testing.T) {
	var out bytes.Buffer
	var transformedInput []byte
	var transformedRouteCount int
	err := RunRoute([]string{"warc", "docs"}, RouteConfig{
		UsageRoute:     "usage route",
		UsageRouteWarc: "usage route warc",
		DefaultMode:    "dev",
		Stdout:         &out,
		ListWARCPaths: func(ctx context.Context, request RouteWARCRequest) ([]string, error) {
			return []string{"/a", "/b", "/c"}, nil
		},
		ResolveWARC: func(ctx context.Context, request RouteWARCRequest) (qinternal.InProcessHTTPResponse, error) {
			return qinternal.InProcessHTTPResponse{
				StatusCode: http.StatusOK,
				Header:     http.Header{"Content-Type": []string{"text/plain"}},
				Body:       []byte("ok"),
			}, nil
		},
		TransformWARC: func(ctx context.Context, request RouteWARCRequest, warc []byte) ([]byte, error) {
			transformedInput = append([]byte(nil), warc...)
			transformedRouteCount = request.RouteCount
			return warc, nil
		},
	})
	if err != nil {
		t.Fatalf("RunRoute: %v", err)
	}
	if len(transformedInput) == 0 || !bytes.Contains(transformedInput, []byte("WARC/1.1\r\n")) {
		t.Fatalf("expected original WARC archive bytes to be passed to TransformWARC")
	}
	if transformedRouteCount != 3 {
		t.Fatalf("route count=%d, want 3", transformedRouteCount)
	}
	if !bytes.Equal(out.Bytes(), transformedInput) {
		t.Fatalf("stdout does not contain the validated transformed archive")
	}
}

func TestRunRouteWARCIsReproducible(t *testing.T) {
	run := func() []byte {
		t.Helper()
		var out bytes.Buffer
		err := RunRoute([]string{"warc", "docs"}, RouteConfig{
			UsageRoute:     "usage route",
			UsageRouteWarc: "usage route warc",
			Stdout:         &out,
			ListWARCPaths: func(context.Context, RouteWARCRequest) ([]string, error) {
				return []string{"/b", "/a"}, nil
			},
			ResolveWARC: func(_ context.Context, request RouteWARCRequest) (qinternal.InProcessHTTPResponse, error) {
				return qinternal.InProcessHTTPResponse{
					StatusCode: http.StatusOK,
					Header:     http.Header{"Content-Type": []string{"text/plain"}},
					Body:       []byte("body for " + request.RequestPath),
				}, nil
			},
		})
		if err != nil {
			t.Fatalf("RunRoute: %v", err)
		}
		return out.Bytes()
	}

	first := run()
	second := run()
	if !bytes.Equal(first, second) {
		t.Fatal("router WARC export is not reproducible")
	}
}

func TestRunRouteWARCRejectsInvalidRecipeOutput(t *testing.T) {
	err := RunRoute([]string{"warc", "docs"}, RouteConfig{
		UsageRoute:     "usage route",
		UsageRouteWarc: "usage route warc",
		Stdout:         &bytes.Buffer{},
		ListWARCPaths: func(context.Context, RouteWARCRequest) ([]string, error) {
			return []string{"/a"}, nil
		},
		ResolveWARC: func(context.Context, RouteWARCRequest) (qinternal.InProcessHTTPResponse, error) {
			return qinternal.InProcessHTTPResponse{
				StatusCode: http.StatusOK,
				Header:     http.Header{"Content-Type": []string{"text/plain"}},
				Body:       []byte("ok"),
			}, nil
		},
		TransformWARC: func(context.Context, RouteWARCRequest, []byte) ([]byte, error) {
			return []byte("WARC/1.0\r\nContent-Length: 0\r\n\r\n\r\n\r\n"), nil
		},
	})
	if err == nil || !strings.Contains(err.Error(), "invalid final WARC archive") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestRunRouteWARCNoPaths(t *testing.T) {
	err := RunRoute([]string{"warc", "docs"}, RouteConfig{
		UsageRoute:     "usage route",
		UsageRouteWarc: "usage route warc",
		ListWARCPaths: func(ctx context.Context, request RouteWARCRequest) ([]string, error) {
			return nil, nil
		},
		ResolveWARC: func(ctx context.Context, request RouteWARCRequest) (qinternal.InProcessHTTPResponse, error) {
			return qinternal.InProcessHTTPResponse{}, errors.New("should not be called")
		},
	})
	if err == nil || !strings.Contains(err.Error(), "no route paths found to archive") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestRunRouteWARCCustomHost(t *testing.T) {
	var out bytes.Buffer
	err := RunRoute([]string{"warc", "--host", "example.com", "docs"}, RouteConfig{
		UsageRoute:     "usage route",
		UsageRouteWarc: "usage route warc",
		DefaultMode:    "dev",
		Stdout:         &out,
		ListWARCPaths: func(ctx context.Context, request RouteWARCRequest) ([]string, error) {
			if request.Host != "example.com" {
				t.Fatalf("host=%q, want example.com", request.Host)
			}
			return []string{"/a"}, nil
		},
		ResolveWARC: func(ctx context.Context, request RouteWARCRequest) (qinternal.InProcessHTTPResponse, error) {
			return qinternal.InProcessHTTPResponse{
				StatusCode: http.StatusOK,
				Header:     http.Header{"Content-Type": []string{"text/plain"}},
				Body:       []byte("ok"),
			}, nil
		},
	})
	if err != nil {
		t.Fatalf("RunRoute: %v", err)
	}
	if !strings.Contains(out.String(), "WARC-Target-URI: http://example.com/a\r\n") {
		t.Fatalf("missing custom-host URI")
	}
}

func TestRunRouteWARCAcceptsHTTPSOrigin(t *testing.T) {
	var out bytes.Buffer
	err := RunRoute([]string{"warc", "--host", "https://example.com", "docs"}, RouteConfig{
		UsageRoute:     "usage route",
		UsageRouteWarc: "usage route warc",
		ListWARCPaths: func(ctx context.Context, request RouteWARCRequest) ([]string, error) {
			return []string{"/a"}, nil
		},
		ResolveWARC: func(ctx context.Context, request RouteWARCRequest) (qinternal.InProcessHTTPResponse, error) {
			if request.Host != "https://example.com" {
				t.Fatalf("host=%q, want https://example.com", request.Host)
			}
			return qinternal.InProcessHTTPResponse{
				StatusCode: http.StatusOK,
				Header:     http.Header{"Content-Type": []string{"text/html"}},
				Body:       []byte("hello"),
			}, nil
		},
		Stdout: &out,
	})
	if err != nil {
		t.Fatalf("RunRoute: %v", err)
	}
	if !strings.Contains(out.String(), "WARC-Target-URI: https://example.com/a\r\n") {
		t.Fatalf("missing HTTPS origin URI")
	}
}

func TestRunRouteWARCRejectsHostWithPath(t *testing.T) {
	_, err := parseRouteWARCHost("https://example.com/docs")
	if err == nil || !strings.Contains(err.Error(), "invalid host") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestRunRouteWARCRejectsMethodFlags(t *testing.T) {
	err := RunRoute([]string{"warc", "-X", "HEAD", "docs"}, RouteConfig{
		UsageRoute:     "usage route",
		UsageRouteWarc: "usage route warc",
		ListWARCPaths: func(ctx context.Context, request RouteWARCRequest) ([]string, error) {
			return []string{"/a"}, nil
		},
		ResolveWARC: func(ctx context.Context, request RouteWARCRequest) (qinternal.InProcessHTTPResponse, error) {
			return qinternal.InProcessHTTPResponse{}, nil
		},
	})
	if err == nil || !strings.Contains(err.Error(), "flag provided but not defined: -X") {
		t.Fatalf("unexpected error: %v", err)
	}

	err = RunRoute([]string{"warc", "--method", "HEAD", "docs"}, RouteConfig{
		UsageRoute:     "usage route",
		UsageRouteWarc: "usage route warc",
		ListWARCPaths: func(ctx context.Context, request RouteWARCRequest) ([]string, error) {
			return []string{"/a"}, nil
		},
		ResolveWARC: func(ctx context.Context, request RouteWARCRequest) (qinternal.InProcessHTTPResponse, error) {
			return qinternal.InProcessHTTPResponse{}, nil
		},
	})
	if err == nil || !strings.Contains(err.Error(), "flag provided but not defined: -method") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestRunRouteWARCViewSourceRequiresRecipes(t *testing.T) {
	err := RunRoute([]string{"warc", "--view-source", "docs"}, RouteConfig{
		UsageRoute:     "usage route",
		UsageRouteWarc: "usage route warc",
		ListWARCPaths: func(ctx context.Context, request RouteWARCRequest) ([]string, error) {
			return []string{"/a"}, nil
		},
		ResolveWARC: func(ctx context.Context, request RouteWARCRequest) (qinternal.InProcessHTTPResponse, error) {
			return qinternal.InProcessHTTPResponse{}, nil
		},
	})
	if err == nil || !strings.Contains(err.Error(), "--view-source requires --recipes") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestRunRouteWARCViewSourceAddsViewSourceRecords(t *testing.T) {
	recipesRoot := t.TempDir()
	if err := os.MkdirAll(filepath.Join(recipesRoot, "text", "markdown"), 0o755); err != nil {
		t.Fatalf("mkdir recipes: %v", err)
	}
	markdownZig := filepath.Join(recipesRoot, "text", "markdown", "10-markdown-basic.zig")
	markdownWasm := filepath.Join(recipesRoot, "text", "markdown", "10-markdown-basic.wasm")
	if err := os.WriteFile(markdownZig, []byte("const std = @import(\"std\");"), 0o644); err != nil {
		t.Fatalf("write zig: %v", err)
	}
	if err := os.WriteFile(markdownWasm, []byte{0x00, 0x61, 0x73, 0x6d}, 0o644); err != nil {
		t.Fatalf("write wasm: %v", err)
	}
	if err := os.WriteFile(filepath.Join(recipesRoot, ".DS_Store"), []byte("noise"), 0o644); err != nil {
		t.Fatalf("write hidden file: %v", err)
	}
	componentsRoot := t.TempDir()
	if err := os.MkdirAll(filepath.Join(componentsRoot, "text"), 0o755); err != nil {
		t.Fatalf("mkdir components: %v", err)
	}
	if err := os.WriteFile(filepath.Join(componentsRoot, "text", "trim.zig"), []byte("const std = @import(\"std\");"), 0o644); err != nil {
		t.Fatalf("write component source zig: %v", err)
	}
	if err := os.WriteFile(filepath.Join(componentsRoot, "text", "styles.css"), []byte(".x{color:red}"), 0o644); err != nil {
		t.Fatalf("write component source css: %v", err)
	}
	if err := os.WriteFile(filepath.Join(componentsRoot, ".DS_Store"), []byte("noise"), 0o644); err != nil {
		t.Fatalf("write hidden component file: %v", err)
	}

	var out bytes.Buffer
	err := RunRoute([]string{"warc", "--view-source", "--recipes", recipesRoot, "--components", componentsRoot, "docs"}, RouteConfig{
		UsageRoute:     "usage route",
		UsageRouteWarc: "usage route warc",
		DefaultMode:    "dev",
		Stdout:         &out,
		ListWARCPaths: func(ctx context.Context, request RouteWARCRequest) ([]string, error) {
			if !request.ViewSource {
				t.Fatalf("expected ViewSource to be true")
			}
			return []string{"/a", "/guide", "/guide.md", "/text/trim.wasm"}, nil
		},
		ResolveWARC: func(ctx context.Context, request RouteWARCRequest) (qinternal.InProcessHTTPResponse, error) {
			return qinternal.InProcessHTTPResponse{
				StatusCode: http.StatusOK,
				Header:     http.Header{"Content-Type": []string{"text/plain"}},
				Body:       []byte("ok"),
			}, nil
		},
	})
	if err != nil {
		t.Fatalf("RunRoute: %v", err)
	}

	got := out.String()
	if gotCount := strings.Count(got, "WARC/1.1\r\n"); gotCount != 9 {
		t.Fatalf("record count=%d, want 9", gotCount)
	}
	if !strings.Contains(got, "WARC-Target-URI: http://qip.local/view-source\r\n") {
		t.Fatalf("missing view-source index record")
	}
	if !strings.Contains(got, "WARC-Target-URI: http://qip.local/view-source/recipes/text/markdown/10-markdown-basic.zig\r\n") {
		t.Fatalf("missing zig source record")
	}
	if !strings.Contains(got, "WARC-Target-URI: http://qip.local/view-source/recipes/text/markdown/10-markdown-basic.wasm\r\n") {
		t.Fatalf("missing wasm source record")
	}
	if !strings.Contains(got, "<h1>View Source</h1>") {
		t.Fatalf("missing View Source heading")
	}
	if !strings.Contains(got, "<h2>Recipes</h2>") {
		t.Fatalf("missing recipes heading in view-source index")
	}
	if !strings.Contains(got, "<h2>Content</h2>") {
		t.Fatalf("missing content heading in view-source index")
	}
	if !strings.Contains(got, "<h2>Components</h2>") {
		t.Fatalf("missing components heading in view-source index")
	}
	if gotCount := strings.Count(got, "<h2>Components</h2>"); gotCount != 1 {
		t.Fatalf("components heading count=%d, want 1", gotCount)
	}
	if strings.Contains(got, "<h2>Component Sources</h2>") {
		t.Fatalf("unexpected component sources heading in view-source index")
	}
	if !strings.Contains(got, "href=\"/view-source/recipes/text/markdown/10-markdown-basic.zig\"") {
		t.Fatalf("missing zig link in view-source index")
	}
	if !strings.Contains(got, "href=\"/guide.md\"") {
		t.Fatalf("missing markdown content link in view-source index")
	}
	if !strings.Contains(got, "href=\"/text/trim.wasm\"") {
		t.Fatalf("missing component link in view-source index")
	}
	if !strings.Contains(got, "href=\"/view-source/components/text/trim.zig\"") {
		t.Fatalf("missing component zig source link in view-source index")
	}
	if !strings.Contains(got, "href=\"/view-source/components/text/styles.css\"") {
		t.Fatalf("missing component css source link in view-source index")
	}
	if !strings.Contains(got, "WARC-Target-URI: http://qip.local/view-source/components/text/trim.zig\r\n") {
		t.Fatalf("missing component zig source record")
	}
	if !strings.Contains(got, "WARC-Target-URI: http://qip.local/view-source/components/text/styles.css\r\n") {
		t.Fatalf("missing component css source record")
	}
	if !strings.Contains(got, "Content-Type: application/wasm\r\n") {
		t.Fatalf("missing wasm content-type in archived response payload")
	}
	if strings.Contains(got, "/view-source/recipes/.DS_Store") {
		t.Fatalf("hidden files should not be included in view-source output")
	}
	if strings.Contains(got, "/view-source/components/.DS_Store") {
		t.Fatalf("hidden component source files should not be included in view-source output")
	}
}

func TestBuildMinimalWARCResponseRecord(t *testing.T) {
	resp := qinternal.InProcessHTTPResponse{
		StatusCode: http.StatusOK,
		Header: http.Header{
			"Content-Type": []string{"text/plain; charset=utf-8"},
		},
		Body: []byte("hello"),
	}

	out, err := buildMinimalWARCResponseRecord("http://qip.local/about", resp)
	if err != nil {
		t.Fatalf("buildMinimalWARCResponseRecord: %v", err)
	}

	checks := []string{
		"WARC/1.1\r\n",
		"WARC-Date: 2000-01-01T00:00:00Z\r\n",
		"WARC-Record-ID: <urn:uuid:",
		"WARC-Type: response\r\n",
		"WARC-Target-URI: http://qip.local/about\r\n",
		"Content-Type: application/http; msgtype=response\r\n",
		"HTTP/1.1 200 OK\r\n",
		"Content-Length: 5\r\n",
		"\r\nhello\r\n\r\n",
	}
	for _, check := range checks {
		if !bytes.Contains(out, []byte(check)) {
			t.Fatalf("missing %q in WARC output", check)
		}
	}
}
