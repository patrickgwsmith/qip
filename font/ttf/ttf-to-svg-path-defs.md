# TrueType To SVG Path Definitions

`ttf-to-svg-path-defs.wasm` extracts Unicode-mapped TrueType glyphs as addressable
SVG paths. It emits a definitions document rather than laying out a specimen:

```xml
<svg xmlns="http://www.w3.org/2000/svg" data-units-per-em="2048" ...>
  <defs>
    <path id="u-0041" data-codepoint="U+0041" data-advance-x="1401" d="..."/>
  </defs>
</svg>
```

The `u-` prefix makes each hexadecimal codepoint a valid, predictable XML ID.
BMP codepoints use at least four hexadecimal digits; supplementary codepoints
use six. Consumers can reference a glyph with `<use href="#u-0041"/>` and
apply their own translation and scale.

```bash
qip run \
  -i fixtures/dejavu-fonts-ttf-2.37/ttf/DejaVuSans.ttf \
  -o dejavu-sans-paths.svg \
  -- font/ttf/ttf-to-svg-path-defs.wasm \
  -u first_codepoint=32 -u last_codepoint=255
```

The default inclusive range is U+0020 through U+00FF, and a requested range
may contain at most 4,096 codepoints. Unmapped codepoints do not produce paths.
Coordinates remain in font units with the baseline at zero. Y is inverted for
SVG, so ascenders use negative Y values.

This component uses the same parser and limits as
[`ttf-to-svg-paths-csv.wasm`](ttf-to-svg-paths-csv.md). It extracts glyphs; it
does not perform kerning, substitution, positioning, bidirectional layout, or
text shaping. Do not use the definitions document as a complete text renderer
when those operations affect the requested script or language.
