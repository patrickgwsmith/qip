# PNG to canonical RGBA8 sRGB KTX2

`png-to-ktx2-r8g8b8a8-srgb.wasm` decodes a PNG directly into QIP's canonical
`VK_FORMAT_R8G8B8A8_SRGB` KTX2 profile. The output has one top-down,
left-to-right (`KTXorientation=rd`) image and a tightly packed RGBA payload.

The component accepts non-interlaced 8-bit grayscale, truecolor, indexed,
grayscale-alpha, and RGBA PNGs. It verifies chunk CRCs, the zlib header, and
the Adler-32 trailer. It rejects unknown critical chunks, 16-bit samples,
sub-8-bit samples, Adam7 interlacing, and malformed palettes. Ancillary chunks
do not change the decoded base image.

The decoder writes unfiltered rows directly to their final top-down KTX2
positions. It does not create a BMP, reverse rows, or swap red and blue.

```sh
./qip run \
  image/png/png-to-ktx2-r8g8b8a8-srgb.wasm \
  -i input.png -o output.ktx2
```

Inputs are limited to 64 MiB. Decoded images are limited to 25,000,000 pixels
and 8192 pixels on either axis. The module uses fixed Wasm memory and returns
zero bytes for unsupported or malformed input.
