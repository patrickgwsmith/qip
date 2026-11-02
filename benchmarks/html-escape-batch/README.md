# HTML escaping: batching pages across SIMD lanes

Does running one input per SIMD lane (16 pages per i8x16) speed up a
variable-length transform? This compares hand-written code shapes against
`text/html/html-escape.wasm`, called once per page. Every output is checked
byte for byte against the component.

- `escape_kernels.zig`: the prototype kernels (one page at a time with a lookup
  table, one page at a time with 16-byte clean-block copies, and 16 pages per
  vector, gathered or pre-interleaved).
- `html_escape_pages.wgsl`: the same work as a WebGPU compute shader, one
  invocation per page. `wgsl-to-wasm` doesn't accept it yet (it has a third
  storage buffer and writes outside `id.x`).
- `bench.mjs`: the Node benchmark. `webgpu-check.mjs`: runs the shader in Deno
  and checks it against the component.

## Run

From the repository root, after `make site-static`:

```sh
zig build-exe benchmarks/html-escape-batch/escape_kernels.zig -target wasm32-freestanding -O ReleaseFast -fstrip -fno-entry -rdynamic -mcpu=generic+simd128 -femit-bin=benchmarks/html-escape-batch/escape_kernels.wasm
node benchmarks/html-escape-batch/bench.mjs
deno run --allow-read --unstable-webgpu benchmarks/html-escape-batch/webgpu-check.mjs
```

## Results (Apple M5, Node 26, median ms, copies in and out included)

| Kernel | 158 HTML pages (4.7 MiB) | 261 markdown pages (2.0 MiB) |
| --- | ---: | ---: |
| `html-escape.wasm`, one call per page | 9.69 | 3.65 |
| Lookup table, one page at a time | 2.36 | 0.91 |
| 16-byte blocks, one page at a time | **1.37** | **0.42** |
| 16 pages per vector, gathered | 8.48 | 6.65 |
| 16 pages per vector, gathered, sorted by length | 6.16 | 3.58 |
| 16 pages per vector, pre-interleaved (untimed transpose), sorted | 5.13 | 3.01 |

The WGSL shader on Metal through Deno: all 158 pages match, but one dispatch
with readback takes about 50–60 ms.

Batching pages across lanes loses to plain SIMD within one page. Classifying
16 bytes at once is cheap, but each lane writes to its own output position,
and wasm SIMD has no scattered store, so every lane is extracted and stored on
its own. That's the scalar work plus the gather and the lanes left idle by
pages of different lengths. Within one page, most 16-byte blocks hold no
`& < > " '` and are copied with a single store.
