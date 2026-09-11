# BMP B8G8R8A8 sRGB to JPEG

`bmp-b8g8r8a8-srgb-to-jpeg-lossy.wasm` encodes QIP's 32-bit BMP interchange format as
an 8-bit JPEG using MozJPEG 4.1.1. It accepts bottom-up and top-down BI_RGB BMPs
and BITMAPV5HEADER BGRA BMPs with the standard channel masks.

The encoder emits baseline sequential JPEG so its output can be consumed by
QIP's current `jpeg-to-bmp-b8g8r8a8-srgb.wasm` decoder. MozJPEG's trellis quantization
and optimized Huffman coding remain enabled. Progressive output can be added
after the decoder supports it.

Uniforms:

- `quality` is `1` through `100`, defaulting to `85`. Zero is clamped to one.
- `subsample` is `0` for 4:4:4, `1` for 4:2:2, or `2` for 4:2:0. The default is
  4:2:0.
- `background_color_rgb` is packed `0xRRGGBB`, defaulting to white. Explicit V5
  alpha is composited onto this color because JPEG cannot store transparency.
  BI_RGB's unused fourth byte is treated as opaque.

The component assumes the BMP pixels are already in sRGB. Run
`bmp-b8g8r8a8-icc-to-srgb.wasm` first when a BMP carries another ICC profile.

The fixed 512 MiB Wasm memory contains a 95.4 MiB input, 80 MiB output, and
336 MiB reclaiming MozJPEG arena. The component exports arena peak/live allocation
telemetry. MozJPEG cannot spill virtual coefficient arrays to files, call
`memory.grow`, or allocate outside this arena. Input is limited to 25 million
pixels with dimensions no larger than 8192 pixels.

A 5000×5000 development probe peaked at 286.3 MiB with the worst-case 4:4:4
setting. The 336 MiB arena leaves almost 50 MiB for MCU padding and allocator
fragmentation. MozJPEG's trellis pass needs image-wide coefficient arrays, so
the module must declare the complete 512 MiB even when encoding a small image.

This build uses C function tables, which compile to `call_indirect`. It follows
the normal fixed-memory, import-free QIP policy but does not pass the optional
strict profile that bans indirect calls.

```sh
make -j image/bmp/bmp-b8g8r8a8-srgb-to-jpeg-lossy.wasm
qip run -i image.bmp -o image.jpg -- \
  image/bmp/bmp-b8g8r8a8-srgb-to-jpeg-lossy.wasm -u quality=85 -u subsample=2
```

MozJPEG 4.1.1 is vendored under `third_party/mozjpeg-4.1.1`; see its
`QIP-VENDOR.md` and `LICENSE.md` for source provenance and license terms.
