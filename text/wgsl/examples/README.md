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
