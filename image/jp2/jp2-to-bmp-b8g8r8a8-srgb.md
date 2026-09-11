# JPEG 2000 to 32-bit BGRA BMP

`jp2-to-bmp-b8g8r8a8-srgb.wasm` decodes a still `image/jp2` file into a top-down,
uncompressed 32-bit BGRA BMP. It statically links the OpenJPEG 2.5.4 decoder
with its SSE2/SSE4.1 paths lowered to WebAssembly SIMD; users do not need
OpenJPEG installed.

```bash
qip run --timeout-ms 30000 \
  image/jp2/jp2-to-bmp-b8g8r8a8-srgb.wasm \
  < input.jp2 > output.bmp

qip run --timeout-ms 30000 \
  image/jp2/jp2-to-bmp-b8g8r8a8-srgb.wasm \
  image/bmp/bmp-to-png.wasm \
  < input.jp2 > output.png
```

The component accepts JP2 containers up to 64 MiB and decoded images up to
25,000,000 pixels, with neither dimension above 8192 pixels. It handles
grayscale, RGB, sYCC, e-YCC, and CMYK component data, plus one alpha channel.
Component precision is scaled to eight bits for BMP output. Embedded ICC
profiles and other JP2 metadata are not transferred.

Raw `.j2k`/`.j2c` codestreams and JPX Part 2 files are rejected. OpenJPEG can
decode raw codestreams, but accepting them under the `image/jp2` contract would
make the MIME boundary inaccurate. A separate component can expose that input
format if it becomes useful.

The module reserves 640 MiB of fixed Wasm memory: 64 MiB for input, about
95.4 MiB for BMP output, and 384 MiB for a reclaiming OpenJPEG arena, plus code
and stack. It imports no memory and contains no `memory.grow`. The 25 MP
lossless fixture peaks at about 303 MiB of live arena allocations.

The full OpenJPEG library source and its BSD 2-Clause license are vendored
under `third_party/openjpeg-2.5.4`. The build selects only the decoder library
sources and excludes OpenJPEG's command-line tools and their PNG, TIFF, and
LCMS dependencies.

## When not to use this

Keep a JP2 file unchanged when downstream software already understands JPEG
2000 or needs its metadata and original component precision. BMP is useful as
a simple QIP interchange format, but it expands a 25 MP image to roughly
95 MiB and reduces higher-precision components to eight bits.
