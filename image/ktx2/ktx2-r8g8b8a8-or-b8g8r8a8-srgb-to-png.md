# RGBA8 or BGRA8 sRGB KTX2 to PNG

`ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-png.wasm` encodes either of QIP's strict
8-bit sRGB KTX2 layouts as an 8-bit RGBA PNG. It accepts
`VK_FORMAT_R8G8B8A8_SRGB` or `VK_FORMAT_B8G8R8A8_SRGB` with one image, one
level, no supercompression, and explicit `KTXorientation=rd` metadata.

RGBA payload rows pass directly into PNG filtering. BGRA rows swap red and
blue while the encoder fills its bounded row buffer. The component preserves
alpha and RGB values beneath transparent pixels.

```sh
./qip run \
  image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-png.wasm \
  -i input.ktx2 -o output.png
```

The component uses the same adaptive scanline filters and bounded DEFLATE
implementation as `../bmp/bmp-to-png.wasm`. Images are limited to 25,000,000
pixels and 8192 pixels on either axis.
