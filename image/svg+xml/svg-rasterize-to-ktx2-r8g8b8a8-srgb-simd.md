# SVG to antialiased sRGB RGBA8 KTX2

`svg-rasterize-to-ktx2-r8g8b8a8-srgb-simd.wasm` uses the same SIMD scanline path
coverage and premultiplied sRGB compositing as the RGBA32F renderer. It
quantizes the completed straight-alpha image to RGBA8 once.

This component exists to measure the RGBA8 output tradeoff without comparing
different rasterization quality. Its float working image requires 16 bytes per
pixel, so it retains the 512 MiB fixed-memory cost even though its KTX2 output
uses 4 bytes per pixel.

`current_color_rgba` resolves `currentColor` paint in `fill` and `stroke`
attributes and defaults to opaque black. This limited SVG subset does not
implement the CSS `color` property or its inheritance. The uniform supplies
one document-wide current color instead and resets after each render.

It supports the same SVG subset as
[`svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm`](svg-rasterize-to-ktx2-r8g8b8a8-srgb.md),
including gradients, opacity, rounded rectangles, and Inter text.
