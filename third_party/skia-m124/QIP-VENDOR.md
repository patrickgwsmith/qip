# Skia CPU SVG source for QIP

This tree builds the CPU `SkSVGDOM` renderer for the SVG-to-KTX2 Content
component. The normal build reads `qip/sources.json`; it does not download
libraries, run GN, or use system graphics libraries.

## Sources and licenses

Archive checksums use SHA-256.

| Source | Pinned revision | Archive URL | SHA-256 |
| --- | --- | --- | --- |
| Skia, `chrome/m124` | `03c4671cffded59a3bb00e18bfae3c2763424fc6` | `https://codeload.github.com/google/skia/tar.gz/03c4671cffded59a3bb00e18bfae3c2763424fc6` | `187ac1d03c3ed575de8fe93eff342f4e8245af04367a571a2ad1c342f1e04a2c` |
| Expat, from Skia's `DEPS` | `441f98d02deafd9b090aea568282b28f66a50e36` | `https://codeload.github.com/libexpat/libexpat/tar.gz/441f98d02deafd9b090aea568282b28f66a50e36` | `f94dd8eed1d63ed0e6b3be73174ee2efb237a9e15bd0c52ba880693d8891560e` |
| FreeType 2.13.2 | `VER-2-13-2` | `https://codeload.github.com/freetype/freetype/tar.gz/refs/tags/VER-2-13-2` | `427201f5d5151670d05c1f5b45bef5dda1f2e7dd971ef54f0feaaa7ffd2ab90c` |
| Brotli 1.2.0 | `028fb5a23661f123017c060daa546b55cf4bde29` | Copied from `third_party/libjxl-0.12.0/third_party/brotli` | See `third_party/libjxl-0.12.0/QIP-VENDOR.md` |

Skia's BSD license is in `LICENSE`. The skcms module retains its license and
copyright headers. Expat's MIT license is in
`third_party/externals/expat/COPYING`. FreeType's license terms and notices are
in `third_party/externals/freetype/docs`; this build uses the FreeType License
(`FTL.TXT`). Brotli's MIT license is in `third_party/externals/brotli/LICENSE`.

The tree retains Skia's `include`, `src`, `gn`, SVG, resources, shaper, and
skcms modules, Expat's complete parser library, and FreeType's complete source
distribution. Unused Skia frontends and external dependencies are not copied.
FreeType 2.13.2 is the upstream release rather than the Chromium fork named
by Skia's `DEPS`. `third_party/externals/brotli` keeps only Brotli's decoder:
its `LICENSE`, `c/common`, `c/dec`, and the decoder headers from `c/include`.
It is the revision libjxl pins, newer than the one Skia's `DEPS` names.

## Target configuration

Skia m124 uses C++17 and works with the repository's pinned Emscripten 2.0.34
Clang and system libraries. `qip/args.gn` records the GN feature choices.
The checked manifest contains 597 translation units from the SVG dependency
closure, with the target's inherited defines and include paths.

The target is little-endian wasm32 with one thread and fixed memory. GPU
engines, PDF, animation, ICU, HarfBuzz, raster-image codecs, SVG font glyphs, and PNG
bitmap glyphs are disabled. It uses FreeType for caller-supplied fonts and
the primitive SkShaper for text. FreeType reads TrueType, OpenType, WOFF, and
WOFF2 data. WOFF uses FreeType's bundled zlib in `src/gzip`; WOFF2 uses the
Brotli decoder.

`tools/build-skia.py` compiles the manifest with LTO and archives its objects.
It records command hashes and header dependencies for incremental builds.
The adapter links that archive with the pinned C and C++ runtime libraries.
Binaryen produces the final checked `.wasm`.

