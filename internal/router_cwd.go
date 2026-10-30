package qinternal

import (
	"flag"
	"fmt"
	"os"
	"strings"
)

// RouterCWDFlagNames are the flags that take the qip router content directory.
var RouterCWDFlagNames = []string{"-C", "--cwd"}

// RegisterRouterCWDFlag registers -C and --cwd, defaulting to the current
// directory.
func RegisterRouterCWDFlag(fs *flag.FlagSet, contentRoot *string) {
	fs.StringVar(contentRoot, "C", ".", "content directory")
	fs.StringVar(contentRoot, "cwd", ".", "content directory")
}

// CheckRouterPositionalContentDir rejects the content directory positional
// argument that qip router subcommands took before -C/--cwd. requestPaths is
// how many positional request paths the subcommand accepts.
func CheckRouterPositionalContentDir(subcommand string, positionals []string, requestPaths int) error {
	if len(positionals) > requestPaths {
		return routerPositionalContentDirError(subcommand, positionals[0], positionals[1:])
	}
	for _, arg := range positionals {
		if strings.HasPrefix(arg, "/") {
			continue
		}
		if looksLikeContentDir(arg) {
			return routerPositionalContentDirError(subcommand, arg, []string{"/"})
		}
		return fmt.Errorf("qip router %s request path must start with \"/\": %q", subcommand, arg)
	}
	return nil
}

// looksLikeContentDir reports whether a request path argument without a
// leading "/" is a content directory from before -C/--cwd.
func looksLikeContentDir(arg string) bool {
	if strings.HasPrefix(arg, "github:") {
		return true
	}
	info, err := os.Stat(arg)
	return err == nil && info.IsDir()
}

func routerPositionalContentDirError(subcommand string, contentRoot string, rest []string) error {
	suggestion := append([]string{"qip router", subcommand, "-C", contentRoot}, rest...)
	return fmt.Errorf("qip router %s no longer takes the content directory as an argument; pass it with -C or --cwd (default: current directory):\n  %s", subcommand, strings.Join(suggestion, " "))
}
