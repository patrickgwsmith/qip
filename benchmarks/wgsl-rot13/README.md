# WGSL ROT13: WebGPU against wasm

Can a byte transform written as a WGSL compute shader beat the CPU? This
benchmark runs ROT13 three ways on the same input and checks that every output
is identical:

- **WebGPU:** `rot13.wgsl`, dispatched in the host.
- **WGSL→wasm:** the same shader compiled by `text/wgsl/wgsl-to-wasm.wasm`,
  scalar and with `vectorize_invocations=1`.
- **Zig SIMD wasm:** `rot13_zig_simd.zig`, hand-written with 16-byte vectors.

ROT13 is a one-to-one byte map, so it is the easiest text transform to move to
a GPU. WGSL has no `u8`, so the shader packs four bytes into each `u32`.

## Run

From the repository root:

```sh
qip run -i benchmarks/wgsl-rot13/rot13.wgsl -o benchmarks/wgsl-rot13/rot13_wgsl.wasm text/wgsl/wgsl-to-wasm.wasm
qip run -i benchmarks/wgsl-rot13/rot13.wgsl -o benchmarks/wgsl-rot13/rot13_wgsl_vec4.wasm text/wgsl/wgsl-to-wasm.wasm -u vectorize_invocations=1
qip run -i benchmarks/wgsl-rot13/rot13_bytes.wgsl -o benchmarks/wgsl-rot13/rot13_bytes_wgsl.wasm text/wgsl/wgsl-to-wasm.wasm -u vectorize_invocations=1
zig build-exe benchmarks/wgsl-rot13/rot13_zig_simd.zig -target wasm32-freestanding -O ReleaseFast -fstrip -fno-entry -rdynamic -mcpu=generic+simd128 -femit-bin=benchmarks/wgsl-rot13/rot13_zig_simd.wasm

# Browser (the representative WebGPU numbers)
python3 benchmarks/wgsl-rot13/serve.py 4277
# then open http://127.0.0.1:4277/benchmarks/wgsl-rot13/bench.html?runs=30

# Deno
deno run --allow-read --unstable-webgpu benchmarks/wgsl-rot13/bench.mjs --runs=30
```

`serve.py` sends cross-origin isolation headers. Without them, Chrome rounds
`performance.now()` and GPU timestamps to 100 µs.

## Method

Each time is one request on warmed, reused resources, from input bytes in
JavaScript to output bytes in JavaScript:

- **wasm:** copy the input into memory, call `render`, copy the output out.
  Inputs above the 4 MiB component capacity run as 4 MiB requests.
- **WebGPU:** `writeBuffer`, one compute pass, copy to a staging buffer,
  `mapAsync`, copy the result out. Pipeline, buffers and bind groups are created
  once. Inputs above 16 MiB use one dispatch per 16 MiB slice, in one pass.
- **Kernel only:** the compute pass alone, from `timestamp-query`.

The "153 × 8 KiB pages" case is a batch: one GPU submission over all pages,
against 153 separate wasm `render` calls.

The input is the site's largest markdown pages, repeated. Each sample repeats
the call until it has run for at least 2 ms. Every output is compared with the
Zig output before timing.

## Results

Apple M5, 24 GB, macOS. HeadlessChrome 156 on Metal, cross-origin isolated, 30
samples per case. Mean ms.

| Input | Zig SIMD wasm | WGSL→wasm | WGSL→wasm vec4 | WebGPU end to end | WebGPU kernel only |
| --- | ---: | ---: | ---: | ---: | ---: |
| 4 KiB | 0.001 | 0.002 | 0.002 | 0.257 | <0.01 |
| 64 KiB | 0.007 | 0.034 | 0.021 | 0.416 | <0.01 |
| 1 MiB | 0.130 | 0.555 | 0.352 | 0.649 | <0.01 |
| 4 MiB | 0.468 | 2.277 | 1.470 | 1.406 | 0.059 |
| 153 × 8 KiB pages | 0.132 | 0.680 | 0.437 | 0.700 | 0.020 |
| 16 MiB | 1.842 | 9.245 | 5.940 | 4.273 | 0.354 |
| 64 MiB | 7.308 | 36.598 | 23.531 | 16.537 | 1.049 |
| 128 MiB | 13.897 | 73.651 | 47.125 | 32.910 | 2.084 |

