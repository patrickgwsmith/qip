# SVG to canonical RGBA8 sRGB KTX2

`svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm` rasterizes the repository's
supported SVG subset directly into QIP's canonical
`VK_FORMAT_R8G8B8A8_SRGB` KTX2 profile. Rows and RGBA channels are written in
their final top-down (`KTXorientation=rd`) order. Use this component for new
pipelines. Use the BMP variant only when the next stage requires BMP.

The SVG root must declare numeric `width` and `height` attributes or a
`viewBox`. A viewBox-only document uses the viewBox dimensions. The
`background_color_rgba` uniform accepts `0xRRGGBBAA` and defaults to transparent
black. The output retains straight alpha when no opaque background is
requested. The uniform resets to its default after each render.

```sh
./qip run \
  image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm \
  -u background_color_rgba=0xffffffff \
  -i input.svg -o output.ktx2
```

SVG input is limited to 1 MiB. Output images are limited to 25,000,000 pixels
and 8192 pixels on either axis. Missing, zero, or excessive dimensions reject
the input.
