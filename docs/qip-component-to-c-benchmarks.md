# QIP Component-to-C Runtime Benchmarks

These measurements compare current QIP generated C against the original Zig
source, wazero, V8, and WABT wasm2c at three boundaries where the host
architecture changes the result: a warmed CommonMark transform, a memory-heavy
image recipe, and a fresh-process CommonMark transform. Every implementation
produced byte-identical output before timing.

The results are a comparison of these implementations on one machine, not a
general ranking of WebAssembly engines. In particular, the hosts use different
instance and linear-memory allocation strategies.

## Questions These Benchmarks Answer

The project has three primary questions:

1. Can ahead-of-time translated components approach direct-native throughput
   while retaining WebAssembly's 32-bit linear-memory boundary, defined
   instruction semantics, and traps?
2. Can a precompiled native executable preserve WebAssembly behavior with much
   less startup latency than loading a general-purpose runtime?
3. Can a recipe reduce resident memory and intermediate copying by giving
   heterogeneous components exclusive, sequential access to one fixed
   workspace?

The third comparison is against separately composed native components that
retain their own scratch memory. A hand-written native program can implement
the same lifetime analysis and buffer reuse, so shared workspace is not a claim
to beat the theoretical native minimum. Doing that across several native
libraries is application-specific work: acquire and configure each library,
learn its allocation and lifetime rules, pass allocator callbacks or replace
allocation functions where supported, and reconcile APIs that were not
designed to share storage.

A QIP component moves that work to the component adaptation. For example,
`image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy.wasm` is not merely libwebp in another
file format. Its build and wrapper constrain libwebp to fixed memory, one
thread, no imports, and no external system or data access, then expose the same
Content lifecycle as other QIP components. A host does not need to learn
libwebp's allocator API to reuse its storage after an SVG renderer or before
another image transform.

The question is therefore whether one constrained component model can make
lifetime reuse the normal composition path. A recipe host can allocate one
workspace, give each component exclusive sequential access, and reclaim dirty
state through the same API regardless of the underlying parser, codec, or
library. The stricter execution model gives up library features such as
threads, dynamic memory growth, system integration, and direct access to
external data. In exchange, the host can establish resource ownership and
composition rules once rather than negotiate them separately with every
native dependency.

The same measurements answer several secondary questions:

- How much executable size does each translated component add, and when is
  that smaller than carrying a Wasm runtime?
- How much time belongs to address checks, dirty-page tracking, translation
  quality, compilation, instantiation, and host-buffer copies?
- Can generated C preserve every relevant Wasm trap without relying on C
  overflow, aliasing, alignment, or out-of-bounds behavior?
- Does a fixed, precompiled component set work on platforms where JIT
  compilation or writable-executable memory is unavailable or undesirable?
- Are the generated symbols, workspace ABI, and build outputs practical when
  an application links many components together?

Output equality is a prerequisite for all of these comparisons. Trap and limit
conformance require separate tests; a fast benchmark cannot demonstrate that
the generated C preserved the WebAssembly safety model.

## Test Machine And Boundaries

The measurements were collected on an Apple M5 MacBook Air with 10 cores and
24 GB RAM, running arm64 macOS 26.5.2:

- QIP used wazero 1.11.0.
- V8 used Node 26.3.0 with V8 14.6.
- WABT wasm2c was 1.0.41.
- Zig source was compiled by Zig 0.15.2.
- Generated C, wasm2c, and the C benchmark boundaries were compiled by Apple
  Clang 21.

## Workspace Memory At A Glance

The large-image recipe is the current case where the shared workspace changes
whole-process memory use enough to be operationally visible:

| Memory model | End RSS | Difference from shared workspace |
|---|---:|---:|
| QIP generated C, one shared workspace, in-place handoff | 131.7 MiB | — |
| WABT wasm2c, three memories, direct handoff | 194.6 MiB | +62.9 MiB / +48% |
| Node/V8, three memories, direct handoff | 262.1 MiB | +130.4 MiB / +99% |
| QIP generated C, three workspaces, external buffers | 259.6 MiB | +127.9 MiB / +97% |

The shared workspace reserves one 331.4 MiB Wasm-visible address range plus a
672-byte metadata trailer, but only 131.7 MiB is resident after repeated
recipes. Sparse virtual pages between the working set and trailer remain
untouched. The comparison is most useful for recipes with large intermediates:
small text transforms may leave most dedicated memories non-resident and show
little absolute RSS difference.

## Large-Image Recipe

