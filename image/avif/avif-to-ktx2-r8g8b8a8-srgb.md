# AVIF to canonical RGBA8 sRGB KTX2

`avif-to-ktx2-r8g8b8a8-srgb.wasm` decodes one still AVIF directly into QIP's
canonical `VK_FORMAT_R8G8B8A8_SRGB` KTX2 profile. libavif writes the decoded
top-down RGBA pixels into the final KTX2 payload.

The decoder rejects image sequences, progressive layers, embedded ICC
profiles, and CICP that explicitly names non-BT.709 primaries or a non-sRGB
transfer. It accepts unspecified CICP under the component's documented sRGB
assumption. Use a colour-managed boundary when another source colour space
must be converted or preserved.

```sh
./qip run \
  image/avif/avif-to-ktx2-r8g8b8a8-srgb.wasm \
  -i input.avif -o output.ktx2
```

Inputs are limited to 64 MiB. Decoded images are limited to 25,000,000 pixels
and 8192 pixels on either axis. Decoding uses libavif 1.4.1 with libaom 3.13.0
in one thread and fixed 1 GiB Wasm memory.
