# BMP to lossless WebP

`bmp-b8g8r8a8-srgb-to-webp-lossless.wasm` converts an uncompressed 32-bit BGRA BMP into a
lossless VP8L WebP. It statically links the VP8L portion of libwebp 1.6.0 and
has no imports, runtime dependency, or `memory.grow` instruction.

The BMP alpha byte is meaningful in this component, matching the B8G8R8A8 sRGB BMPs
produced elsewhere in this repository. Alpha and RGB values beneath completely
transparent pixels are preserved: libwebp's `exact` option is always enabled.
Explicitly masked `BITMAPV5HEADER` input is accepted as well. Use the opaque
lossy component when legacy `BI_RGB` byte four is padding rather than alpha.

The `level` uniform selects libwebp's lossless efficiency preset from 0 through
9. Level 6 is the default and is a good size/speed tradeoff; level 9 performs a
more exhaustive search for the smallest output without changing decoded
pixels.

```sh
./qip run \
  --timeout-ms 180000 \
  --max-memory 1610612736 \
  -i input.bmp -o output.webp -- \
  image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossless.wasm -u level=6
```

The component accepts B8G8R8A8 sRGB BMPs up to 25,000,000 pixels, with no dimension
above 8192 pixels. Its input capacity includes 64 KiB for BMP headers and
metadata; its output capacity is 128 MiB.

Its initial and maximum memory are both 24,576 WebAssembly pages
(1,610,612,736 bytes, or 1.5 GiB). That ceiling contains:

- a 1.25 GiB encoder arena;
- the maximum 100,065,536-byte BMP input;
- the 128 MiB output writer; and
- row scratch, allocator metadata, code, and stack.

VP8L makes and releases hundreds of temporary allocations at high effort. The
module therefore uses a first-fit, coalescing free-list allocator backed by a
fixed arena. It has 16-byte block headers, splits free blocks on allocation,
and merges adjacent blocks on `free()`. The arena is reset before every render.
It never requests host memory and libwebp keeps no allocations after encoding
returns.

Allocator telemetry is available through exports including allocation sizes,
arena offsets, allocation/free event numbers, and free-list search counts.
`arena_peak_bytes()` reports simultaneously live payload bytes, not cumulative
allocation traffic.

The observed allocation traces do not justify dedicated pools or size-class
bins. A 25 MP level-6 encode made 34 allocations of 12,500,012 bytes, all live
at once. Its 681.75 MB peak live payload occupied a 688.84 MB arena span, so
fragmentation added about 7.1 MB (1.0%). Exact-size pools sized for maximum
concurrency would instead reserve 697.53 MB because different allocation sizes
peak during different phases.

The more allocation-heavy level-9 trace reached 108.22 MB of live payload and
a 113.51 MB span on a 2 MP image. Exact-size pools would reserve 187.23 MB. Its
582 allocations required 21,020 first-fit block inspections, with at most 80
for one allocation; that search work is negligible beside a roughly 15-second
encode. Small allocations are also too little traffic to matter: allocations
up to 4 KiB totalled about 187 KiB in that trace. Power-of-two rounding through
64 KiB added only about 11 KiB at peak, but provided no memory saving; rounding
every allocation to a power of two increased peak live storage to 156.28 MB.

For these workloads, the fixed-arena coalescing free list uses less memory than
static pools and is simple enough to keep. Revisit bins, a double-ended arena,
or a general allocator only if a future libwebp version materially increases
search counts or the gap between peak live payload and occupied arena span.

Resolution and content sweeps show which parts of this result are stable. On
the photographic fixtures, cropping one row, one column, or both retained the
same 34 dominant image-sized allocations. Sparse low-bit noise also left the
allocation layout essentially unchanged. At 25 MP, these perturbations moved
peak live payload by less than 0.1 MB at a fixed pixel count, while output size
changed from 28.92 MB to as much as 32.56 MB. A one-column crop was the only
notable count change, from 138 to 132 allocations, without a meaningful change
to peak memory or fragmentation.

Allocation demand does depend substantially on image structure, however:

| 25 MP input | Allocations | Peak live | Arena span | Output |
|---|---:|---:|---:|---:|
| Solid color | 86 | 231.31 MB | 231.31 MB | 1.0 KiB |
| Smooth gradient | 143 | 531.37 MB | 531.37 MB | 69.5 KiB |
| Photograph | 138 | 681.75 MB | 688.84 MB | 28.92 MB |
| Fine textured bands | 163 | 731.38 MB | 731.38 MB | 4.19 MB |
| Pseudorandom RGB | 104 | 900.07 MB | 900.07 MB | 75.00 MB |

One-pixel dimension jitter at approximately 2, 8.3, 12.2, and 25 MP changed
the exact allocation count but kept peak storage closely tied to pixel count.
For example, four 25 MP gradient shapes from 5000x5000 through 8192x3051 all
fell between 531.27 and 531.37 MB. This supports retaining a conservative fixed
ceiling: the current 1.25 GiB arena has about 442 MB of headroom over the most
demanding 25 MP case in this sweep, rather than assuming the photographic trace
is a universal peak.

Development measurements under Node on an Apple M5 illustrate the level
tradeoff:

| Input | Level | Time | Encoder peak | Output |
|---|---:|---:|---:|---:|
| 12 MP photograph | 6 | 4.4 s | 435 MB | 16.26 MB |
| 12 MP photograph | 9 | 24.7 s | 555 MB | 16.20 MB |
| 25 MP photograph | 6 | 9.9 s | 682 MB | 28.92 MB |
| 25 MP photograph | 9 | 71.9 s | 1.15 GB | 28.56 MB |

The module calls the pinned internal `VP8LEncodeImage` entry point rather than
libwebp's public lossy/lossless dispatcher. This lets LTO remove the VP8 encoder
and SharpYUV, reducing the artifact to about 127 KB. A libwebp upgrade must
therefore revalidate this call boundary as well as output correctness and
memory measurements.

libwebp is vendored under `third_party/libwebp-1.6.0`; its `COPYING` and
`PATENTS` files apply.
