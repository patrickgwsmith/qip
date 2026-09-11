# SVG to antialiased sRGB RGBA8 KTX2

`svg-rasterize-to-ktx2-r8g8b8a8-srgb-simd.wasm` uses the same SIMD scanline path
coverage and premultiplied linear-light compositing as the RGBA32F renderer. It
converts the completed straight-alpha image to sRGB RGBA8 once.

This component exists to measure the RGBA8 output tradeoff without comparing
different rasterization quality. Its float working image requires 16 bytes per
pixel, so it retains the 512 MiB fixed-memory cost even though its KTX2 output
uses 4 bytes per pixel.
