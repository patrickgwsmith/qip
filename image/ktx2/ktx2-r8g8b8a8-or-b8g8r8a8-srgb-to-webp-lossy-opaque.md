# RGBA8 or BGRA8 sRGB KTX2 to opaque lossy WebP

`ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-webp-lossy-opaque.wasm` encodes photographs
and other opaque images as lossy VP8 WebP. It accepts either strict 8-bit sRGB
KTX2 component order (`VK_FORMAT_R8G8B8A8_SRGB` or `VK_FORMAT_B8G8R8A8_SRGB`).
Alpha is composited over an opaque background before encoding, so the output
never has an alpha channel.

The background defaults to white and is configurable as `0xRRGGBB`:

```sh
./qip run \
  image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-webp-lossy-opaque.wasm \
  -u quality=95 -u method=4 -u sharp_yuv=1 -u low_memory=1 \
  -u background_color_rgb=0xffffff \
  -i input.ktx2 -o output.webp
```

The defaults are quality 95, method 4, SharpYUV enabled, low-memory mode
enabled, and one encoder thread. `quality` accepts 0--100, `method` accepts
0--6, and `sharp_yuv` and `low_memory` accept 0 or 1. Background compositing
uses straight alpha in byte-encoded sRGB:

```text
result = (source * alpha + background * (255 - alpha) + 127) / 255
```

The input is disposable. The KTX2 payload is composited and reordered to BGRA
in place, then passed directly as `WebPPicture.argb` without another
full-image allocation.

Images are limited to 25,000,000 pixels and 8192 pixels on either axis. Fixed
initial and maximum memory are both 469,762,048 bytes (448 MiB), the same as
`bmp-b8g8r8a8-srgb-to-webp-lossy-opaque.wasm`. Like that component, the build
defines `WEBP_OPAQUE_ONLY` so LTO removes libwebp's VP8L alpha encoder. For
the same opaque pixels, its output is byte-identical to the BMP component.

Use `ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm` when transparency must remain in
the WebP.
