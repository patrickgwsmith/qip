# BMP B8G8R8A8 sRGB ICC to sRGB

`bmp-b8g8r8a8-icc-to-srgb.wasm` converts a 32-bit BGRA BMP with an embedded ICC
profile to canonical 32-bit BGRA BMP whose pixels use sRGB. The output uses a
40-byte `BITMAPINFOHEADER`, a bottom-up pixel layout, and no embedded profile.

Legacy 40-byte BMPs and V5 BMPs marked `sRGB` are accepted and copied to this
canonical layout without a color conversion. V5 BMPs with an embedded profile
are converted with Little CMS 2.19.1. Linked profiles, unknown color-space
markers, nonstandard masks, and unsupported BMP headers are rejected. Alpha is
copied unchanged. Profile conversion is 8-bit and can round or clip colors
that do not fit the sRGB gamut.

The component accepts up to 25,000,000 pixels, with neither dimension above
8192 pixels. An embedded profile is limited to 64 KiB. Its fixed Wasm memory is
512 MiB, including a 256 MiB reclaiming Little CMS arena, input and output
buffers, code, and stack. The module has no host imports and includes Wasm SIMD
instructions.

With the pinned Little CMS 2.19.1 source and Emscripten 2.0.34 build, the
optimized module is 297,714 bytes (about 291 KiB). The raw LTO-linked module is
491,119 bytes (about 480 KiB) before `wasm-opt` removes debug and unreachable
code. LTO removes much of Little CMS's profile-writing, named-color, and other
optional code, but the baseline still includes the general ICC parser and
transform engine.

```sh
./qip run \
  --timeout-ms 180000 \
  --max-memory 536870912 \
  -i input.bmp -o output.bmp -- \
  image/bmp/bmp-b8g8r8a8-icc-to-srgb.wasm
```

This is a normalization stage for components that need a simple sRGB BMP
interchange contract. It does not preserve the source profile. Use a profile-
aware format at the system boundary when the original profile must remain
available.
