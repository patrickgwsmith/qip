# SVG text to glyph outlines with Skia

`svg-text-to-path-skia-with-fonts.wasm` replaces each SVG `<text>` element
with a `<path>` of glyph outlines from the fonts sent with it. The result draws
the same words on any renderer, with no fonts installed. Its input is
[`multipart/related`](/docs/content-component#multipart-related) with the SVG
as the root part and TrueType, OpenType, WOFF, or WOFF2 fonts as later parts.
It needs no GPU, JavaScript runtime, host fonts, or filesystem.

Pass the SVG with `-i` and each font with a typed `-F` part:

```sh
qip run -i chart.svg \
  -F 'regular=@fixtures/inter-4.1/ttf/InterDisplay-Regular.ttf;type=font/ttf' \
  -F 'bold=@fixtures/inter-4.1/ttf/InterDisplay-Bold.ttf;type=font/ttf' \
  -F 'italic=@fixtures/inter-4.1/ttf/InterDisplay-Italic.ttf;type=font/ttf' \
  -F 'bold-italic=@fixtures/inter-4.1/ttf/InterDisplay-BoldItalic.ttf;type=font/ttf' \
  -o chart-outlined.svg -- \
  image/svg+xml/svg-text-to-path-skia-with-fonts.wasm
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
types may label any supported font. A font part FreeType cannot open is
rejected.

## What changes

The component copies the SVG part's bytes unchanged except for `<text>`
elements. Comments, CDATA, formatting, ids, groups, and `<style>` elements stay
as they were. Each `<text>…</text>` becomes one `<path>`:

- The path keeps the `<text>` element's other attributes, such as `id`,
  `class`, `fill`, `stroke`, `transform`, and `style`.
- It drops layout attributes that have no effect on a path: `x`, `y`, `dx`,
  `dy`, `rotate`, `xml:space`, `text-anchor`, and the `font-*`,
  spacing, baseline, and direction attributes.
- It keeps `<title>` and `<desc>` children, so the accessible name remains.
- The `d` value uses absolute coordinates with six significant digits.

Text that draws no glyphs, such as an empty element, becomes `d=""`.

## Layout

Skia's SVG text engine (`SkSVGText`) lays out each `<text>` with the same rules
as `svg-rasterize-skia-with-fonts-to-ktx2-r8g8b8a8-srgb.wasm`. It reads
`font-family`, `font-size`, `font-style`, `font-weight`, and `text-anchor` from
the element, its ancestors, and their `style` attributes. It supports
`<tspan>`, `<textPath>`, `x` and `y` lists, `dx`, `dy`, `rotate`, `xml:space`,
and percentage lengths. At 256 pixels and larger, a rasterized output matches
the rasterized input except for edge rounding.

Below 256 pixels, Skia draws text from cached glyph masks. These masks
antialias differently from filled paths, so small text in the output has
slightly different edge pixels. Glyph positions and shapes do not change.

Skia matches SVG `font-family`, `font-weight`, and `font-style` against the
names and styles inside the font files, not the order of the parts. A request
for a missing style uses the closest supplied face, and an unknown family falls
back to a supplied font. Without font parts, text becomes `d=""`. There is no
kerning, ligatures, or complex-script shaping.

With Inter Display Regular, Bold, Italic, and Bold Italic as parts, the output
is byte-identical to the earlier build that embedded those four faces. WOFF
and WOFF2 versions of the same faces give the same bytes. Weights
of 600 and above then use Bold, and `font-style` values `italic` and `oblique`
use the italic faces.

## Limits

- Each `<text>` becomes one path with the `<text>` element's paint. Paint
  attributes on `<tspan>` children, such as a different `fill`, are lost.
- CSS rules in `<style>` elements do not set fonts, and selectors such as
  `text { … }` no longer match the new `<path>`.
- Input is limited to 32 MiB and 64 parts: the SVG and up to 63 fonts. Fonts
  are not retained between calls. TrueType and OpenType parts are read in
  place. FreeType unpacks WOFF and WOFF2 fonts into the arena while they are
  in use, and limits an unpacked WOFF2 font to 30 MiB.
- Output is limited to 16 MiB. Outlines are larger than text: a 12 pixel
  label of 25 characters is about 11 KB. About 1,500 such labels fill the
  output.
- A malformed body, a wrong part type, an unreadable font, malformed XML, a
  root other than `<svg>`, entity declarations, and output over the limit
  return a recoverable rejection without a byte offset. An internal
  allocation failure can trap; discard the instance after a trap.

The module declares fixed 192 MiB memory: the 32 MiB input buffer, the
16 MiB output buffer, and a 128 MiB reclaiming arena. Unpacking a WOFF2 font
briefly needs about twice its unpacked size. Two WOFF2 fonts that unpack to
22 MiB and 29 MiB peaked at 84 MiB of arena when used together. Skia keeps some
allocations for the life of the instance. Layout storage and font caches are
released after each call. The `arena_*` exports report live and peak bytes,
failed allocation size, and unmatched frees.

## Build

Run `make -j test-svg-text-to-path-skia` to rebuild and test the component.
It links the same pinned Skia build as the Skia rasterizer; see
`third_party/skia-m124/QIP-VENDOR.md`.
