# BMP B8G8R8A8 sRGB to lossy WebP

`bmp-b8g8r8a8-srgb-to-webp-lossy.wasm` converts an uncompressed 32-bit BGRA BMP into a lossy
WebP. RGB is encoded with VP8 and, when present, transparency is preserved in
WebP's losslessly compressed alpha plane. Both legacy QIP BGRA and explicitly
masked `BITMAPV5HEADER` input are accepted. It statically links libwebp 1.6.0
and SharpYUV; it has no runtime imports or dynamic library dependency.

The release module is built by Emscripten 2.0.34's Clang 14 and `wasm-ld`
directly, with `-O3`, LTO, and libwebp's SSE2/SSE4.1 implementations lowered to
WebAssembly SIMD. This is the manual-source equivalent of libwebp's
`WEBP_ENABLE_SIMD=1` CMake option. The Emscripten SDK supplies its Wasm SIMD
compatibility headers and C sysroot, but no browser runtime or JavaScript glue
is linked. The resulting module has no host imports and only the exports named
by the component. LLVM bulk-memory lowering emits `memory.copy` and
`memory.fill` directly instead of linking a JavaScript-assisted `memcpy`. See
[Building C libraries as QIP components](../../../docs/c-wasm-toolchains.md)
for the compiler comparison and the direct-link responsibilities. Install the
pinned compiler with `mise install emsdk@2.0.34` before rebuilding.

The component is tuned for high-quality photographs:

- quality 95
- method 4
- sharp YUV conversion enabled
- libwebp low-memory mode enabled
- single-threaded encoding
- a direct fixed-capacity output writer

All four choices are uniforms: `quality` is 0–100, `method` is 0–6, and
`sharp_yuv` / `low_memory` accept 0 or 1. For transparent images, requested
method 6 is capped to 5. With exact alpha quality 100, libwebp method 6 enables
an exhaustive VP8L alpha search: on random 4K alpha it raised the arena peak
from 281 MB to 445 MB and time from 3.1 to 26.8 seconds. Opaque images still
use method 6 when requested.

```sh
./qip run \
  --timeout-ms 180000 \
  --max-memory 1275068416 \
  -i input.bmp -o output.webp -- \
  image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy.wasm \
  -u quality=95 -u method=4 -u sharp_yuv=1 -u low_memory=1
```

The module accepts B8G8R8A8 sRGB BMPs up to 25,000,000 pixels, with no dimension above
8192 pixels. This matches Cloudinary's 25 MP baseline image limit: 6000x4000
and 5000x5000 are accepted, while an 8000x6000 camera original must be resized
first. The input capacity includes 64 KiB for BMP headers and metadata, and the
output capacity is 64 MiB.

Its fixed linear memory is 19,456 WebAssembly pages (1,275,068,416 bytes, or
1.1875 GiB). Its initial and maximum declarations agree, and the module has no
`memory.grow` instruction. This contains a 960 MiB coalescing arena, the
maximum 100 MiB BMP input, the 64 MiB output writer, row scratch, code, and
stack.

The BMP input is disposable. After validating the header, the component moves
the pixel payload to an aligned base, flips bottom-up rows in place, and
exposes those pixels directly as `WebPPicture.argb`. This avoids a second
full-size ARGB copy. RGB beneath fully transparent pixels is not part of the
decoded lossy result; use the lossless component when those hidden RGB values
must round-trip exactly.

Allocator telemetry remains exported for measurements:

- `arena_peak_bytes()`
- `arena_allocation_count()`
- `arena_largest_allocation()`
- `arena_failed_allocation()`
- `arena_free_count()`
- `arena_free_null_count()`
- `arena_free_matched_count()`
- `arena_free_unmatched_count()`
- `arena_freed_bytes()`
- `arena_allocation_size(index)`
- `arena_allocation_event(index)`
- `arena_allocation_free_event(index)`

Encoding speed depends strongly on the Wasm runtime and sustained CPU clock.
On the development machine, the SIMD module encoded a 12 MP photograph in
about 2.2--3.6 seconds under Node's WebAssembly JIT; the former Zig scalar
build took 3.85--4.03 seconds. The output is byte-identical between those
builds and to native libwebp 1.6.0 with the same configuration.

The Go CLI's wazero interpreter/JIT path is substantially slower for this
calculation-heavy component, so the command example allows three minutes. The
timeout is a host policy rather than a component memory or image-size limit.

A 5000x5000 opaque photograph with the defaults took about 8.0 seconds under
Node and peaked at 212.60 MB of simultaneously live arena allocations.
Transparency invokes libwebp's VP8L alpha path and is more demanding:

| 25 MP alpha | Time | Arena peak | Output |
|---|---:|---:|---:|
| Opaque | 8.0 s | 212.60 MB | 9.34 MB |
| Binary checker | 3.4 s | 398.93 MB | 5.07 MB |
| Smooth gradient | 7.9 s | 442.67 MB | 9.32 MB |
| Random, photographic RGB | 10.4 s | 827.36 MB | 34.38 MB |
| Random RGBA | 14.1 s | 827.36 MB | 50.20 MB |

The former reset-only allocator failed on random 4K alpha. The current
first-fit coalescing free list reuses libwebp's VP8L temporaries and leaves
about 179 MB (22%) above the measured 25 MP peak. Opaque encodes make only
12--17 allocations; transparent cases made up to 154 in this sweep. All are
released before `WebPEncode()` returns, so libwebp keeps no allocator-owned
state between renders.

The build already uses whole-program LTO. Against the current alpha-preserving
build, forcing only the top-level lossless dispatcher branch away reduced the
artifact from 324,820 to 316,614 bytes (2.5%). Outputs were byte-identical for
opaque and transparent inputs, with no consistent speed difference. An earlier
opaque-only experiment reached 185,660 bytes because LTO could also remove
VP8L alpha compression, but that discarded WebP transparency and was rejected.
Aggressively raising LLVM's inline threshold instead made its build about 32%
larger. Preserving alpha therefore means the VP8L subset is a real dependency
rather than removable dead code.

libwebp is vendored under `third_party/libwebp-1.6.0`; its `COPYING` and
`PATENTS` files apply to that source.