Clang 14 auto-vectorization produces stray spans on complex paths in this
configuration. `SkScan_AAAPath.cpp`, `SkAnalyticEdge.cpp`, `SkEdgeBuilder.cpp`,
`SkEdgeClipper.cpp`, and `SkEdge.cpp` retain `-O2` with `-fno-vectorize` and
`-fno-slp-vectorize`. Other translation units retain normal optimization and
Wasm SIMD. The Tiger coverage test checks the observed failure. The adapter supplies a complete
reclaiming `malloc`/`calloc`/`realloc`/`free` family and `malloc_usable_size`.
Its C runtime sees an empty environment through `getenv`; locale queries
cannot read host variables.

## Local changes

- `third_party/freetype2/BUILD.gn` and its `ftoption.h` disable PNG bitmap
  glyphs and the libpng dependency.
- `src/base/SkSemaphore.cpp` traps if an OS semaphore wait or signal is
  reached. Uncontended atomic operations still use Skia's implementation.
- `src/core/SkStrikeCache.cpp` and `src/sksl/SkSLPool.cpp` use module globals
  in place of thread-local globals. This module has exactly one thread.
- `src/ports/SkDebug_stdio.cpp` discards debug output.
- `qip/SkOSFile_none.cpp` replaces the POSIX and stdio file ports with a
  port that rejects file operations. The manifest generator selects this port.
- `src/core/SkStream.cpp` and `src/core/SkData.cpp` reject filename factories.
  The adapter uses memory streams and a null SVG resource provider.
- FreeType's `src/base/ftsystem.c` rejects filename opens. `ftoption.h`
  disables environment properties. Its `ftstdlib.h`
  replaces setjmp recovery with a trap, because QIP hosts do not enable Wasm
  exception handling. Font validator failures and FreeType raster overflow
  therefore trap, and the host reports the run as failed. Fonts are
  caller-supplied, so a malformed font can reach this path.
- Expat's `xmlparse.c` uses a fixed nonzero fallback hash salt instead of
  host entropy. Skia's parser also supplies its own salt and stops parsing
  on entity declarations. Neither path reads host randomness or time. Its debug-level reader and
  diagnostic functions also omit host environment and stdio access.
- `src/sksl/SkSLString.cpp` uses C-locale `snprintf` and `strtod` instead of
  C++ locale streams. `modules/skshaper/src/SkShaper.cpp` uses language `und`
  instead of the host locale.
- The compiler defines `SK_DISABLE_LEGACY_PNG_WRITEBUFFER` to disable a
  legacy PNG serialization fallback when PNG encoders are absent.

Skia keeps module-lifetime singletons. The adapter initializes its arena and
constructors once, releases per-render storage, and purges Skia caches after
each call. It does not reset the arena under retained pointers.

## Regenerate the source manifest

Use a complete checkout of the pinned Skia revision and the pinned external
sources. Apply the local feature changes above. The GN used to derive this
manifest was revision `fe330c0ae1ec29db30b6f830e50771a335e071fb`, fetched by
Skia's `bin/fetch-gn` from the official Chromium tool archive.

Copy `qip/args.gn` to `out/qip/args.gn` in that checkout. Set
`skia_emsdk_dir` to the pinned SDK path. Generate the target description:

```sh
bin/gn gen out/qip
bin/gn desc out/qip '*' --format=json > /tmp/skia-targets.json
```

From the QIP repository, extract the source closure with this command:

```sh
python3 tools/skia-source-manifest.py /tmp/skia-targets.json \
  --root /path/to/skia \
  --output third_party/skia-m124/qip/sources.json
```

The checked manifest's `//third_party/brotli:brotli` group was written by
hand, because this tree's Brotli is newer than Skia's. It lists every `.c`
file in `c/common` and `c/dec`, including `dec/prefix.c` and
`dec/static_init.c`, which Skia's `third_party/brotli/BUILD.gn` predates.
Restore that group after regenerating.

Rebuild with `make -j test-svg-skia`. Check the final module for zero imports,
fixed memory, static ABI getters, and absence of `memory.grow`. Run
`make -j test` after a source or build change.