Small text pipelines barely dirty their linear memories, so sparse dedicated
allocations can have little resident-memory cost. This image pipeline has a
64 MiB intermediate, giving workspace reuse and copy-free handoff enough data
to affect RSS. The fixture was generated once at 4096×4096 by
`text-to-path-svg-dejavu-sans-mono.wasm`, then the measured recipe ran:

1. SVG current-color replacement
2. SVG rasterization to BMP
3. BMP encoding to PNG

The 35,274-byte SVG produces a 67,108,918-byte intermediate BMP and a
438,762-byte PNG. Every row produced the same PNG with SHA-256
`c36b64d61e44559b15e95c139c60a45dbeb395823116b0ab5ca662f69dda48bd`.

| Runtime and memory model | Mean | p50 | p95 | After initialization | After first recipe | End |
|---|---:|---:|---:|---:|---:|---:|
| WABT wasm2c, guard pages, direct handoff | 645.7 ms | 645.9 ms | 647.1 ms | 1.5 MiB | 194.6 MiB | 194.6 MiB |
| Node/V8, direct handoff | 664.1 ms | 662.6 ms | 678.3 ms | 55.9 MiB | 261.7 MiB | 262.1 MiB |
| WABT wasm2c, explicit bounds, direct handoff | 1,008.4 ms | 1,008.6 ms | 1,008.9 ms | 1.5 MiB | 194.6 MiB | 194.7 MiB |
| QIP generated C, shared workspace, in-place handoff | 1,114.8 ms | 1,114.9 ms | 1,116.2 ms | 1.4 MiB | 131.5 MiB | 131.7 MiB |
| QIP generated C, shared workspace, external buffers | 1,125.8 ms | 1,117.3 ms | 1,152.2 ms | 1.5 MiB | 196.0 MiB | 196.2 MiB |
| QIP generated C, three workspaces, external buffers | 1,117.5 ms | 1,117.2 ms | 1,118.8 ms | 1.5 MiB | 259.2 MiB | 259.6 MiB |

The QIP in-place path reduces whole-process RSS by about 62.9 MiB, or 32%,
versus direct-handoff wasm2c and by about 130.4 MiB, or 50%, versus Node. Node
starts with a 55.9 MiB runtime baseline; subtracting each process's initial RSS
still leaves the QIP workspace about 37% below V8's incremental footprint.
QIP requests one 331.4 MiB linear-memory allocation, while Node and wasm2c
retain three memories totaling 437.9 MiB.

That memory saving has a throughput cost. Default guard-page wasm2c is 1.73×
faster and V8 is 1.68× faster than QIP generated C on this pipeline. With the
same explicit-bounds strategy, wasm2c is about 10.5% faster. The remaining gap
includes WABT's stronger stack-to-local lowering, QIP's write tracking, and the
workspace turnover between stages. Node and wasm2c retain three initialized
instances; the shared QIP allocation must clear the prior component's dirty
bytes, preserve the relocated input, and initialize the next component.

The copying generated-C rows isolate the workspace API change. In-place
handoff saves about 64.5 MiB, or 33%, versus the copying shared-workspace path
and about 127.9 MiB, or 49%, versus three dedicated generated-C workspaces. It
also avoids copying the 64 MiB BMP out to a host buffer and back into the PNG
component. Their timing remains in the same 1.11-second range; the small
differences are not evidence of a general throughput change.

The shared allocation requests 347,538,080 bytes: 347,537,408 bytes of
Wasm-visible memory and a 672-byte trailer. Accessing that trailer does not
touch the virtual pages between the current working set and the end of linear
memory. The RSS checkpoints confirm this: after one complete recipe, about
131.5 MiB was resident rather than the full 331.4 MiB linear memory.

The host performs the handoff explicitly. It checks the next input capacity,
uses `memmove` from the dynamic output offset to the next component's static
input offset, and calls the next `init`. That `init` preserves exactly the
relocated input while clearing other dirty bytes. No generated convenience
wrapper or external intermediate allocation is required.

V8 and wasm2c also hand off directly, but between different linear memories.

## Native Source And The Wasm Intermediary

CommonMark provides a useful source-level control because
`text/markdown/commonmark.0.31.2.zig` contains the complete parser.
Its native benchmark calls the same `renderMarkdown` implementation, uses the
same static scratch structures, and performs the same input and output copies
as the translated-C harnesses. This is not a comparison with a different
CommonMark library.

The table reports the mean of three two-second trials after 20 warmup renders,
except for the native `ReleaseSmall` row, which is one ten-second trial. The
29,178-byte `README.md` fixture produced the same 33,488-byte HTML with SHA-256
`b124324d432689bb61aa784b6bb08461a31b751d3a82b35e7d80882c9c9795b9`.

