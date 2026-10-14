# SVG to canonical RGBA8 sRGB KTX2

`svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm` rasterizes the repository's
supported SVG subset directly into QIP's canonical
`VK_FORMAT_R8G8B8A8_SRGB` KTX2 profile. Rows and RGBA channels are written in
their final top-down (`KTXorientation=rd`) order. Use this component for new
pipelines. Use the BMP variant only when the next stage requires BMP.

The SVG root must declare numeric `width` and `height` attributes or a
`viewBox`. A viewBox-only document uses the viewBox dimensions. The
`background_color_rgba` uniform accepts `0xRRGGBBAA` and defaults to transparent
black. `current_color_rgba` resolves `currentColor` paint in `fill` and
`stroke` attributes and defaults to opaque black. The output retains straight
alpha when no opaque background is requested. The uniforms reset to their
defaults after each render.

```sh
./qip run \
  image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm \
  -u background_color_rgba=0xffffffff \
  -i input.svg -o output.ktx2
```

SVG input is limited to 1 MiB. Output images are limited to 25,000,000 pixels
and 8192 pixels on either axis. Missing, zero, or excessive dimensions reject
the input.

This limited SVG subset does not implement the CSS `color` property or its
inheritance. The `current_color_rgba` uniform supplies one document-wide
current color instead.

Supported elements are `rect` (with `rx` and `ry`), `circle`, `line`,
`path`, `polygon`, `polyline`, `text`, and `g`. Paint may be a hex or basic
named color, `currentColor`, or a `url(#id)` reference to a `linearGradient`
or `radialGradient`, with `fill-opacity`, `stroke-opacity`, and `opacity`.
Gradients support both `gradientUnits`, `gradientTransform`, `spreadMethod`,
and stops inherited through `href`; radial focal points (`fx`, `fy`) are
ignored. A reference to a missing gradient uses its fallback color or paints
nothing. Group `opacity` is applied to each child separately rather than to
the composited group. `<text>` is drawn with embedded Inter Display Regular
and Bold outlines whatever `font-family` says, honours `font-size`,
`font-weight`, and `text-anchor`, and lays out one line with pair kerning.
Content inside `defs`, `clipPath`, `mask`, `symbol`, `pattern`, and `marker`
is not drawn. The `style` attribute is ignored.

Each pixel is sampled once at its center, so edges are not antialiased.
Translucent paint is blended in sRGB. Strokes always have round caps and
joins, and arcs fall back to straight segments.
