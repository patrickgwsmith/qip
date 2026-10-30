package main

import (
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"

	qinternal "github.com/royalicing/qip/internal"
)

func loadComponentAssets(componentsRoot string) (map[string]componentAsset, []string, error) {
	assets := make(map[string]componentAsset)
	if componentsRoot == "" {
		return assets, nil, nil
	}

	err := qinternal.WalkFilesFollowingSymlinks(componentsRoot, "component", func(fullPath string, _ fs.FileInfo) error {
		relPath, err := filepath.Rel(componentsRoot, fullPath)
		if err != nil {
			return err
		}
		relPath = filepath.ToSlash(relPath)
		if !utf8.ValidString(relPath) {
			return fmt.Errorf("component path %q must be valid UTF-8", relPath)
		}
		if strings.HasPrefix(relPath, "/") {
			return fmt.Errorf("component path %q must not start with /", relPath)
		}
		cleanRel := path.Clean(relPath)
		if cleanRel != relPath || cleanRel == "." || cleanRel == ".." || strings.HasPrefix(cleanRel, "../") {
			return fmt.Errorf("component path %q is not canonical", relPath)
		}
		if strings.ToLower(path.Ext(relPath)) != ".wasm" {
			return nil
		}

		body, err := os.ReadFile(fullPath)
		if err != nil {
			return err
		}
		requestPath := "/" + cleanRel
		if _, exists := assets[requestPath]; exists {
			return fmt.Errorf("duplicate component request path %q", requestPath)
		}
		assets[requestPath] = componentAsset{
			body:        body,
			contentType: "application/wasm",
		}
		return nil
	})
	if err != nil {
		return nil, nil, err
	}

	requestPaths := make([]string, 0, len(assets))
	for requestPath := range assets {
		requestPaths = append(requestPaths, requestPath)
	}
	sort.Strings(requestPaths)
	return assets, requestPaths, nil
}

func loadElementAssets(elementsRoot string) (map[string]elementAsset, []string, []string, error) {
	assets := make(map[string]elementAsset)
	if elementsRoot == "" {
		return assets, nil, nil, nil
	}

	err := qinternal.WalkFilesFollowingSymlinks(elementsRoot, "element", func(fullPath string, _ fs.FileInfo) error {
		relPath, err := filepath.Rel(elementsRoot, fullPath)
		if err != nil {
			return err
		}
		relPath = filepath.ToSlash(relPath)
		if !utf8.ValidString(relPath) {
			return fmt.Errorf("element path %q must be valid UTF-8", relPath)
		}
		if strings.HasPrefix(relPath, "/") {
			return fmt.Errorf("element path %q must not start with /", relPath)
		}
		cleanRel := path.Clean(relPath)
		if cleanRel != relPath || cleanRel == "." || cleanRel == ".." || strings.HasPrefix(cleanRel, "../") {
			return fmt.Errorf("element path %q is not canonical", relPath)
		}
		if strings.ToLower(path.Ext(relPath)) != ".js" {
			return nil
		}

		requestPath := "/elements/" + cleanRel
		if _, exists := assets[requestPath]; exists {
			return fmt.Errorf("duplicate element request path %q", requestPath)
		}
		assets[requestPath] = elementAsset{filePath: fullPath}
		return nil
	})
	if err != nil {
		return nil, nil, nil, err
	}

	requestPaths := make([]string, 0, len(assets))
	entryPaths := make([]string, 0, len(assets))
	for requestPath := range assets {
		requestPaths = append(requestPaths, requestPath)
		rel := strings.TrimPrefix(requestPath, "/elements/")
		if !strings.Contains(rel, "/") && isValidCustomElementName(strings.TrimSuffix(rel, ".js")) {
			entryPaths = append(entryPaths, requestPath)
		}
	}
	sort.Strings(requestPaths)
	sort.Strings(entryPaths)
	return assets, requestPaths, entryPaths, nil
}

func isValidCustomElementName(name string) bool {
	if name == "" || name[0] < 'a' || name[0] > 'z' || !strings.Contains(name, "-") || strings.HasPrefix(strings.ToLower(name), "xml") {
		return false
	}
	for _, r := range name {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '.' || r == '_' || r == '-' {
			continue
		}
		return false
	}
	return true
}