Small kernel times are below Chrome's timestamp resolution.

In Deno 2.9.8 the wasm numbers are similar, but every WebGPU round trip costs
at least 13 ms, even an empty `submit` followed by `onSubmittedWorkDone`. That
is Deno's polling, not the GPU, so use the browser numbers.

## Findings

- **WebGPU never beats hand-written SIMD wasm end to end.** It is 2.3–5×
  slower from 1 MiB up, and 56–370× slower below that. A round trip costs about
  0.25 ms before any work is done.
- **The kernel is fast; the copies are not.** At 128 MiB the compute pass
  takes 2.1 ms (about 64 GB/s), 6.7× faster than Zig SIMD. The other 31 ms is
  upload, staging copy and readback. Unified memory does not remove these
  copies in WebGPU.
- **Batching does not help a memory-bound map.** 153 pages in one submission
  take 0.70 ms against 0.13 ms for 153 Zig calls.
- **WebGPU does beat the WGSL→wasm output** from 4 MiB up (1.4× faster than
  vec4 at 128 MiB). Hand-written SIMD is 3.4× faster than the vectorized WGSL,
  because it works on 16 bytes per `i8x16` operation. The WGSL works on four
  `u32` words and unpacks each byte with shifts and masks.

So a GPU can only win for text when the data stays on the GPU across several
stages, or when the work per byte is much higher than ROT13's.

## Follow-up: byte vectors in wgsl-to-wasm

`rot13_bytes.wgsl` is the same transform written with `vec4u`,
`unpack4xU8` and `pack4xU8`, one byte per lane. It is valid WebGPU WGSL and
gives the same bytes on WebGPU (Deno on Metal) as the wasm builds.

With `vectorize_invocations=1`, `wgsl-to-wasm` now compiles such a shader to
i8x16 operations on 16 bytes at a time. It first checks that 8-bit lanes give
the same stored bytes as WGSL's 32-bit arithmetic, by evaluating the shader
both ways for all 256 values of each input byte; if any byte differs it keeps
the scalar module. The same change loads and stores scalar elements at
`id.x` as whole v128s in the ordinary vectorized path.

Node 26.3 on the same machine, median ms, `node benchmarks/wgsl-rot13/bench-bytes.mjs`.
The vec4 column is the original `rot13_wgsl_vec4.wasm`; the next one is
`rot13.wgsl` rebuilt by the new compiler.

| Input | Zig SIMD | rot13.wgsl vec4 | rot13.wgsl vec4, v128 loads | rot13_bytes.wgsl i8x16 |
| --- | ---: | ---: | ---: | ---: |
| 64 KiB | 0.007 (1.00×) | 0.028 (3.85×) | 0.019 (2.69×) | 0.005 (0.72×) |
| 1 MiB | 0.087 (1.00×) | 0.374 (4.32×) | 0.269 (3.10×) | 0.063 (0.73×) |
| 4 MiB | 0.349 (1.00×) | 1.491 (4.27×) | 1.064 (3.05×) | 0.291 (0.83×) |

The i8x16 build runs in 0.7–0.9× the Zig time across repeated runs, so WGSL
written with byte vectors is as fast as hand-written SIMD here. It does not
change the GPU findings above.

## Limits

- One machine and one browser. Discrete GPUs have slower uploads over PCIe.
- Energy is not measured. On macOS that needs `sudo powermetrics`.
- The wasm side is a warmed, reused instance, as in `qipx bench`. A
  fresh-instance `qip bench` boundary adds instantiation to every request.
