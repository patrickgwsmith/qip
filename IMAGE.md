# Image Tiling Protocol (RGBA Filters)

This document describes the RGBA tiling protocol used by `qip image` (Go) and `image.html` (browser). It is intended for implementing future WebAssembly filter modules.

## Overview

- Filters operate on **tiles** of size **64x64** pixels.
- Pixel data is provided as **RGBA32Float** values in `[0, 1]`.
- Filters run **in-place**: they read from the input tile buffer and write results back to it.
- The host may optionally provide a **halo** (extra border pixels) when a filter exports a halo function.

## Required Exports

Every RGBA32Float filter module must export:

- `memory` (linear memory)
- `input_ptr() -> i32` (function) -> byte offset into `memory`
- `input_bytes_cap() -> i32` -> capacity in bytes of the input buffer
- `tile_rgba32float_64x64(x: f32, y: f32)` (function)

### Optional Exports

- `uniform_set_width_and_height(width: f32, height: f32)`
  - Called once per image before processing.
- `calculate_halo_px() -> i32`
  - If present, host enables halo mode and requests the halo size in pixels.
  - Returned value must be **>= 0**. Negative values are treated as 0 by the host.

## Tile Buffer Layout

The tile buffer is a **row-major** array of RGBA32Float values:

```
index = ((row * tileSpan) + col) * 4
R = buffer[index + 0]
G = buffer[index + 1]
B = buffer[index + 2]
A = buffer[index + 3]
```

- `tileSpan` is **64** when no halo is used.
- If halo is enabled, `tileSpan = 64 + 2 * halo`.
- The host writes the input tile into `memory` at `input_ptr`.
- The filter reads/writes in place in that buffer.

## Coordinates and Halo

- The host calls `tile_rgba32float_64x64(x, y)` once per tile.
- `x` and `y` are the **top-left pixel coordinates** of the **64x64 core** tile in the original image.
- If halo is used, the host passes **`x - halo`** and **`y - halo`** so that absolute pixel math remains consistent with the expanded buffer.

Halo usage:

- Halo tiles are filled by the host using **edge clamping** (replicate the nearest pixel beyond image boundaries).
- Filters that read neighbors (blur, edge detection, etc.) should export `calculate_halo_px` and handle `tileSpan > 64`.
- The host writes back **only the 64x64 core** (center of the tile) to the output.

## Capacity Requirements

Modules must size `memory` and `input_bytes_cap` to hold the largest tile they expect.

- Required bytes: `tileSpan * tileSpan * 4 * 4`
- Example: `halo=6 -> tileSpan=76 -> bytes=76*76*16=92416`

If the module uses internal scratch buffers, allocate enough memory and place them beyond the input buffer to avoid overlap.

## Precision Pipeline

- The host uses float32 throughout the pipeline when **any** stage requests a halo.
- Without halo, the host currently uses a per-tile pipeline that writes results back to bytes between stages.

## Alpha Handling

- Alpha is always provided.
- Unless the filter explicitly modifies alpha, it should preserve it.

## Filters in WGSL

A filter can be a WGSL pixel kernel instead of hand-written Wasm.
`text/wgsl/wgsl-compute-to-wasm.wasm` compiles it to a module with the exports
above, and each `override` becomes a uniform:

```wgsl
fn pixel(c: vec4f) -> vec4f {
  return vec4f(1.0 - c.rgb, c.a);
}
```

`make components-wgsl-wasm` builds `components/**/*.wgsl` this way, such as
`components/rgba/invert.wgsl`. Kernels cannot read tile coordinates.

A kernel reads a neighbor with `sample(dx, dy)`, as
`components/rgba/box-blur-3x3.wgsl` does. The offsets must be integer
literals or `const`s, so the compiler derives the halo from them and exports
`calculate_halo_px` and `uniform_set_width_and_height`. Samples are clamped to
the image, the same as the host's halo, so a module whose kernels sample gives
the same pixels as running each kernel as its own stage. An offset that
depends on a uniform, such as a blur radius, is not supported yet.

`text/wgsl/pixel-kernels.mjs` plans these kernels:

- `fusePixelKernels(sources)` joins consecutive kernels into one source that
  compiles to one module. Pixels stay f32 between the fused stages, and the
  host makes one tile pass for all of them, with a halo that is the sum of the
  kernels' halos. The output is bit for bit the same as running each stage in
  turn in f32. Each stage's names get an `s<i>_` prefix, so `brightness` in
  stage 0 becomes the uniform `s0_brightness`.
- `pixelKernelPasses(source)` groups the kernels into passes. Each kernel
  that samples starts a pass, and point kernels join the pass before them.
- `pixelKernelsToComputeShader(source)` wraps a kernel source in a WebGPU
  compute shader with one entry point per pass, `qip_pass0` and on, and one
  invocation per pixel. Dispatch them in order and swap `qip_src` and
  `qip_dst` between passes. If a kernel samples, set the `qip_width` and
  `qip_height` overrides to the image size. GPU output can differ from the
  Wasm output by about one ulp, because the GPU can fuse multiply-adds.

## Reference Implementation Notes

- `main.go` (Go) and `image.html` (browser) implement the host pipeline.
- `gaussian-blur.wat` shows a halo-aware filter with dynamic tile span and scratch buffers.
- `unsharp-mask.wat` shows a halo-aware filter that copies original data into scratch, blurs, then sharpens.
