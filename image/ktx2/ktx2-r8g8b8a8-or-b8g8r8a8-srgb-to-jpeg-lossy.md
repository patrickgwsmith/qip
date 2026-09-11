# RGBA8 or BGRA8 sRGB KTX2 to lossy JPEG

`ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jpeg-lossy.wasm` accepts either strict
8-bit sRGB KTX2 component order and encodes JPEG without a BMP intermediate.
It reads the top-down payload directly and composites straight alpha because
JPEG cannot store transparency.

The uniforms are `quality` from 0 through 100 (default 85), `subsample` from
0 through 2, and `background_color_rgb` as `0xRRGGBB` (default white).

```sh
./qip run \
  image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jpeg-lossy.wasm \
  -u quality=85 -u background_color_rgb=0xffffff \
  -i input.ktx2 -o output.jpg
```

Images are limited to 25,000,000 pixels and 8192 pixels on either axis. The
encoder uses mozjpeg 4.1.1 in fixed Wasm memory.