| Build path | Memory checks | Mean | p50 | p95 | Relative to native source at the same Zig mode |
|---|---|---:|---:|---:|---:|
| Zig source, `ReleaseFast` | direct native pointers and arrays | 0.118 ms | 0.115 ms | 0.129 ms | — |
| Zig source, `ReleaseSmall` | direct native pointers and arrays | 0.216 ms | 0.214 ms | 0.231 ms | 1.00× |
| `ReleaseSmall` Wasm → WABT wasm2c | guard pages | 0.250 ms | 0.248 ms | 0.265 ms | 1.16× |
| `ReleaseSmall` Wasm → WABT wasm2c | explicit bounds | 0.470 ms | 0.468 ms | 0.487 ms | 2.18× |
| `ReleaseSmall` Wasm → QIP generated C | explicit bounds and dirty-page tracking | 0.482 ms | 0.475 ms | 0.504 ms | 2.23× |

There is no single format tax in this result. Against a native build using the
same `ReleaseSmall` mode as the shipped Wasm, guard-page wasm2c adds 0.034 ms,
or 16%. Explicit checks add substantially more: bounds-checked wasm2c is 2.18×
the matched native time, while QIP generated C is 2.23×. QIP is within about
2.5% of bounds-checked wasm2c on this parser.

The fastest direct native build changes a second variable by using
`ReleaseFast`. It takes 0.118 ms, making guard-page wasm2c 2.12× slower,
bounds-checked wasm2c 3.99× slower, and QIP generated C 4.09× slower. Those
larger ratios describe the production artifacts a developer would actually
choose, but they combine the Wasm intermediary with the repository's decision
to compile the shipped Wasm using `ReleaseSmall`. About three quarters of the
guard-page difference disappears when both sides use `ReleaseSmall`.

The remaining work is visible in the generated code. Wasm keeps pointers as
32-bit offsets into linear memory. The C translations reconstruct addresses
for loads and stores and preserve Wasm traps; explicit-bounds builds check
those accesses. QIP also records dirty output pages so a shared workspace can
be cleared without making untouched memory resident. As a diagnostic only,
disabling dirty tracking reduced QIP's warmed mean from 0.482 ms to 0.418 ms,
about 13%. That mode clears the entire linear memory on turnover and raised
this small benchmark's RSS to about 16.4 MiB, so it is not the workspace
configuration QIP intends hosts to use.

Compiler choice did not explain the gap. Compiling the translated C through
Zig's Clang frontend instead of Apple Clang changed guard-page wasm2c from
about 0.250 ms to 0.258 ms and QIP generated C from about 0.482 ms to
0.487 ms. This is still one component on one CPU: parsers with different
load/store density can produce different ratios.

## Cold One-Shot Startup

