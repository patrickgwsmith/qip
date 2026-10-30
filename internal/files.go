package qinternal

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

func WalkFilesFollowingSymlinks(root string, entryKind string, visit func(fullPath string, info fs.FileInfo) error) error {
	seenDirs := make(map[string]uint8)
	var walkDir func(readDir string) error
	walkDir = func(readDir string) error {
		realDir, err := filepath.EvalSymlinks(readDir)
		if err != nil {
			return err
		}
		realDir, err = filepath.Abs(realDir)
		if err != nil {
			return err
		}
		realDir = filepath.Clean(realDir)
		if seenDirs[realDir] > 0 {
			// Avoid infinite recursion when a symlink points back to an ancestor.
			return nil
		}
		seenDirs[realDir]++
		defer func() {
			seenDirs[realDir]--
		}()

		entries, err := os.ReadDir(readDir)
		if err != nil {
			return err
		}
		for _, entry := range entries {
			fullPath := filepath.Join(readDir, entry.Name())
			mode := entry.Type()
			if mode.IsRegular() {
				info, err := entry.Info()
				if err != nil {
					return err
				}
				if err := visit(fullPath, info); err != nil {
					return err
				}
				continue
			}
			if mode.IsDir() {
				if err := walkDir(fullPath); err != nil {
					return err
				}
				continue
			}
			if mode&fs.ModeSymlink == 0 {
				return fmt.Errorf("%s entry %q must be a regular file", entryKind, fullPath)
			}

			targetInfo, err := os.Stat(fullPath)
			if err != nil {
				return err
			}
			if targetInfo.Mode().IsRegular() {
				if err := visit(fullPath, targetInfo); err != nil {
					return err
				}
				continue
			}
			if targetInfo.IsDir() {
				if err := walkDir(fullPath); err != nil {
					return err
				}
				continue
			}
			return fmt.Errorf("%s entry %q must be a regular file", entryKind, fullPath)
		}
		return nil
	}

	return walkDir(root)
}
