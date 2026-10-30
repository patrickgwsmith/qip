package qinternal

import (
	"strings"
	"testing"
)

func TestCheckRouterPositionalContentDir(t *testing.T) {
	dir := t.TempDir()
	for _, tc := range []struct {
		name         string
		subcommand   string
		positionals  []string
		requestPaths int
		suggestion   string
	}{
		{"path only", "get", []string{"/"}, 1, ""},
		{"absolute path is a request path", "get", []string{dir}, 1, ""},
		{"relative path", "get", []string{"no-such-dir"}, 1, `must start with "/"`},
		{"relative path for kindred", "kindred", []string{"docs/router"}, 1, `must start with "/"`},
		{"no args", "list", nil, 0, ""},
		{"dir and path", "get", []string{"./site", "/about"}, 1, "qip router get -C ./site /about"},
		{"github dir alone", "head", []string{"github:owner/repo"}, 1, "qip router head -C github:owner/repo /"},
		{"existing dir alone", "kindred", []string{"."}, 1, "qip router kindred -C . /"},
		{"dir for list", "list", []string{"./site"}, 0, "qip router list -C ./site"},
		{"dir for dev", "dev", []string{"site"}, 0, "qip router dev -C site"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := CheckRouterPositionalContentDir(tc.subcommand, tc.positionals, tc.requestPaths)
			if tc.suggestion == "" {
				if err != nil {
					t.Fatalf("error = %v, want nil", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.suggestion) {
				t.Fatalf("error = %v, want suggestion %q", err, tc.suggestion)
			}
		})
	}
}
