#!/usr/bin/env python3
"""Extract the SVG source closure from `gn desc OUT '*' --format=json`."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('targets', type=Path)
parser.add_argument('--root', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = args.root.resolve()
targets = json.loads(args.targets.read_text())
seen = set()

def walk(label):
    # QIP disables FreeType PNG bitmap glyphs in ftoption.h and BUILD.gn.
    if label in seen or label == '//third_party/libpng:libpng':
        return
    seen.add(label)
    for dependency in targets[label].get('deps', []):
        walk(dependency)

walk('//modules/svg:svg')
groups = []
for label in sorted(seen):
    target = targets[label]
    sources = [name[2:] for name in target.get('sources', []) if name.endswith(('.c', '.cc', '.cpp'))]
    if 'src/ports/SkOSFile_stdio.cpp' in sources:
        sources = [s for s in sources if s not in ['src/ports/SkOSFile_stdio.cpp', 'src/ports/SkOSFile_posix.cpp']]
        sources.append('qip/SkOSFile_none.cpp')
    if not sources:
        continue
    flags = target.get('cflags', [])
    system_dirs = []
    for i, flag in enumerate(flags):
        if flag == '-isystem':
            path = Path(flags[i + 1]).resolve().relative_to(root).as_posix()
            if 'libpng' not in path:
                system_dirs.append(path)
    groups.append(dict(target=label, sources=sources, defines=target.get('defines', []),
                       include_dirs=[name[2:].rstrip('/') or '.' for name in target.get('include_dirs', [])],
                       system_include_dirs=list(dict.fromkeys(system_dirs))))
args.output.write_text(json.dumps(groups, indent=2) + '\n')