The warmed image results describe a long-lived application. Command-line filters
also care about the time and memory required to start a fresh process, acquire
the component, transform one input, write the result, and exit. This benchmark
uses `README.md` as its CommonMark fixture and was inspired by the startup,
RSS, and binary-size comparison in
[Vercel's ScriptC README](https://github.com/vercel-labs/scriptc#performance).

Each row is 500 fresh processes after five unmeasured launches warmed the
filesystem cache. Every process consumed `README.md`, produced the same
33,488-byte output, wrote it to `/dev/null`, and exited. The Node and native
runners read standard input; `qip run` used its normal `-i README.md` path.
The direct source used Zig `ReleaseFast`; translated C used Apple Clang `-O3`.
The executables were dead-stripped and stripped of local symbols. RSS is the
mean of the per-process peak reported by `wait4`, not an observation after the
process had already exited.

| One-shot host | Mean | p50 | p95 | Peak RSS | Shipped command/payload |
|---|---:|---:|---:|---:|---:|
| Zig source, `ReleaseFast` | 1.076 ms | 1.071 ms | 1.140 ms | 1.75 MiB | 114.4 KiB executable |
| WABT wasm2c, guard pages | 1.257 ms | 1.238 ms | 1.356 ms | 1.73 MiB | 131.4 KiB executable |
| QIP generated C, explicit bounds | 1.415 ms | 1.410 ms | 1.484 ms | 1.72 MiB | 146.7 KiB executable |
| WABT wasm2c, explicit bounds | 1.445 ms | 1.440 ms | 1.507 ms | 1.75 MiB | 147.5 KiB executable |
| Node 26, Wasm read with `readFileSync` | 23.294 ms | 23.134 ms | 24.843 ms | 59.57 MiB | 47.3 KiB script + Wasm; 137.8 MiB Node binary |
| Node 26, static Wasm source import | 24.023 ms | 23.703 ms | 26.335 ms | 59.95 MiB | 47.1 KiB script + Wasm; 137.8 MiB Node binary |
| Node 26, base64 Wasm embedded in script | 24.326 ms | 23.850 ms | 27.121 ms | 59.00 MiB | 62.5 KiB script; 137.8 MiB Node binary |
| `qip run`, wazero | 34.322 ms | 33.961 ms | 36.996 ms | 49.74 MiB | 9.58 MiB CLI + 46.0 KiB Wasm |

Inlining this 47 KiB Wasm module does not improve Node startup. With warm
filesystem caches, avoiding one small file read saves less than parsing the
larger script and decoding base64 costs; the inline mean is 1.03 ms slower
than `readFileSync`. Node's static source-phase import is 0.73 ms slower in
this run. The choice should therefore follow packaging needs rather than an
expected startup win for a module this size.

Process startup and stdio hide much of the warmed execution gap. Guard-page
wasm2c adds 0.18 ms, or 17%, to the direct native source executable.
Generated C adds 0.34 ms, or 32%; bounds-checked wasm2c adds 0.37 ms, or 34%.
Generated C still completes the whole operation about 16× sooner than Node
and 24× sooner than `qip run`, with roughly 1.7 MiB peak RSS.

The size accounting has two valid views. A Node or QIP installation pays for
its runtime once and can execute many components, so its incremental
per-component payload remains the compact Wasm. A native application avoids
the runtime process and compilation work, but incorporates translated machine
code for each bundled component. The standalone native sizes above include
the CommonMark translation and its one-shot I/O harness; multiple generated
headers in one application can share the workspace ABI and surrounding
application code.

`qip bench` measured CommonMark's wazero compile at 14.56 ms, instantiation at
0.24 ms, and execution at 6.05 ms on the same fixture. Those internal phases
explain part, but not all, of the 34.32 ms `qip run` wall time; the external
measurement additionally includes Go process startup, CLI and host setup,
input/output, and shutdown.

## Reproducing

For a new source-level comparison, use the reusable driver:

```sh
tools/bench-qip-component-to-c-source.sh \
  --input README.md \
  --duration-ms 2000 \
  --trials 3 \
  --startup-runs 100 \
  text/markdown/commonmark.0.31.2.zig
```

The driver builds the source's normal `.wasm` target through the Makefile,
then produces seven rows:

- the original source compiled directly with Zig `ReleaseFast` and
  `ReleaseSmall`, or C `-O3` and `-Os`;
- QIP generated C;
- WABT wasm2c with guard pages;
- WABT wasm2c with explicit bounds;
- a reused Node/V8 instance; and
- QIP/wazero with its normal fresh-instance boundary.

It compares every output byte before printing a Markdown table. The table
includes warmed mean, p50, p95, ratio to direct native, warmed process RSS,
fresh-process latency and RSS, stripped compiled-executable size, Wasm
input/payload size, and the size of a shared runtime where applicable. The
speed ratios use Zig `ReleaseFast` or C `-O3` as the native baseline. A second
table reports compilation, initialization, and linear-memory measurements.
Warm rows average three trials by default. The build completes before
measurement, and timing runs execute serially.

The Markdown table is the command's standard output and progress is written to
standard error, so a report can be captured directly:

```sh
tools/bench-qip-component-to-c-source.sh \
  --input README.md \
  text/markdown/commonmark.0.31.2.zig \
  > /tmp/commonmark-native-matrix.md
```

The source-to-Wasm build remains in the Makefile, so components with custom
dependencies keep their production flags. Pass `--wasm path` when the artifact
does not share the source basename, and `--skip-build` to measure already-built
artifacts. WABT, Node.js, Zig for Zig sources, and a C11 compiler must be
installed. `--keep-temp` retains the generated headers, wasm2c source,
executables, raw JSON, and outputs for inspection.

Direct native code needs an adapter because QIP's Wasm ABI exposes 32-bit
linear-memory offsets rather than native pointers. Zig sources use:

```zig
pub const native_output_capacity: usize = OUTPUT_CAP;

pub fn nativeRender(input: []const u8, output: []u8) u32 {
    // Call the same implementation used by the exported Wasm render function.
}
```

For C, define these only for the benchmark build, normally behind
`QIP_NATIVE_BENCHMARK`:

```c
size_t qip_native_output_capacity(void);

uint32_t qip_native_render(
    const uint8_t *input,
    size_t input_size,
    uint8_t *output,
    size_t output_capacity);
```

The adapter must call the same algorithm as the Wasm export. Replacing it with
a platform library would compare implementations rather than measure the Wasm
intermediary.

Run the QIP boundary directly:

```sh
./qip bench -i README.md --benchtime=2s \
  text/markdown/commonmark.0.31.2.wasm
```

Run a parameterized Content recipe comparison with:

```sh
tools/bench-qip-component-to-c-recipe.sh \
  --input qip-logo.svg \
  image/svg+xml/svg-recolor-current-color.wasm \
  image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm \
  image/bmp/bmp-to-png.wasm
```

The driver validates the connections with `qip dry run`, obtains the reference
bytes from `qip run`, translates every module, and emits one table for shared
and dedicated QIP workspaces, wasm2c guard and bounds modes, Node/V8, and
warmed wazero. Pass `--keep-temp` to inspect the generated recipe C and raw JSON
measurements. Uniform arguments are not yet supported.

The underlying large-image recipe harnesses are:

- `test/bench-content-c-image-recipe.c` for the large-image copying comparison;
- `test/bench-content-c-workspace-recipe.c` for the copy-free large-image
  workspace;
- `test/bench-content-wasm2c-recipe.c` for warmed wasm2c pipelines, with
  `QIP_RECIPE_STEP_COUNT=3` and `QIP_RECIPE_DIRECT_HANDOFF=1`; and
- `tools/bench-content-node-recipe.mjs` for V8.

The one-shot harnesses are:

- `tools/bench-content-native-api.zig` and
  `test/bench-content-native-once.c` for the original Zig source;
- `test/bench-content-c-once.c` for generated C;
- `test/bench-content-wasm2c-once.c` for wasm2c;
- `tools/bench-process-startup.c` for fresh-process timing and RSS;
- `tools/bench-content-node-once.mjs` for `readFileSync`;
- `tools/bench-commonmark-node-import-once.mjs` for a static Wasm source
  import; and
- the output of `tools/make-content-node-inline.mjs` for base64-inline Wasm.

The warmed original-source harness is `tools/bench-content-native.zig`.
Compile it with the CommonMark source as its `component` module:

```sh
zig build-obj -O ReleaseFast -fstrip --dep component \
  -Mroot=tools/bench-content-native.zig \
  -O ReleaseFast \
  -Mcomponent=text/markdown/commonmark.0.31.2.zig \
  -femit-bin=/tmp/commonmark-native.o

cc /tmp/commonmark-native.o -o /tmp/commonmark-native
/tmp/commonmark-native README.md 2000 /tmp/commonmark-native.html
```

For the smaller one-shot executable, compile only the native parser API and
link it to the same stdio boundary used by the translated executables:

```sh
zig build-obj -O ReleaseFast -fstrip --dep component \
  -Mroot=tools/bench-content-native-api.zig \
  -O ReleaseFast \
  -Mcomponent=text/markdown/commonmark.0.31.2.zig \
  -femit-bin=/tmp/commonmark-native-api.o

cc -std=c11 -O3 -DNDEBUG \
  test/bench-content-native-once.c \
  /tmp/commonmark-native-api.o \
  -Wl,-dead_strip \
  -o /tmp/commonmark-native-once
```

Generate the QIP C header with:

```sh
./qip run \
  -i text/markdown/commonmark.0.31.2.wasm \
  -o /tmp/commonmark-qip.h \
  application/wasm/qip-component-to-c.wasm

cc -std=c11 -O3 -DNDEBUG \
  -DQIP_WASM_GENERATED_HEADER='"/tmp/commonmark-qip.h"' \
  test/bench-content-c-once.c -lm -o /tmp/commonmark-qip
```

Generate WABT C once:

```sh
wasm2c -n qipbench \
  text/markdown/commonmark.0.31.2.wasm \
  -o /tmp/commonmark-wasm2c.c
```

Compile `test/bench-content-wasm2c-once.c`, the generated source, and WABT's
`wasm-rt-impl.c` and `wasm-rt-mem-impl.c` with one of these configurations:

```sh
# 64-bit default: mmap allocation and guard-page checks.
cc -std=c11 -O3 -DNDEBUG ...

# Explicit checks, retaining mmap allocation.
cc -std=c11 -O3 -DNDEBUG \
  -DWASM_RT_MEMCHECK_BOUNDS_CHECK=1 ...
```

Pass the same macros to the generated wasm2c source and every WABT runtime
translation unit.
The harness reports the resulting `allocation` and `memcheck` modes in its JSON
output.

These are performance tools, not timing assertions in the test suite. Always
compare output bytes before interpreting a speed difference.
