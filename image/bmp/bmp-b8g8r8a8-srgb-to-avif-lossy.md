# BMP B8G8R8A8 sRGB to AVIF

`bmp-b8g8r8a8-srgb-to-avif-lossy.wasm` converts an uncompressed 32-bit BGRA BMP into a
lossy AVIF. It accepts legacy `BI_RGB` BGRA and explicitly masked
`BITMAPV5HEADER` input, preserves transparency when any alpha byte is below
255, and writes an AVIF using libavif 1.4.1 with libaom 3.13.0. The component
is encoder-only: it does not contain an AVIF decoder, filesystem support,
JavaScript glue, or host imports.

The release module is built with the pinned Emscripten 2.0.34 Clang toolchain,
`-O3`, whole-program LTO, Wasm SIMD, and bulk-memory instructions. libaom is
configured for the generic Wasm target with the AV1 decoder, multithreading,
runtime CPU detection, WebM I/O, accounting, and inspection disabled. libavif
is configured with only its AOM encoder path; libyuv, SharpYUV, image I/O
frontends, apps, and tests are disabled. See
[Building C libraries as QIP components](../../../docs/c-wasm-toolchains.md)
for the direct-link responsibilities.

The component has one combined lossy contract rather than separate lossless
and lossy modules. AVIF's lossless mode would still need a separate policy:
lossless RGB requires YUV444 and a lossless AV1 setting, while the useful
photographic path normally uses lossy YUV conversion. Keeping this prototype
lossy avoids presenting `quality=100` as mathematically lossless; at the
default YUV420 setting it is not pixel lossless.

The exported uniforms are:

- `quality`: 0--100, default 70
- `quality_alpha`: 0--100, default 100
- `speed`: 0--10, default 8
- `subsample`: 0 for YUV420, 1 for YUV422, or 2 for YUV444; default 0

For example:

```sh
./qip run \
  --timeout-ms 180000 \
  --max-memory 1073741824 \
  -i input.bmp -o output.avif -- \
  image/bmp/bmp-b8g8r8a8-srgb-to-avif-lossy.wasm \
  -u quality=70 -u quality_alpha=100 -u speed=8 -u subsample=0
```

The input is disposable. After validating the BMP header, the component moves
the pixel payload to an aligned base, reverses bottom-up rows in place, and
passes those pixels directly to libavif. It avoids a second full-size BGRA
image. The input capacity is 12,000,000 pixels plus 64 KiB of BMP headers; no
dimension may exceed 8192 pixels. The output capacity is 64 MiB.

The module's fixed initial and maximum memory are both 1,073,741,824 bytes
(1 GiB), and it has no `memory.grow` instruction. This first working limit
includes a 768 MiB coalescing arena, a 45.8 MiB BGRA input buffer, a 64 MiB
output buffer, row scratch, code, and stack. The arena peak and failed
allocation counters are exported so the limit can be reduced or raised from
measurements rather than from codec estimates. A later 12 MP sweep should be
used before changing the 12 MP admission limit.

The module uses one AOM encoder thread. Its Wasm SIMD code is compiled into
the artifact, but the generic target does not perform runtime CPU detection.
This is suitable for Wasm SIMD-capable runtimes; a runtime that cannot execute
Wasm SIMD must use a different component build. The adapter replaces
Emscripten's setjmp/longjmp and optional stdio paths with QIP-local stubs so
the module remains freestanding and import-free. An encoder failure traps or
returns no output rather than calling a host service.

The vendored source and build configuration are recorded in
[`third_party/avif-qip-build.md`](../../../third_party/avif-qip-build.md).
Use the WebP components when WebP compatibility or substantially smaller
modules is more valuable than AVIF's compression ratio. Use a future lossless
AVIF component only when exact pixel round-tripping is a stated requirement.
