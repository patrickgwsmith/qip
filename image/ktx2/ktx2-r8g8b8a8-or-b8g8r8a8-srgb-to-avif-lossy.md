# RGBA8 or BGRA8 sRGB KTX2 to lossy AVIF

`ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-avif-lossy.wasm` encodes either strict
8-bit sRGB KTX2 component order as AVIF. libavif reads the top-down payload in
place as RGBA or BGRA, so the component does not reverse rows, move the image,
or swap channels.

The uniforms match the BMP AVIF encoder:

- `quality`: 0 through 100; default 70
- `quality_alpha`: 0 through 100; default 100
- `speed`: 0 through 10; default 8
- `subsample`: 0 for 4:2:0, 1 for 4:2:2, or 2 for 4:4:4; default 0

```sh
./qip run \
  image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-avif-lossy.wasm \
  '?quality=80&speed=8&subsample=0' \
  -i input.ktx2 -o output.avif
```

The component preserves alpha when the source contains transparency and omits
the alpha encode when every alpha byte is 255. Images are limited to
12,000,000 pixels and 8192 pixels on either axis. Encoding uses libavif 1.4.1
with libaom 3.13.0 in one thread and fixed 1 GiB Wasm memory.
