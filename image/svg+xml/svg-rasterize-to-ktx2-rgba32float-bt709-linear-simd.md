# SVG to linear BT.709 RGBA32F KTX2

`svg-rasterize-to-ktx2-rgba32float-bt709-linear-simd.wasm` rasterizes the
supported static SVG subset into the repository's straight-alpha, linear
BT.709 RGBA32F KTX2 profile. It uses a 4 by 4 SIMD sample grid for fractional
pixel coverage. Path fills sort edge intersections for each sample scanline and
emit covered spans. Other primitives use bounded per-pixel sampling. Paint is
composited in premultiplied linear light before returning straight-alpha
pixels.

The root may provide numeric `width` and `height` attributes or a `viewBox`.
The `width` and `height` uniforms override the output dimensions, which is
useful for viewBox-only documents:

```sh
./qip run -i tiger.svg -o tiger.ktx2 \
  image/svg+xml/svg-rasterize-to-ktx2-rgba32float-bt709-linear-simd.wasm \
  -u width=512 -u height=512
```

SVG input is limited to 1 MiB. Output images are limited to 25,000,000 pixels
and 8192 pixels on either axis. The maximum KTX2 output is about 381.5 MiB, so
the component declares 512 MiB of fixed Wasm memory.

`current_color_rgba` resolves `currentColor` paint in `fill` and `stroke`
attributes and defaults to opaque black. This limited SVG subset does not
implement the CSS `color` property or its inheritance. The uniform supplies
one document-wide current color instead and resets after each render.

The 4 by 4 coverage grid is a bounded, deterministic quality baseline, not an
analytic area-coverage rasterizer like Skia's CPU path. Scanline spans avoid
retesting every edge at every pixel, but coverage still has 17 alpha levels.
Curves use fixed subdivision, SVG arcs fall back to straight segments, and
strokes do not yet implement SVG joins and caps. Use a mature SVG renderer when
those geometry details or the full SVG paint model are required.

Compare this component with the RGBA8 center-sampled renderer on the Tiger
fixture:

```sh
node tools/bench-svg-rasterizers.mjs 256 10
```

The benchmark reuses each Wasm instance and excludes compilation. It reports
render time, throughput, output size, fractional-alpha pixels, and the pixel
difference after converting the float output to sRGB.
