# ANSI SGR Text Projections

These components process a narrow terminal presentation profile: UTF-8 text
with only ANSI CSI SGR controls (`ESC[` parameters `m`). They accept reset,
bold, dim, underline, the normal and bright 16 foreground colours, and the
same background colours. They reject cursor movement, screen erasure, OSC,
hyperlinks, device queries, and unsupported SGR parameters.

`strip-ansi-sgr.wasm` returns `text/plain` without supported SGR controls. Use
it before sending a terminal screen to a plain-text parser, a search index, or
an archive.

`ansi-sgr-to-html.wasm` returns `text/html` as an escaped `<pre>` document. It
uses `b`, `u`, and inline `span` styles for the accepted presentation state.

`ansi-sgr-to-svg.wasm` returns `image/svg+xml` with browser-native SVG `text`
elements and a generic monospace font stack. It is not self-contained: the
browser chooses its installed monospace font. The component clips text outside
its viewport so a long terminal transcript cannot expand the SVG without
bound. Use a separately named `*-dejavu-sans-mono-paths` component when an SVG
must embed DejaVu outlines instead of browser text.

```bash
printf 'normal \033[1;94mbold blue\033[0m\n' |
  qip run text/ansi-sgr-to-html.wasm > screen.html

printf 'normal \033[1;94mbold blue\033[0m\n' |
  qip run text/ansi-sgr-to-svg.wasm > screen.svg
```

These are presentation adapters, not a terminal emulator. They do not retain
cursor position, screen regions, links, clipboard data, or terminal state.
