package qinternal

import "testing"

func TestContentPathFilterIsIncludesMinusExcludes(t *testing.T) {
	filter, err := NewContentPathFilter([]string{"blog", "./docs/"}, []string{"blog/drafts"})
	if err != nil {
		t.Fatal(err)
	}
	cases := map[string]bool{
		"blog.md":               true,
		"blog/index.md":         true,
		"blog/post.md":          true,
		"blog/drafts.md":        false,
		"blog/drafts/wip.md":    false,
		"blogroll.md":           false,
		"docs/router.md":        true,
		"index.md":              false,
		"blog/.notes/a.md":      false,
		"blog/.DS_Store":        false,
		"blog/drafts-public.md": true,
	}
	for relPath, want := range cases {
		if got := filter.Allows(relPath); got != want {
			t.Errorf("Allows(%q)=%v, want %v", relPath, got, want)
		}
	}
}

func TestContentPathFilterExcludeOnlySkipsDotPaths(t *testing.T) {
	filter, err := NewContentPathFilter(nil, []string{"blog/drafts"})
	if err != nil {
		t.Fatal(err)
	}
	cases := map[string]bool{
		"index.md":           true,
		"blog/post.md":       true,
		"blog/drafts/wip.md": false,
		".env":               false,
		".well-known/a.txt":  false,
	}
	for relPath, want := range cases {
		if got := filter.Allows(relPath); got != want {
			t.Errorf("Allows(%q)=%v, want %v", relPath, got, want)
		}
	}
}

func TestContentPathFilterIncludeCanNameDotPath(t *testing.T) {
	filter, err := NewContentPathFilter([]string{".well-known"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !filter.Allows(".well-known/security.txt") {
		t.Fatal("expected an include path to allow the dot path it names")
	}
	if filter.Allows(".well-known/.secret") {
		t.Fatal("expected dot paths below an include path to be skipped")
	}
}

func TestContentPathFilterInactiveAllowsEverything(t *testing.T) {
	var filter ContentPathFilter
	if filter.Active() || !filter.Allows(".env") {
		t.Fatal("expected an empty filter to allow every path")
	}
}

func TestContentPathFilterRejectsPathsOutsideContentRoot(t *testing.T) {
	for _, value := range []string{"", ".", "/", "..", "../x", "a\\b"} {
		if _, err := NewContentPathFilter([]string{value}, nil); err == nil {
			t.Errorf("expected --include %q to be rejected", value)
		}
	}
}
