# SVG and fonts to sRGB RGBA8 KTX2 with Skia

`svg-rasterize-skia-with-fonts-to-ktx2-r8g8b8a8-srgb.wasm` renders an SVG with
Skia's `SkSVGDOM` on the CPU, using only the fonts sent with it. Its input is
[`multipart/related`](/docs/content-component#multipart-related) with the SVG
as the root part and TrueType, OpenType, WOFF, or WOFF2 fonts as later parts.
It returns one KTX2 level with straight-alpha RGBA8 sRGB pixels. It needs no GPU, JavaScript
runtime, host fonts, or filesystem.

Pass the SVG with `-i` and each font with a typed `-F` part:

```sh
qip run -i drawing.svg \
  -F 'regular=@fixtures/inter-4.1/ttf/InterDisplay-Regular.ttf;type=font/ttf' \
  -F 'bold=@fixtures/inter-4.1/ttf/InterDisplay-Bold.ttf;type=font/ttf' \
  -o drawing.ktx2 -- \
  image/svg+xml/svg-rasterize-skia-with-fonts-to-ktx2-r8g8b8a8-srgb.wasm \
  -u width=1024 -u height=1024
```

## Input

The declared input type is:

```text
multipart/related;type="image/svg+xml";boundary=uuid-00000000-0000-0000-0000-000000000000
```

The component reads the boundary slot on every call, so hosts may replace the
UUID. The first part must have `Content-Type: image/svg+xml`. Every later part
must be `font/ttf`, `font/otf`, `font/woff`, or `font/woff2`. Media types match
case-insensitively and may carry parameters. Other headers, such as
`Content-ID`, are ignored, except that `Content-Transfer-Encoding` is rejected.
FreeType detects each font's format from its bytes, so any of the four font
types may label any supported font.

A WOFF or WOFF2 font renders the same pixels as the TrueType font it was made
from. FreeType unpacks it into the arena while the font is in use, so it takes
more memory than a TrueType part, which is read in place.

Skia matches SVG `font-family`, `font-weight`, and `font-style` against the
names and styles inside the font files. A request for a missing style uses the
closest supplied face, and an unknown family falls back to a supplied font.
Without font parts, shapes still render but text draws nothing. A font part
FreeType cannot open is rejected.

## Uniforms and limits

| Uniform | Default | Effect |
| --- | --- | --- |
| `width` | `0` | Output width in pixels; zero uses the intrinsic width. |
| `height` | `0` | Output height in pixels; zero uses the intrinsic height. |
| `background_color_rgba` | `0` | Background in `0xRRGGBBAA` order; zero is transparent. |

Uniforms reset after each render. Without an intrinsic size, the component
uses the `viewBox` size, then 300 × 150 pixels. The SVG `preserveAspectRatio`
attribute controls how its coordinates fit the output viewport.

Input is limited to 32 MiB and 64 parts: the SVG and up to 63 fonts. Fonts
are not retained between calls. FreeType limits an unpacked WOFF2 font to
30 MiB. Each output dimension
is limited to 8192 pixels; setters clamp larger values. Output is limited to
25 million pixels. A malformed body, a wrong part type, an unreadable font,
malformed XML, an invalid SVG root, entity declarations, and invalid output
dimensions return a recoverable rejection without a byte offset. An internal
allocation failure can trap; discard the instance after a trap.

The module declares fixed 544 MiB memory: the 32 MiB input buffer and a
384 MiB reclaiming arena. Skia keeps some allocations for the life of the
instance. Render storage and image and font caches are released after each
call. The `arena_*` exports report live and peak bytes, failed allocation
size, and unmatched frees.

## SVG support

This build supports Skia's SVG paths, transforms, gradients, clipping, masks,
filters, text, and antialiased edges. There is no host font lookup or
complex-script shaping.

Skia's SVG DOM is a renderer, not a browser document engine. Unsupported SVG
features can be ignored. External resources, embedded raster images, CSS
stylesheets, animation, and GPU rendering are outside this build's scope.
Use presentation attributes or element `style` attributes for supported paint
properties. Declare SVG `color` to control `currentColor`.

Do not use this component when 544 MiB of fixed memory is too costly, when
browser SVG compatibility is required, or when floating-point linear-light
output is required. QIP's smaller native SVG rasterizers and its RGBA32F
rasterizer serve those different memory and color needs.

## Build

Run `make -j test-svg-skia` to rebuild and test this component. The pinned
Skia, Expat, FreeType, and Brotli sources and their licenses are in
`third_party/skia-m124`. `QIP-VENDOR.md` records their versions, checksums,
target configuration, and local changes. Builds use the repository's pinned
Emscripten toolchain and checked source manifest; they do not need GN or
system graphics libraries.
