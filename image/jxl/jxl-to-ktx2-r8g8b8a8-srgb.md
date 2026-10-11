# JPEG XL to canonical RGBA8 sRGB KTX2

`jxl-to-ktx2-r8g8b8a8-srgb.wasm` decodes one still JPEG XL image into QIP's
canonical `VK_FORMAT_R8G8B8A8_SRGB` KTX2 profile. It uses jxl-rs (the `jxl`
crate, version 0.7.4), the Rust decoder that Chromium and Firefox use for
JPEG XL. jxl-rs writes top-down RGBA rows directly into the KTX2 payload.

```sh
./qip run \
  image/jxl/jxl-to-ktx2-r8g8b8a8-srgb.wasm \
  -i input.jxl -o output.ktx2
```

The component accepts bare codestreams and ISOBMFF containers, lossless and
lossy (VarDCT) images, grayscale, alpha, and bit depths other than 8. It
applies the image's orientation. Grayscale becomes equal RGB channels, and
images without alpha get alpha 255. Lossy 8-bit output is dithered as in
libjxl; on a 16 MP test image every channel was within 1% of `djxl` output.

## Rejected input

- Animations. Use a tool that can choose a frame.
- Colour spaces other than sRGB. jxl-rs 0.7.4 has no colour management and
  no API to request sRGB output, so the component accepts only images whose
  output encoding is sRGB primaries with the sRGB transfer function and a D65
  white point. Images that declare Display P3, BT.2100, custom primaries, PQ,
  HLG or an ICC profile are rejected, whether they are lossy or lossless.
  `cjxl` usually stores an RGB ICC profile from a lossy source as custom
  primaries, so such files are rejected too.
- Truncated or malformed files, and images larger than 25,000,000 pixels or
  8192 pixels on either axis.

Rejected input returns empty output.

## Memory

The module has fixed initial and maximum memory of 469,762,048 bytes
(448 MiB): a 64 MiB input buffer, a 100 MB KTX2 output buffer, a 256 MiB heap
and a 1 MiB stack. jxl-rs decodes in groups and does not keep a full-image
float buffer, so its heap stays small. The largest measured peak was 21.4 MiB,
for a 16 MP lossless file from `cjxl -e 7`.

The heap is a reclaiming first-fit arena used as Rust's global allocator. It
is not reset between render calls, because jxl-rs keeps lazily built tables
(about 2 MiB) in process-lifetime statics. A render that ends with more than
8 MiB of new live allocations returns empty output. If the heap is exhausted,
Rust's allocation error handler traps and the host discards the instance.

The arena exports `arena_peak_bytes`, `arena_live_bytes`,
`arena_allocation_count`, `arena_largest_allocation` and
`arena_failed_allocation` for the last render call.

## Speed

One Node.js 26 thread on an Apple Silicon Mac decoded a 16 MP fjxl file in
0.30 s, a 25 MP lossy file in 0.47 s, and a 25 MP `cjxl -e 7` lossless file in
4.9 s.

## Build

The crate is in `image/jxl/jxl-to-ktx2-r8g8b8a8-srgb/`. Its dependencies are
vendored in `third_party/rust` and the build does not access the network. It
needs Rust 1.89 or later with the `wasm32-unknown-unknown` target:

```sh
rustup target add wasm32-unknown-unknown
make image/jxl/jxl-to-ktx2-r8g8b8a8-srgb.wasm
node --test test/ktx2-jxl.mjs
```

`.cargo/config.toml` selects the vendored sources, enables WebAssembly SIMD
and bulk memory, and sets equal initial and maximum memory. The `jxl` crate's
`simd128` feature uses WebAssembly SIMD for its vector kernels. The module has
no imports and does not use `memory.grow`. It is built with `opt-level = 3`;
`opt-level = "s"` made it 35% smaller (1.02 MB instead of 1.56 MB) and 5–20%
slower to decode.
