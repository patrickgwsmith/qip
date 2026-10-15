# WGSL compute examples

Shaders for `text/wgsl/wgsl-compute-to-wasm.wasm`. Each one compiles to a QIP
Content component that runs once per input element, and its `override`s
become uniforms. `test/wgsl-compute-to-wasm.mjs` checks every example.

```bash
qip run -i life.wgsl -o life.wasm ../wgsl-compute-to-wasm.wasm
qip run -i board.u32 -o next.u32 life.wasm -u width=64
```

| Shader | Element | What it does |
| --- | --- | --- |
| `life.wgsl` | u32 cell | One Game of Life generation on a wrapping `width`-wide grid. Feed the output back in for the next one. |
| `rgba8-premultiply.wgsl` | RGBA8 pixel as u32 | Premultiplies alpha using integer maths with exact rounding. |
| `byteswap32.wgsl` | u32 | Converts big-endian words to little-endian, or back. |
| `smooth3.wgsl` | f32 sample | 3-tap `[1 2 1] / 4` smoothing that reads neighbouring samples. |
| `stereo-mid-side.wgsl` | f32 sample, interleaved L/R | Converts L/R to mid/side and back (`k=1`), and can widen or narrow the stereo image. |
| `dither.wgsl` | f32 in [0, 1] | Quantizes to `levels` steps with hashed noise so gradients don't band. The output is the same on every run for a given `seed`. |
| `tonemap-aces.wgsl` | RGBA32F as vec4f | Applies `exposure`, then the Narkowicz ACES filmic curve. |
| `flip.wgsl` | RGBA32F as vec4f | Mirrors a `width`-wide image horizontally and/or vertically. |

The compiler doesn't support loops, so wider kernels come from running a
shader more than once, as with `smooth3` and `life`. Reading other elements is
allowed, and reads outside the buffer return 0.

## Vectorize compute invocations

Set the compiler's `vectorize_invocations` uniform to 1 to compile four
independent invocations together with SIMD. Set it on the compiler, rather
than on the generated shader component:

```bash
qip run -i smooth3.wgsl -o smooth3-vector.wasm \
  ../wgsl-compute-to-wasm.wasm -u vectorize_invocations=1
```

The option defaults to 0 and resets after each compilation. Existing SIMD
within one WGSL vector remains enabled in either mode. Uniform calculations
stay scalar; varying calculations use one SIMD register per WGSL component.
Branches use lane masks. The final partial batch uses the same SIMD function
with absent lanes masked out; optimized modules do not retain a scalar
function. Floating-point expressions keep their operation order.

The first implementation requires separate read-only input and read/write
output buffers. Stores must use `global_invocation_id.x` or a direct local
alias of it, and shaders must not read the output buffer. Other access
patterns, Tile kernels, and shaders that exceed the bounded optimization
workspace retain the original module. Optimized modules have a
`qip.vectorize_invocations` custom section containing the byte `4`; they keep
the same exports, buffer capacities, and uniforms as the scalar module.

Keep the option off when module size or compilation latency takes priority.
The four-invocation function can be larger, and simple shaders can be slower.
It is most useful for arithmetic-heavy kernels such as the demo's Perlin
noise. Measure on the intended engine and input before
enabling it by default.

To compare Perlin with identical output in wazero and warmed V8, build the
compiler and run the benchmark without competing CPU-heavy work:

```bash
make -j text/wgsl/wgsl-compute-to-wasm.wasm
node tools/benchmark-wgsl-invocations.mjs --runs 40
```

Run the commands from the repository root. The script compiles both modes
from the demo source, checks that vectorization was applied, and uses
`qip bench` and `qipx bench` to compare full Content calls with output checks.
It reports one, four, and eight octaves at 256×192. Use `--size 257x193` to
include a partial SIMD batch, or `--octaves 1,8` to choose other cases. Artifact
sizes, hashes, CPU, runtime, and temporary file paths are included in the
report.

Add `--baseline-compiler /path/to/previous-compiler.wasm` to compare the
previous vectorized output alongside the current scalar and vectorized
modules. The benchmark compiles identical source with both compiler artifacts.

## Perlin measurements

On 2026-10-15, two serial runs on an Apple M1 Max (macOS arm64) measured
256×192 pixels with 40 samples per module. Node.js 24.12.0 / V8
13.6.233.17-node.37 reused each instance after 30 warmups. Wazero 1.11.0 used
its normal fresh-instance boundary. Both include input/output copies and
`render`; the V8 boundary also applies uniforms. Compilation is separate.
The table shows the range of mean times across the two runs, rather than
minimum samples:

| Engine and boundary | Octaves | Scalar, ms | Four invocations, ms | Speedup |
| --- | ---: | ---: | ---: | ---: |
| V8, reused instance | 1 | 1.97–2.03 | 0.917–0.939 | 2.15–2.16× |
| V8, reused instance | 4 | 6.15–6.24 | 2.39 | 2.57–2.61× |
| V8, reused instance | 8 | 15.9–16.2 | 4.39–4.47 | 3.62× |
| wazero, fresh instance | 1 | 7.25–7.44 | 1.74–1.86 | 4.00–4.16× |
| wazero, fresh instance | 4 | 24.0–24.7 | 4.19–4.25 | 5.74–5.81× |
| wazero, fresh instance | 8 | 52.9–53.6 | 7.48–7.58 | 7.07× |

At eight octaves, V8 p95 was 16.5–16.6 ms scalar and 4.49–4.61 ms vectorized.
The source uses seed 7, time 2.3, and the other demo defaults. The zero-filled
RGBA32F input has SHA-256
`599c1bb5ffd4b87229a81958f33f1060821cd01cd7aa7ccafa0d862f4522f3f6`.
Perlin ignores these pixel values and uses their dimensions. Output matches
byte for byte between modes and engines; the eight-octave output SHA-256 is
`50d89b1d79f8bb7f58d7c3e2a1076aef7abbbb894fb888b65ee7096eaeb07e92`.
The benchmark script prints the hashes for the other cases.

The scalar module is 22,905 bytes; the vectorized module is 49,814 bytes.
Gzip sizes are about 6.4 KB scalar and 5.9 KB vectorized. Both allocate
2,162,688 bytes of fixed linear memory. The compiler itself grows from 32 to
36 fixed pages to retain the bounded compute IR and vectorization scratch
space. These results include uniform analysis, exact unsigned constant
division, predication of small divergent assignments, a bounded pool of
repeated constant splats, register aliases for vector components, and removal
of assignment masks outside divergent control flow.

The previous vectorizer retained the scalar function for tails and produced
90,573-byte modules (about 12.0 KB gzip). The current vectorizer removes that
function and uses a masked final batch. Together with the expression and mask
changes, this reduces raw module size by 45%. In the same two runs, the previous
eight-octave vectorized module took 6.66–6.69 ms in V8 and 10.0–10.1 ms in
wazero; the current module took 4.39–4.47 ms and 7.48–7.58 ms respectively.

These measurements do not establish a four-lane speedup for every shader or
engine. The browser's first render can also include lazy compilation, so
compare warmed runs when evaluating execution speed.
