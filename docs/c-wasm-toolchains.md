# Building C libraries as QIP components

QIP C components can use Emscripten's Clang and system libraries without using
Emscripten's browser runtime. Inspect the final `.wasm` imports, exports, memory
declaration, and instructions. The compiler name does not establish the
module's runtime requirements.

The libwebp encoders and the OpenJPEG decoder use this approach. They statically
link selected upstream C sources with Clang and `wasm-ld`, then run Binaryen
directly. They have no imports, export only their QIP interfaces and
diagnostics, and do not require JavaScript, WASI, a filesystem, or a dynamically
loaded library.

## The available build paths

| Path | What it buys | What it costs |
| --- | --- | --- |
| Zig | A compact freestanding toolchain and straightforward QIP ABI control | libwebp's upstream Wasm SIMD route uses Emscripten's SSE compatibility headers, so Zig's scalar build was substantially slower |
| `emcc` standalone | The simplest way to activate libwebp's translated SSE SIMD and select compatible system libraries | Emscripten 2.0.34 also exported its function table, `errno` accessor, and three stack helpers |
| Clang + `wasm-ld` | Explicit imports, exports, memory, libraries, and post-link passes | The recipe must supply the SIMD compatibility flags, sysroot libraries, linker limits, exports, and Binaryen features itself |

The direct Clang build was selected for `bmp-b8g8r8a8-srgb-to-webp-lossy.wasm`. On the 12 MP
photograph used during development it had the same encoding speed and produced
byte-identical WebP output as the standalone `emcc` build. It was about 362 KB
instead of 353 KB, but reduced the export surface from 31 entries to the 26
entries requested by the component.

The five removed exports were not browser dependencies:

- `__indirect_function_table` exposed the table used internally for C function
  pointers.
- `__errno_location` exposed C's `errno` address.
- `stackSave`, `stackRestore`, and `stackAlloc` supported Emscripten-generated
  JavaScript argument marshalling.

An export makes an internal value callable by the host. An import is a runtime
dependency that the host must provide. The earlier module had no imports and
was already a valid QIP component; direct linking gives it a narrower public
surface.

## What `emcc` was doing

Invoking Clang from the Emscripten SDK is not equivalent to replacing `emcc`
with `clang` in the command line. The libwebp build depended on four driver
behaviors.

First, `-msse4.1` is a driver-level compatibility feature for Wasm. Direct
Clang 14 ignores that option for a `wasm32` target. The QIP recipe explicitly
adds Emscripten's `include/compat` directory and defines the SSE feature macros
that select libwebp's SSE2 and SSE4.1 sources. Those headers lower the intrinsics
to WebAssembly SIMD.

Second, libwebp's CPU dispatcher checks `EMSCRIPTEN`, not only
`__EMSCRIPTEN__`, to treat compile-time SIMD support as available at runtime.
Omitting that definition produces a valid but effectively scalar module. In
the development benchmark it took about 3.1 seconds instead of about 1.8
seconds for 12 MP.

Third, Emscripten's normal optimized `memcpy` delegates copies of 512 bytes or
more to a JavaScript helper. Its standalone fallback deliberately traps if that
path is reached. Compiling and linking with `-mbulk-memory` lets LLVM lower
`memcpy` and `memset` operations to WebAssembly `memory.copy` and `memory.fill`
instead. This removes the JavaScript path without maintaining a replacement C
copy loop. The final libwebp module currently contains 149 `memory.copy` and 95
`memory.fill` instructions; QIP's strict profile accepts both bounded-memory
operations.

Finally, `emcc` chose and prepared its musl-derived C library, compiler runtime,
and standalone support library, then ran Binaryen. The Makefile now makes those
steps explicit:

- `embuilder.py --lto` prepares the pinned system libraries in a QIP-specific
  cache.
- Clang 14 compiles and LTO-links with `-nostdlib` and an explicit library
  list.
- `wasm-ld` receives every public export, the 64 KiB stack, and equal initial
  and maximum memory sizes.
- `wasm-opt -O3 --enable-simd --enable-bulk-memory` performs the post-link
  optimization and removes debug and producer metadata.

