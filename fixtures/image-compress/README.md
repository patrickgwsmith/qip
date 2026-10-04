# Image compressor fixtures

Small inputs for `test/image-compress-ktx2.mjs`, one per format that the
image compressor accepts.

- `red-zeppelin-320x240.png` — `../red-zeppelin-oiqNzA5Fqso-unsplash.jpg`
  resized to 320x240 with ImageMagick, opaque 8-bit RGB.
- `red-zeppelin-320x240-progressive.jpg` — the same pixels as a progressive
  JPEG (ImageMagick, quality 85).
- `red-zeppelin-320x240.webp` — the same pixels encoded by
  `ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm` at quality 80.
- `red-zeppelin-320x240.avif` — the same pixels encoded by
  `ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-avif-lossy.wasm` at quality 70.
- `transparent-radial-160x120.png` — an ImageMagick radial gradient that fades
  from opaque blue to fully transparent, 8-bit RGBA.
- `transparent-radial-160x120.webp` — the same pixels encoded by
  `ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm` at quality 80, with alpha.

The photograph is from [Red Zeppelin on Unsplash](https://unsplash.com/photos/oiqNzA5Fqso).
