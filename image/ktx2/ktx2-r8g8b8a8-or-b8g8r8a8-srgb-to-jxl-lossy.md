# RGBA8 or BGRA8 sRGB KTX2 to lossy JPEG XL

`ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jxl-lossy.wasm` encodes a still 8-bit
sRGB KTX2 image with libjxl 0.12.0. It accepts the strict RGBA and BGRA
profiles and writes a bare JPEG XL codestream. Opaque input becomes RGB;
otherwise alpha is preserved while RGB is encoded at the selected distance.

```sh
./qip run image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jxl-lossy.wasm \
  -u distance=1 -u effort=5 -i input.ktx2 -o output.jxl
```

`distance` is libjxl's perceptual distance, from 0.1 to 15, and defaults to 1.
Smaller values retain more detail and usually produce larger files. Values
outside the range leave the previous setting unchanged. `effort` is 1 to 9
and defaults to 5. Higher effort can reduce size at the cost of encoding time.
The component keeps a single-threaded encoder; it does not start Wasm threads.

The input is disposable. The encoder packs fully opaque RGBA or BGRA pixels to
RGB in place. For other input it swaps BGRA to RGBA in place. The
`encoded_channel_count` export reports 3 or 4 after a call.

## One photo measurement

On the 3264 × 4928 `fixtures/dmytro-yarish-qpVLtOs5kag-unsplash.jpg`
photograph decoded to KTX2, one `qip run` call on an Apple Silicon Mac gave:

| Encoder | Time | JPEG XL bytes |
| --- | ---: | ---: |
| libjxl, distance 1 and effort 5 | 37.4 s | 2,683,206 |
| fjxl, default effort 2, lossless | 1.67 s | 17,974,789 |

These files have different image quality, so the sizes are not a compression
efficiency comparison. The lossy file decoded with both `djxl` and this repo's
jxl-rs component. The measurement includes QIP startup and data transfer.

## Build and limits

The component accepts at most 25,000,000 pixels and 8192 pixels on either
axis. It has a 100,000,224-byte input buffer, a 128 MiB output buffer, and a
448 MiB reclaiming arena. Fixed Wasm memory is 768 MiB. It has no imports and
does not use `memory.grow`. libjxl retains a small process-wide allocation
between calls; the arena reclaims other freed blocks. An allocation failure or
more than 8 MiB of retained arena allocations returns empty output. A C++
allocation failure can trap because the build has exceptions disabled.

The build uses Emscripten 6.0.3, Brotli, Highway, and skcms. All three library
dependencies are pinned in `third_party/libjxl-0.12.0/`. The module is larger
and slower to encode than the separate fjxl lossless component, which has a
different output contract: use fjxl when exact pixels and encoding speed are
the priorities. Use WebP or AVIF when the recipient does not support JPEG XL.

```sh
make -j image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jxl-lossy.wasm
node --test test/ktx2-jxl.mjs
```

[`jxl-to-ktx2-r8g8b8a8-srgb.wasm`](../jxl/jxl-to-ktx2-r8g8b8a8-srgb.md)
decodes this output to canonical RGBA8 sRGB KTX2.
