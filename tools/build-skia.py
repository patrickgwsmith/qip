#!/usr/bin/env python3
"""Compile the pinned Skia CPU SVG closure without GN or network access."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import shlex
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--clang', required=True)
parser.add_argument('--sysroot', required=True)
parser.add_argument('--root', required=True)
parser.add_argument('--build-dir', required=True)
parser.add_argument('--library', required=True)
parser.add_argument('--jobs', type=int, default=4)
args = parser.parse_args()
root = Path(args.root).resolve()
build = Path(args.build_dir).resolve()
build.mkdir(parents=True, exist_ok=True)
common = [args.clang, '--target=wasm32-unknown-emscripten', '--sysroot=' + args.sysroot,
          '-O2', '-flto', '-ffunction-sections', '-fdata-sections', '-msimd128', '-mbulk-memory',
          '-fno-stack-protector', '-fno-math-errno', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables',
          '-fno-builtin-malloc', '-fno-builtin-calloc', '-fno-builtin-realloc', '-fno-builtin-free',
          '-fno-threadsafe-statics', '-U__STDCPP_THREADS__', '-D_LIBCPP_ABI_VERSION=2',
          '-isystem', str(Path(args.sysroot) / 'include/compat'), '-DSK_DISABLE_LEGACY_PNG_WRITEBUFFER', '-DQIP_SINGLE_THREAD', '-DSK_BUILD_FOR_UNIX', '-DNDEBUG', '-Wno-attributes', '-ffp-contract=off']
groups = json.loads((root / 'qip/sources.json').read_text())
tasks = []
for group in groups:
    flags = ['-D' + value for value in group['defines']]
    flags += ['-I' + str(root / value) for value in group['include_dirs']]
    for value in group.get('system_include_dirs', []):
        flags += ['-isystem', str(root / value)]
    for source in group['sources']:
        tasks.append((source, flags))

def compile_source(task):
    source, flags = task
    obj = build / (source.replace('/', '_') + '.o')
    dependency = obj.with_suffix('.d')
    signature = obj.with_suffix('.command')
    language = [] if source.endswith('.c') else ['-std=c++17', '-fno-exceptions', '-fno-rtti']
    # Clang 14 Wasm auto-vectorization produces stray spans on complex paths.
    # Keep path conversion scalar; the Tiger coverage test guards this choice.
    if source in ['src/core/SkScan_AAAPath.cpp', 'src/core/SkAnalyticEdge.cpp',
                  'src/core/SkEdgeBuilder.cpp', 'src/core/SkEdgeClipper.cpp', 'src/core/SkEdge.cpp']:
        language += ['-fno-vectorize', '-fno-slp-vectorize']
    command = common + language + flags + ['-MD', '-MF', str(dependency), '-c', str(root / source), '-o', str(obj)]
    digest = hashlib.sha256(json.dumps(command).encode()).hexdigest()
    if obj.exists() and dependency.exists() and signature.exists() and signature.read_text() == digest:
        dependencies = shlex.split(dependency.read_text().replace('\\\n', ' ').split(':', 1)[1])
        if all(Path(name).exists() and Path(name).stat().st_mtime <= obj.stat().st_mtime for name in dependencies):
            return str(obj)
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(source + '\n' + result.stderr)
    signature.write_text(digest)
    return str(obj)

with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as executor:
    objects = list(executor.map(compile_source, tasks))
ar = str(Path(args.clang).with_name('llvm-ar'))
library = Path(args.library)
temporary = library.with_suffix('.tmp.a')
temporary.unlink(missing_ok=True)
subprocess.run([ar, 'rcs', str(temporary), *objects], check=True)
temporary.replace(library)
print(f'Skia: {len(objects)} translation units -> {args.library}')
