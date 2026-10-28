package qinternal

import (
	"flag"
	"fmt"
	"net/http"
	"path"
	"strings"
)

// ContentPathFilter limits which content files QIP Router serves, lists and
// archives. The result is the union of the include paths, or every file when
// there are none, minus the union of the exclude paths. Flag order does not
// matter. An active filter also skips dot paths unless an include path names
// them. Reserved directories such as _recipes are not content and are not
// affected.
type ContentPathFilter struct {
	include []string
	exclude []string
}

// ContentFilterFlags collects repeatable --include and --exclude flags.
type ContentFilterFlags struct {
	include repeatedPathFlag
	exclude repeatedPathFlag
}

// ContentFilterFlagNames lists the content filter flags that take a value.
var ContentFilterFlagNames = []string{"--include", "--exclude"}

// Register adds --include and --exclude to fs.
func (f *ContentFilterFlags) Register(fs *flag.FlagSet) {
	fs.Var(&f.include, "include", "only route content under this path (repeatable)")
	fs.Var(&f.exclude, "exclude", "do not route content under this path (repeatable)")
}

// Filter validates the collected paths.
func (f *ContentFilterFlags) Filter() (ContentPathFilter, error) {
	return NewContentPathFilter(f.include, f.exclude)
}

type repeatedPathFlag []string

func (p *repeatedPathFlag) String() string {
	return strings.Join(*p, ",")
}

func (p *repeatedPathFlag) Set(value string) error {
	*p = append(*p, value)
	return nil
}

// NewContentPathFilter validates include and exclude paths relative to the
// content root.
func NewContentPathFilter(include []string, exclude []string) (ContentPathFilter, error) {
	var filter ContentPathFilter
	var err error
	if filter.include, err = normalizeContentFilterPaths("--include", include); err != nil {
		return ContentPathFilter{}, err
	}
	if filter.exclude, err = normalizeContentFilterPaths("--exclude", exclude); err != nil {
		return ContentPathFilter{}, err
	}
	return filter, nil
}

func normalizeContentFilterPaths(flagName string, raw []string) ([]string, error) {
	out := make([]string, 0, len(raw))
	for _, value := range raw {
		p := strings.TrimSpace(value)
		if strings.Contains(p, "\\") {
			return nil, fmt.Errorf("%s %q must use / separators", flagName, value)
		}
		p = strings.Trim(p, "/")
		p = path.Clean(p)
		if p == "." || p == "" {
			return nil, fmt.Errorf("%s %q must name a path inside the content root", flagName, value)
		}
		if p == ".." || strings.HasPrefix(p, "../") {
			return nil, fmt.Errorf("%s %q must not leave the content root", flagName, value)
		}
		out = append(out, p)
	}
	return out, nil
}

// Active reports whether any include or exclude path was given.
func (f ContentPathFilter) Active() bool {
	return len(f.include) > 0 || len(f.exclude) > 0
}

// Allows reports whether the content file at relPath is routed.
func (f ContentPathFilter) Allows(relPath string) bool {
	if !f.Active() {
		return true
	}
	for _, prefix := range f.exclude {
		if _, ok := contentFilterMatch(relPath, prefix); ok {
			return false
		}
	}
	if len(f.include) == 0 {
		return !hasDotPathSegment(relPath)
	}
	for _, prefix := range f.include {
		if rest, ok := contentFilterMatch(relPath, prefix); ok && !hasDotPathSegment(rest) {
			return true
		}
	}
	return false
}

// contentFilterMatch matches whole path segments, so "blog" matches
// "blog/post.md" but not "blogroll.md". It also matches the file whose path
// without its extension is the prefix, so "blog/drafts" matches
// "blog/drafts.md". It returns the part of relPath below the prefix.
func contentFilterMatch(relPath string, prefix string) (string, bool) {
	if relPath == prefix || strings.TrimSuffix(relPath, path.Ext(relPath)) == prefix {
		return "", true
	}
	if strings.HasPrefix(relPath, prefix+"/") {
		return relPath[len(prefix)+1:], true
	}
	return "", false
}

func hasDotPathSegment(relPath string) bool {
	for segment := range strings.SplitSeq(relPath, "/") {
		if strings.HasPrefix(segment, ".") {
			return true
		}
	}
	return false
}

// FilterContentRoutes returns the routes whose content file the filter allows.
func FilterContentRoutes(routes map[string]ContentRoute, filter ContentPathFilter) map[string]ContentRoute {
	if !filter.Active() {
		return routes
	}
	out := make(map[string]ContentRoute, len(routes))
	for requestPath, route := range routes {
		if filter.Allows(route.RelPath) {
			out[requestPath] = route
		}
	}
	return out
}

// KindredParentPaths returns the canonical parent page paths that a WARC
// recipe receives as Kindred Routes for requestPath.
func KindredParentPaths(requestPath string) []string {
	parents := kindredParentRoutePaths(requestPath)
	out := make([]string, 0, len(parents))
	for _, parentPath := range parents {
		canonical, _ := CanonicalRequestPath(parentPath, DefaultRouteOptions())
		if canonical != requestPath {
			out = append(out, canonical)
		}
	}
	return out
}

// IsKindredParentResponse reports whether response can be a Kindred Route
// parent page: a 200 OK HTML response.
func IsKindredParentResponse(response InProcessHTTPResponse) bool {
	return response.StatusCode == http.StatusOK && isHTMLMediaType(response.Header.Get("Content-Type"))
}
