# PNG to 32-bit BGRA BMP

`png-to-bmp-b8g8r8a8-srgb.wasm` converts non-interlaced, 8-bit PNG images to
bottom-up B8G8R8A8 sRGB BMP. It accepts grayscale, grayscale-alpha, RGB, RGBA, and
palette PNGs. It rejects Adam7 interlacing, 16-bit channels, unknown critical
chunks, invalid chunk CRCs, and invalid zlib checksums.

The decoder accepts compressed input up to 64 MiB and decoded images up to
25,000,000 pixels, with neither dimension above 8192 pixels.

## Fixed batches

The input and output follow QIP's ordinary whole-value contract. Internally,
the decoder avoids retaining a second decoded image:

1. It validates the PNG and compacts IDAT payloads inside the disposable input
   buffer.
2. DEFLATE emits batches targeting 1 MiB and aligned to complete scanlines.
3. Each batch is checksummed, unfiltered, converted to BGRA, and written
   directly to its final BMP rows.

The batch size is the `DECODE_BATCH_TARGET` compile-time constant. A separate
32 KiB history preserves DEFLATE back-references across batches. This is one
synchronous `render` call rather than an externally resumable decoder.

At the 25 MP ceiling, the module allocates about 162 MiB of fixed Wasm memory:
64 MiB input, about 95.4 MiB output, a 1 MiB batch, and small history, row, and
Huffman buffers.

## SIMD fork

`png-to-bmp-b8g8r8a8-srgb-simd.wasm` shares the parser, inflater, and batching policy
but is compiled with Wasm `simd128`, `ReleaseFast`, and explicit debug-symbol
stripping. It vectorizes RGB and RGBA conversion and the PNG `Up` filter. Other
filters retain the scalar reconstruction path.

On the development machine, using stitched 5000×5000 photographs:

| 25 MP input | Whole-image scalar | Batched scalar | Batched SIMD |
|---|---:|---:|---:|
| RGB, Paeth rows | 3.03 s | 3.21 s | 2.37 s |
| RGBA, Paeth rows | 3.57 s | 3.80 s | 2.87 s |
| RGB, Up rows | 2.87 s | 3.01 s | 1.19 s |
| Fixed Wasm memory | 319.9 MiB | 161.6 MiB | 161.6 MiB |

All variants produced byte-identical 100,000,054-byte BMP output. SIMD support
is the compatibility tradeoff; use the scalar component where the host only
accepts baseline Wasm instructions. The stripped SIMD artifact is about 12.5
KiB raw or 6.1 KiB gzipped.
