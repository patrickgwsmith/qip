package main

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"

	qinternal "github.com/royalicing/qip/internal"
)

type recipeCandidate struct {
	path     string
	filename string
	order    int
	body     []byte
	digest   [32]byte
}

type recipeFileSet map[string][]recipeCandidate

type moduleFileStamp struct {
	modTimeUnixNano int64
	sizeBytes       int64
}

func parseRecipeFilename(filename string) (order int, disabled bool, err error) {
	if !isASCII(filename) {
		return 0, false, errors.New("filename must be ASCII")
	}
	if !strings.HasSuffix(filename, ".wasm") {
		return 0, false, errors.New("filename must end with .wasm")
	}

	trimmed := filename
	if strings.HasPrefix(trimmed, "-") {
		disabled = true
		trimmed = trimmed[1:]
	}

	if len(trimmed) < len("00-a.wasm") {
		return 0, disabled, errors.New("filename must match NN-name.wasm")
	}
	if trimmed[0] < '0' || trimmed[0] > '9' || trimmed[1] < '0' || trimmed[1] > '9' {
		return 0, disabled, errors.New("filename prefix must be two digits")
	}
	if trimmed[2] != '-' {
		return 0, disabled, errors.New("filename must match NN-name.wasm")
	}
	namePart := strings.TrimSuffix(trimmed, ".wasm")[3:]
	if namePart == "" {
		return 0, disabled, errors.New("recipe name must not be empty")
	}

	order = int(trimmed[0]-'0')*10 + int(trimmed[1]-'0')
	return order, disabled, nil
}

func isASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] > 0x7f {
			return false
		}
	}
	return true
}

func loadRecipeChains(ctx context.Context, recipesRoot string, opts options) (map[string]*qinternal.Pipeline, map[string][][32]byte, error) {
	files, digestsByMIME, err := loadRecipeFileSet(recipesRoot)
	if err != nil {
		return nil, nil, err
	}
	chains, err := compileRecipeFileSet(ctx, files, newQIPRuntime(opts))
	if err != nil {
		return nil, nil, err
	}
	return chains, digestsByMIME, nil
}

func loadRecipeFileSet(recipesRoot string) (recipeFileSet, map[string][][32]byte, error) {
	files := make(recipeFileSet)
	digestsByMIME := make(map[string][][32]byte)
	if recipesRoot == "" {
		return files, digestsByMIME, nil
	}

	candidatesByMIME := make(map[string][]recipeCandidate)
	err := qinternal.WalkFilesFollowingSymlinks(recipesRoot, "recipe", func(fullPath string, _ fs.FileInfo) error {
		relPath, err := filepath.Rel(recipesRoot, fullPath)
		if err != nil {
			return err
		}
		relPath = filepath.ToSlash(relPath)
		filename := path.Base(relPath)
		if !strings.HasSuffix(filename, ".wasm") {
			return nil
		}
		parts := strings.Split(relPath, "/")
		if len(parts) != 3 {
			return fmt.Errorf("recipe path %q must match <type>/<subtype>/<file>", relPath)
		}
		mimeType := parts[0] + "/" + parts[1]
		filename = parts[2]

		order, disabled, err := parseRecipeFilename(filename)
		if err != nil {
			return fmt.Errorf("invalid recipe filename %q: %w", relPath, err)
		}
		if disabled {
			return nil
		}

		body, err := os.ReadFile(fullPath)
		if err != nil {
			return err
		}
		digest := sha256.Sum256(body)
		candidatesByMIME[mimeType] = append(candidatesByMIME[mimeType], recipeCandidate{
			path:     fullPath,
			filename: filename,
			order:    order,
			body:     body,
			digest:   digest,
		})
		return nil
	})
	if err != nil {
		return nil, nil, err
	}

	mimeTypes := make([]string, 0, len(candidatesByMIME))
	for mimeType := range candidatesByMIME {
		mimeTypes = append(mimeTypes, mimeType)
	}
	sort.Strings(mimeTypes)

	for _, mimeType := range mimeTypes {
		candidates := candidatesByMIME[mimeType]
		sort.Slice(candidates, func(i, j int) bool {
			if candidates[i].order != candidates[j].order {
				return candidates[i].order < candidates[j].order
			}
			return candidates[i].filename < candidates[j].filename
		})
		seenOrder := make(map[int]string, len(candidates))
		for _, candidate := range candidates {
			if prevPath, exists := seenOrder[candidate.order]; exists {
				return nil, nil, fmt.Errorf("duplicate recipe prefix for %s: %02d in %q and %q", mimeType, candidate.order, prevPath, candidate.path)
			}
			seenOrder[candidate.order] = candidate.path
		}
		digests := make([][32]byte, len(candidates))
		for i, candidate := range candidates {
			digests[i] = candidate.digest
		}
		files[mimeType] = candidates
		digestsByMIME[mimeType] = digests
	}

	return files, digestsByMIME, nil
}

func compileRecipeFileSet(ctx context.Context, files recipeFileSet, compiler PipelineCompiler) (map[string]*qinternal.Pipeline, error) {
	chains := make(map[string]*qinternal.Pipeline, len(files))
	mimeTypes := make([]string, 0, len(files))
	for mimeType := range files {
		mimeTypes = append(mimeTypes, mimeType)
	}
	sort.Strings(mimeTypes)

	for _, mimeType := range mimeTypes {
		candidates := files[mimeType]
		components := make([]ResolvedComponent, len(candidates))
		for i, candidate := range candidates {
			components[i] = ResolvedComponent{
				Name:          candidate.path,
				WASM:          candidate.body,
				UniformValues: make(map[string]string),
			}
		}
		pipeline, err := compiler.CompilePipeline(ctx, components)
		if err != nil {
			closePipelines(ctx, chains)
			return nil, err
		}
		chains[mimeType] = pipeline
	}
	return chains, nil
}

func scanRecipeModuleStamps(recipesRoot string) (map[string]moduleFileStamp, error) {
	stamps := make(map[string]moduleFileStamp)
	if recipesRoot == "" {
		return stamps, nil
	}

	err := qinternal.WalkFilesFollowingSymlinks(recipesRoot, "recipe", func(fullPath string, info fs.FileInfo) error {
		if strings.ToLower(path.Ext(fullPath)) != ".wasm" {
			return nil
		}

		relPath, err := filepath.Rel(recipesRoot, fullPath)
		if err != nil {
			return err
		}
		relPath = filepath.ToSlash(relPath)
		stamps[relPath] = moduleFileStamp{
			modTimeUnixNano: info.ModTime().UnixNano(),
			sizeBytes:       info.Size(),
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return stamps, nil
}

func recipeModuleStampsEqual(a map[string]moduleFileStamp, b map[string]moduleFileStamp) bool {
	if len(a) != len(b) {
		return false
	}
	for path, stampA := range a {
		stampB, ok := b[path]
		if !ok {
			return false
		}
		if stampA != stampB {
			return false
		}
	}
	return true
}

func closePipelines(ctx context.Context, pipelines map[string]*qinternal.Pipeline) {
	for _, p := range pipelines {
		p.Close(ctx)
	}
}
