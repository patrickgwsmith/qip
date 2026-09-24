package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	qinternal "github.com/royalicing/qip/internal"
)

func TestSiteElementEntrypointsRegisterOneElementEach(t *testing.T) {
	tests := []struct {
		path       string
		registered string
		excluded   []string
	}{
		{path: "site/_elements/qip-edit.js", registered: `customElements.define("qip-edit"`, excluded: []string{`customElements.define("qip-view"`}},
		{path: "site/_elements/qip-form.js", registered: `customElements.define("qip-form"`},
		{path: "site/_elements/qip-view.js", registered: `customElements.define("qip-view"`, excluded: []string{`customElements.define("qip-edit"`}},
		{path: "site/_elements/qip-play.js", registered: `customElements.define("qip-play"`, excluded: []string{`customElements.define("qip-step"`}},
		{path: "site/_elements/qip-tui.js", registered: `customElements.define("qip-tui"`},
		{path: "site/_elements/qip-wasm-policy.js", registered: `customElements.define("qip-wasm-policy"`},
	}
	for _, tt := range tests {
		body, err := os.ReadFile(tt.path)
		if err != nil {
			t.Fatalf("read %s: %v", tt.path, err)
		}
		if !bytes.Contains(body, []byte(tt.registered)) {
			t.Errorf("%s does not register %s", tt.path, tt.registered)
		}
		for _, excluded := range tt.excluded {
			if bytes.Contains(body, []byte(excluded)) {
				t.Errorf("%s unexpectedly contains %s", tt.path, excluded)
			}
		}
	}
}

func TestLoadElementAssetsMapsJavaScriptAndSelectsTopLevelEntrypoints(t *testing.T) {
	root := t.TempDir()
	files := map[string]string{
		"copy-code.js":       "export {};",
		"_qip-ktx2.js":       "export {};",
		"_qip-pipeline.js":   "export {};",
		"plain.js":           "export {};",
		"Upper-box.js":       "export {};",
		"lib/shared.js":      "export {};",
		"ignored-source.css": "body {}",
	}
	for rel, body := range files {
		full := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", rel, err)
		}
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatalf("write %s: %v", rel, err)
		}
	}

	assets, paths, entries, err := loadElementAssets(root)
	if err != nil {
		t.Fatalf("loadElementAssets: %v", err)
	}
	wantPaths := []string{"/elements/Upper-box.js", "/elements/_qip-ktx2.js", "/elements/_qip-pipeline.js", "/elements/copy-code.js", "/elements/lib/shared.js", "/elements/plain.js"}
	if !reflect.DeepEqual(paths, wantPaths) {
		t.Fatalf("paths=%v, want %v", paths, wantPaths)
	}
	if want := []string{"/elements/copy-code.js"}; !reflect.DeepEqual(entries, want) {
		t.Fatalf("entries=%v, want %v", entries, want)
	}
	if _, ok := assets["/elements/copy-code.js"]; !ok {
		t.Fatal("copy-code asset missing")
	}
}

func TestResolveElementAssetResponseServesJavaScript(t *testing.T) {
	root := t.TempDir()
	filePath := filepath.Join(root, "test-box.js")
	if err := os.WriteFile(filePath, []byte("export {};"), 0o644); err != nil {
		t.Fatalf("write element: %v", err)
	}
	state := &RouterServerState{
		RouterFileState: &RouterFileState{elementAssets: map[string]elementAsset{
			"/elements/test-box.js": {filePath: filePath},
		}},
		recipeChains: map[string]*qinternal.Pipeline{},
	}
	response, ok, err := resolveElementAssetResponse(context.Background(), state, "/elements/test-box.js", 1, RouterServerTimeouts{})
	if err != nil || !ok {
		t.Fatalf("resolveElementAssetResponse: ok=%v err=%v", ok, err)
	}
	if got := response.Header.Get("Content-Type"); got != "text/javascript" {
		t.Fatalf("Content-Type=%q", got)
	}
	if got := string(response.Body); got != "export {};" {
		t.Fatalf("body=%q", got)
	}
}
