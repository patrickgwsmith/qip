# WebP to 32-bit BGRA BMP

`webp-to-bmp-b8g8r8a8-srgb.wasm` decodes a static lossy or lossless WebP into a
top-down, uncompressed 32-bit BGRA BMP. It statically links the decoder half of
libwebp 1.6.0 with its SSE2/SSE4.1 paths lowered to WebAssembly SIMD.

The BMP is a useful interchange format inside QIP. Its pixels can flow into
the existing PNG, ICO, WebP, palette, metrics, and image-processing components
without giving the host a separate pixel-buffer ABI.

```bash
qip run image/webp/webp-to-bmp-b8g8r8a8-srgb.wasm \
  < input.webp > output.bmp

qip run image/webp/webp-to-bmp-b8g8r8a8-srgb.wasm \
  image/bmp/bmp-to-png.wasm \
  < input.webp > output.png
```

The component accepts WebP files up to 64 MiB and images up to 25,000,000
pixels, with neither dimension above 8192 pixels. It rejects animated WebP
rather than silently selecting a frame.
Metadata such as ICC, EXIF, and XMP is not copied into the BMP.

The module reserves 448 MiB of fixed Wasm memory: 64 MiB for input, about
95.4 MiB for decoded pixels and the BMP header, and 256 MiB for libwebp's
reclaiming arena. It does not import memory or use `memory.grow`. Arena
telemetry exports make allocation regressions visible in tests and benchmarks.

The decoder core is vendored under `third_party/libwebp-1.6.0/src/dec`.
libwebp's `COPYING` file applies to those sources.
