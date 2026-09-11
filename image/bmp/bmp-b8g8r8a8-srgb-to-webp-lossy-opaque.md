# BMP B8G8R8A8 sRGB to opaque lossy WebP

`bmp-b8g8r8a8-srgb-to-webp-lossy-opaque.wasm` encodes photographs and other opaque BMPs as
lossy VP8 WebP. It accepts standard 24-bit `BI_RGB` BGR, legacy 32-bit
`BI_RGB` BGRX, and 32-bit `BITMAPV5HEADER` BGRA with the standard channel
masks. V5 alpha is composited over an opaque background before encoding;
legacy `BI_RGB` byte four is padding and is deliberately ignored.

The background defaults to white and is configurable as `0xRRGGBB`:

```sh
./qip run \
  --timeout-ms 180000 \
  --max-memory 469762048 \
  -i input.bmp -o output.webp -- \
  image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy-opaque.wasm \
  -u quality=95 -u method=4 -u sharp_yuv=1 -u low_memory=1 \
  -u background_color_rgb=0xffffff
```

The remaining defaults match the alpha-capable lossy component: quality 95,
method 4, SharpYUV enabled, low-memory mode enabled, and one encoder thread.
`quality` accepts 0--100, `method` accepts 0--6, and `sharp_yuv` and
`low_memory` accept 0 or 1. Background compositing uses straight alpha in
byte-encoded sRGB:

```text
result = (source * alpha + background * (255 - alpha) + 127) / 255
```

The input is disposable. A 24-bit payload is expanded backwards in place to
remove BMP row padding; 32-bit pixels are either marked opaque or composited
in place. Bottom-up rows are then reversed before the buffer is passed
directly as `WebPPicture.argb`, avoiding another full-image allocation.

The component supports 25,000,000 pixels with no dimension above 8192. Its
fixed initial and maximum memory are both 469,762,048 bytes (448 MiB), including
a 256 MiB coalescing arena, a 100 MiB input, a 64 MiB output, row scratch,
stack, and code. It contains no `memory.grow` instruction. A 5000x5000 opaque
photograph encoded in 7.55 seconds under Node on the development machine and
peaked at 212,595,008 live arena bytes, leaving about 53 MiB in the arena.

The 179,625-byte release artifact is 45% smaller than the current 324,920-byte
alpha-capable lossy component. The build defines `WEBP_OPAQUE_ONLY`, replaces
libwebp's alpha encoder entry points with fixed opaque stubs, and lets LTO
remove VP8L and its lossless DSP. Across five quality, method, SharpYUV, and
low-memory configurations, its opaque output was byte-identical to the
alpha-capable component. The specialization changes the contract rather than
the VP8 bitstream.

Allocator telemetry matches the other WebP components:

- `arena_peak_bytes()`
- `arena_allocation_count()`
- `arena_largest_allocation()`
- `arena_failed_allocation()`
- the free and per-allocation event counters

Use `bmp-b8g8r8a8-srgb-to-webp-lossy.wasm` when transparency must remain in the WebP. Use
`bmp-b8g8r8a8-srgb-to-webp-lossless.wasm` when RGB values, including RGB beneath transparent
pixels, must round-trip exactly.
