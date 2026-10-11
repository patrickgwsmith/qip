# RGBA8 or BGRA8 sRGB KTX2 to lossless JPEG XL

`ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jxl-lossless.wasm` encodes 8-bit sRGB KTX2
as lossless JPEG XL with fjxl, the single-file fast lossless encoder from
libjxl 0.12.0 (`lib/jxl/enc_fast_lossless.cc`). It accepts either strict 8-bit
sRGB KTX2 component order (`VK_FORMAT_R8G8B8A8_SRGB` or
`VK_FORMAT_B8G8R8A8_SRGB`). The output is a bare JPEG XL codestream that
declares sRGB and decodes to the same bytes, including RGB under fully
transparent pixels.

```sh
./qip run \
  image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jxl-lossless.wasm \
  -u effort=2 \
  -i input.ktx2 -o output.jxl
```

`effort` accepts 0--127 and defaults to 2, the default of libjxl's
`fast_lossless` tool. Values below 2 skip palette detection. Higher values
sample more rows when the encoder builds its entropy codes. On photographs,
the size gain past 2 is small: effort 127 made a 16 MP photograph 0.01%
smaller and took 1.6 times as long.

The input is disposable. If every alpha byte is 255, the encoder packs the
payload to RGB in place and writes a JPEG XL file without an alpha channel.
Otherwise it swaps BGRA to RGBA in place when necessary. Both paths avoid an
image-sized copy. The `encoded_channel_count` export reports 3 or 4 after a
render call.

## Size and speed

fjxl trades compression for speed. These measurements used one Node.js 26
thread on an Apple Silicon Mac and a 3264 × 4928 (16.1 MP) opaque photograph:

| Encoder | Time | Output |
| --- | --- | --- |
| This component, effort 2 | 0.18 s | 17.97 MB |
| `ktx2-…-to-webp-lossless.wasm`, level 1 | 2.5 s | 17.57 MB |
| `ktx2-…-to-webp-lossless.wasm`, level 6 (default) | 5.9 s | 16.77 MB |
| `ktx2-…-to-png.wasm` | 4.8 s | 34.38 MB |
| Native `cjxl -d 0 -e 7` (libjxl 0.12, 10 threads) | not comparable | 15.00 MB |

A 5000 × 5000 image took 0.28 s and used 143 MiB of the encoder arena. Use
WebP lossless when browser support matters more than encoding time. Use the
full libjxl encoder outside QIP when the smallest JPEG XL file matters.

## Build and limits

Images are limited to 25,000,000 pixels and 8192 pixels on either axis. The
module has fixed initial and maximum memory of 738,197,504 bytes (704 MiB): a
100 MB input buffer, a 128 MiB output buffer and a 448 MiB reclaiming arena
for fjxl's `malloc`, `free` and C++ allocations. An arena allocation failure
returns empty output. A failure inside a C++ container traps, because the
module is built without exceptions; the host then discards the instance.

fjxl has AVX2, AVX-512 and NEON paths, but no WebAssembly SIMD path, so the
module uses its portable scalar code. The build compiles fjxl as C++17 with
Emscripten 2.0.34's Clang and the no-exception libc++, then links with
`wasm-ld` directly in the same way as the ThorVG rasterizer. The module has no
imports and does not use `memory.grow`.

```sh
make image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jxl-lossless.wasm
node --test test/ktx2-jxl.mjs
```

Decode the output with
[`jxl-to-ktx2-r8g8b8a8-srgb.wasm`](../jxl/jxl-to-ktx2-r8g8b8a8-srgb.md).
