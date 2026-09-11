# HTML To SVG Inter Paths

`html-to-svg-inter-paths.wasm` renders a small HTML document into a
self-contained 390×844 SVG. It is for a fixed mobile viewport, such as a
preview image or a first-page PDF input, not for browser-compatible HTML
rendering.

The component accepts `text/html` and returns `image/svg+xml`. Text uses
embedded Inter Regular and Bold outlines. The SVG contains paths and geometry;
it does not depend on a font file, browser font selection, CSS file, image, or
network request.

```bash
qip run \
  -i test/fixtures/html-to-svg-inter-paths/daring-fireball-mobile.html \
  text/html/html-to-svg-inter-paths.wasm \
  image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm \
  image/bmp/bmp-to-png.wasm \
  > mobile-page.png
```

It lays out `body`, `main`, `header`, `footer`, `article`, `section`, `div`,
paragraphs, headings, lists, buttons, inputs, and horizontal rules. Links,
`strong`, `b`, `span`, and line breaks work in text flow. It applies these
inline style properties: color, background color, font size and weight, line
height, padding, margin, width in pixels or percent, text alignment, border,
and border radius.

The default resembles a reset: Inter at 16px/24px on white, no stylesheet, and
no browser user-agent layout rules. HTML comments, `head`, `title`, `style`,
`script`, and unsupported void elements are skipped. The renderer does not
fetch stylesheets or images, execute JavaScript, apply selector-based CSS,
perform flex/grid/table layout, shape arbitrary scripts, or paginate. It
continues layout after the viewport but stops emitting off-screen glyph paths,
which keeps long source pages within the output bound.

Use a browser engine when the source depends on its existing CSS, JavaScript,
responsive breakpoints, web fonts, or exact browser layout. Use this component
when the source is intentionally within its small static subset and the
portable SVG is the primary output.