There is no direct-Clang equivalent of `-sFILESYSTEM=0`: that option controls
Emscripten's generated runtime. The direct build never links that runtime. A
zero-entry import section is the stronger artifact-level check.

## Treat the upstream build as configuration evidence

Many C libraries do not ship the configuration headers included by their `.c`
files. CMake or Autoconf generates them after probing the target. A
self-contained QIP build can check in those generated headers, but the values
must describe wasm32 rather than the developer's machine.

OpenJPEG is a compact example. The vendored `opj_config.h` records the upstream
version. `opj_config_private.h` deliberately leaves optional platform features
undefined for a little-endian, single-threaded wasm32 build. The Makefile also
defines `MUTEX_stub`, matching the fallback selected by OpenJPEG's own CMake
rules. This avoids accidentally compiling pthread or Win32 paths merely because
the host that prepared the source supports them.

Keep a short record beside the vendored code with:

- the upstream archive URL, version, and checksum;
- the license copied with the source;
- which headers were generated or tailored locally; and
- the target assumptions represented by those headers.

See `third_party/openjpeg-2.5.4/QIP-VENDOR.md` for the repository example. Do
not copy a native build directory wholesale. Its feature probes, absolute
paths, and cached compiler results are inputs from a different target.

## Vendor a coherent tree, compile a narrow source set

Vendoring and linking have different boundaries. Keep enough of the upstream
source tree to preserve license context, internal headers, and a reviewable
upgrade path. Compile only the closure needed by the component contract.

The JP2 component vendors OpenJPEG's complete `src/lib/openjp2` directory, but
the Makefile names only its decoder library sources. It does not build the
command-line applications or their optional PNG, TIFF, zlib, and LCMS
dependencies. This keeps the repository self-contained without turning unused
tools and formats into Wasm code or build prerequisites.

Start the source list from the public operation the adapter calls, resolve its
library-local symbols, and compare the selected files with the upstream library
target so core decoder sources are not missed. Do not remove a source merely
because one fixture did not reach it: format features often select code late at
runtime. Test a matrix of supported features before treating the set as
complete.

Run LTO after source selection to remove unreachable functions inside the
selected translation units. Do not compile every optional frontend and
dependency and expect LTO to repair the source boundary.

## Prefer memory callbacks to a virtual filesystem

An upstream library may expose both filename helpers and a stream API. Use the
stream API for a QIP Content component. The JP2 adapter implements OpenJPEG's
read, skip, and seek callbacks over the QIP input buffer, so the decoder never
needs `FILE`, WASI, or Emscripten's virtual filesystem.

Memory callbacks need the same review as a parser:

- reject seeks and skips outside the input;
- handle end-of-input exactly as the upstream callback contract specifies;
- check conversions between `size_t`, signed offsets, and Wasm's 32-bit
  pointers; and
- keep callback state inside the component invocation.

Do not stub file functions until the link succeeds and assume the path is dead.
Use `wasm-objdump` to verify zero imports, then exercise malformed and truncated
inputs so error paths cannot discover a missing host service.

## Replace allocation as a complete C contract

A monotonic bump allocator is attractive in a fixed-memory module, but it is
often a poor fit for a decoder. OpenJPEG allocates and frees many temporary
buffers and uses `realloc`; never reclaiming those buffers would size memory for
the sum of the whole decode rather than its peak live working set.

The JP2 adapter provides a fixed, reclaiming arena with C-compatible
`malloc`, `calloc`, `realloc`, and `free`. The build disables all four compiler
builtins:

```text
-fno-builtin-malloc
-fno-builtin-calloc
-fno-builtin-realloc
-fno-builtin-free
```

Disabling only `malloc` and `free` is incomplete. Without all four flags, the
optimizer can rewrite a call or apply assumptions that bypass the adapter's
bookkeeping.

A replacement allocator must preserve the behaviors its library relies on:
alignment, overflow checks, zero-filled `calloc`, data preservation across
`realloc`, `free(NULL)`, and a null return on out-of-memory. Test failure
paths as well as successful decoding.

