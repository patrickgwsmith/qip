# JPEG to canonical RGBA8 sRGB KTX2

`jpeg-to-ktx2-r8g8b8a8-srgb.wasm` decodes JPEG directly into QIP's canonical
`VK_FORMAT_R8G8B8A8_SRGB` KTX2 profile. It writes one tightly packed,
top-down (`KTXorientation=rd`) RGBA image without a BMP intermediate.

The component supports sequential and progressive Huffman 8-bit JPEG (SOF0,
SOF1, and SOF2), grayscale and three-component colour images, and restart
markers. It rejects arithmetic-coded, 12-bit, and CMYK streams. JPEG has no
alpha channel, so every output alpha byte is 255.

Progressive JPEG needs image-wide DCT coefficient storage before it can emit
the first pixel. The component retains QIP's 25 MP output limit but therefore
declares 512 MiB of fixed Wasm memory.

```sh
./qip run \
  image/jpeg/jpeg-to-ktx2-r8g8b8a8-srgb.wasm \
  -i input.jpg -o output.ktx2
```

Inputs are limited to 64 MiB. Decoded images are limited to 25,000,000 pixels
and 8192 pixels on either axis. Unsupported or malformed input produces zero
output bytes.