Exporting integer telemetry made the fixed budget reviewable without adding
host imports. The OpenJPEG component reports peak live bytes, current live
bytes, allocation count, largest and failed allocation, frees, and unmatched
frees. Its 25 MP fixture used about 303 MiB of the 384 MiB arena and returned to
zero live bytes after cleanup.

This is separate from linear-memory reporting. The module declares 640 MiB of
fixed Wasm memory because its input, output, arena, stack, and static data must
all fit. `qip bench` reports that host-visible allocation; allocator telemetry
reports the smaller amount of arena storage actually live during the decode.
Record both when memory is a design constraint. See
[Benchmarking Components](/docs/benchmarking-components) for the measurement
workflow.

## What LTO can remove

The lossy component fixes `config.lossless` to zero, but libwebp's public
`WebPEncode` dispatcher receives a pointer and is large enough that ordinary
LTO does not specialize the call. Against the current build, replacing that
branch with a compile-time lossy path reduced the optimized artifact from
324,820 to 316,614 bytes (2.5%). Opaque and transparent outputs remained
byte-identical, with no consistent speed difference. An earlier experiment
that raised LLVM's inline threshold to encourage constant propagation made its
build about 32% larger instead.

Most VP8L code in the alpha-preserving lossy module is not dead. Lossy WebP
stores transparency in a separately lossless-compressed alpha plane. That
component keeps the public dispatcher because carrying a specialization for a
9 KB saving would add maintenance without changing its contract.

The separate opaque component makes a different tradeoff. It composites
declared BMP alpha before encoding, defines `WEBP_OPAQUE_ONLY` around the
lossless dispatcher branch, and replaces `alpha_enc.c` with four fixed opaque
entry points. LTO can then remove VP8L and its lossless DSP, producing a
179,625-byte module instead of the current 324,920 bytes. The guarded libwebp source change
does not affect ordinary builds; its larger size and memory saving justify the
small vendored patch for this deliberately narrower contract.

## Reproducing the build

The compiler is pinned because Emscripten 2.0.34/Clang 14 generated materially
faster libwebp Wasm SIMD than the newer Emscripten version tested during this
work.

```sh
mise install emsdk@2.0.34
make -j image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy.wasm
make -j image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy-opaque.wasm
```

The Makefile locates the SDK through `mise`, prepares the LTO sysroot libraries,
and keeps intermediate objects in the ignored
`tmp/qip-emcc-2.0.34-cache/` directory. The cache name follows the selected
`EMSDK_VERSION`, so different compiler versions do not share generated files.
Preparing a fresh cache took about one minute on the development machine.
Subsequent builds in the same checkout reuse it.

Inspect the artifact and exercise its runtime policy:

```sh
./qip comply image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy.wasm
wasm-objdump -x image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy.wasm
node --test test/bmp-b8g8r8a8-srgb-webp-lossy.mjs test/qip-wasm-policy.mjs
```

For the OpenJPEG decoder:

```sh
make -j image/jp2/jp2-to-bmp-b8g8r8a8-srgb.wasm
./qip comply image/jp2/jp2-to-bmp-b8g8r8a8-srgb.wasm
wasm-objdump -x image/jp2/jp2-to-bmp-b8g8r8a8-srgb.wasm
node --test test/jp2-bmp.mjs
```

For the MozJPEG encoder, CMake generates wasm32 configuration headers and a
static `jpeg-static` library in the same temporary Emscripten cache. The QIP
wrapper replaces allocation, destination I/O, environment lookup, and error
reporting; its output is a fixed memory slice rather than a `FILE` or an
Emscripten filesystem stream.

```sh
make -j image/bmp/bmp-b8g8r8a8-srgb-to-jpeg-lossy.wasm
./qip comply image/bmp/bmp-b8g8r8a8-srgb-to-jpeg-lossy.wasm
node --test test/bmp-b8g8r8a8-srgb-jpeg-lossy.mjs test/qip-wasm-policy.mjs
```

For a freestanding algorithm that does not need Emscripten's translated SIMD
headers or system libraries, Zig or a normal freestanding Clang build is less
fragile. Use the explicit Emscripten-Clang path when those facilities produce a
measured speed or size improvement. Re-test that improvement after upgrading
the SDK or upstream library because the recipe reproduces driver details that
can change between releases.
