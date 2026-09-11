<title>Text content components</title>

# Text content components

These components validate, transform, inspect, or render text. Some components declare a `text/*` MIME type. Other components use the UTF-8 encoding contract without a more specific MIME type. Download a `.wasm` file and run it with [`qipx run`](/docs/qipx), or combine compatible inputs and outputs with the [recipe finder](/recipes).

## Markdown (`text/markdown`)

- [`gfm-commonmark.0.31.2.wasm`](/text/markdown/gfm-commonmark.0.31.2.wasm) renders GitHub Flavored Markdown on top of CommonMark 0.31.2.
- [`commonmark.0.31.2.wasm`](/text/markdown/commonmark.0.31.2.wasm) renders CommonMark 0.31.2 as HTML.
- [`extract-title-text.wasm`](/text/markdown/extract-title-text.wasm) extracts plain text from the first Markdown heading.
- [`markdown-basic.wasm`](/text/markdown/markdown-basic.wasm) renders the repository's smaller basic Markdown subset as HTML.

Related tool: [Markdown to HTML](/markdown-to-html).

## HTML (`text/html`)

### Transform

- [`html-accessible-name-unique-validator.wasm`](/text/html/html-accessible-name-unique-validator.wasm) rejects duplicate accessible names in the supported interactive-element subset.
- [`html-add-highlight-stylesheet-night-owl.wasm`](/text/html/html-add-highlight-stylesheet-night-owl.wasm) adds the Night Owl syntax-highlight stylesheet.
- [`html-link-extractor.wasm`](/text/html/html-link-extractor.wasm) replaces each absolute HTTPS link with a line containing that URL.
- [`html-page-wrap.wasm`](/text/html/html-page-wrap.wasm) wraps an HTML fragment in the repository's page shell.
- [`html-to-accessibility-tree.wasm`](/text/html/html-to-accessibility-tree.wasm) renders supported HTML as a Markdown accessibility tree.
- [`html-id-reference-validator.wasm`](/text/html/html-id-reference-validator.wasm) rejects same-document ID references that do not resolve to a valid target.
- [`html-unique-id-validator.wasm`](/text/html/html-unique-id-validator.wasm) rejects duplicate `id` values.
- [`html-wcag-contrast-aa.wasm`](/text/html/html-wcag-contrast-aa.wasm) checks supported foreground and background colors against WCAG AA contrast thresholds.

### Syntax highlight

These components highlight matching fenced code blocks and return `text/html`:

- [`html-code-syntax-highlight-bash.wasm`](/text/html/html-code-syntax-highlight-bash.wasm)
- [`html-code-syntax-highlight-c.wasm`](/text/html/html-code-syntax-highlight-c.wasm)
- [`html-code-syntax-highlight-css.wasm`](/text/html/html-code-syntax-highlight-css.wasm)
- [`html-code-syntax-highlight-go.wasm`](/text/html/html-code-syntax-highlight-go.wasm)
- [`html-code-syntax-highlight-html.wasm`](/text/html/html-code-syntax-highlight-html.wasm)
- [`html-code-syntax-highlight-ruby.wasm`](/text/html/html-code-syntax-highlight-ruby.wasm)
- [`html-code-syntax-highlight-swift.wasm`](/text/html/html-code-syntax-highlight-swift.wasm)
- [`html-code-syntax-highlight-tsx.wasm`](/text/html/html-code-syntax-highlight-tsx.wasm)
- [`html-code-syntax-highlight-wasm.wasm`](/text/html/html-code-syntax-highlight-wasm.wasm)
- [`html-code-syntax-highlight-zig.wasm`](/text/html/html-code-syntax-highlight-zig.wasm)

Related tools: [syntax highlighter](/syntax-highlight) and [HTML accessibility tree](/accessibility-tree).

## JSON (`application/json`)

- [`json-prettify.wasm`](/application/json/json-prettify.wasm) formats JSON with indentation and line breaks.

## CSS (`text/css`)

- [`css-minify.wasm`](/text/css/css-minify.wasm) removes comments and unnecessary whitespace. It returns `text/css`.

Related tools: [CSS minifier](/css-minifier) and [CSS expression calculator](/css-expression-calculator).

## General text

- [`trim.wasm`](/text/trim.wasm) removes whitespace from the start and end of UTF-8 text.
- [`base64-decode.wasm`](/text/base64-decode.wasm) decodes canonical RFC 4648 Base64 text as bytes.
- [`shortcode-to-emoji.wasm`](/text/shortcode-to-emoji.wasm) replaces supported emoji shortcodes in text. [`shortcode-to-emoji-odin.wasm`](/text/shortcode-to-emoji-odin.wasm) is the Odin implementation.
- [`e164.wasm`](/text/e164.wasm) removes phone-number punctuation and emits an E.164-style number.
- [`hex-to-rgb.wasm`](/text/hex-to-rgb.wasm) converts a hexadecimal color to RGB text.
- [`rgb-to-hex.wasm`](/text/rgb-to-hex.wasm) converts RGB text to a hexadecimal color.
- [`youtube-id-extractor.wasm`](/text/youtube-id-extractor.wasm) extracts YouTube video IDs from text.

## Validation

- [`utf8-must-be-valid.wasm`](/text/utf8-must-be-valid.wasm) accepts valid UTF-8 bytes unchanged and reports the first invalid byte offset. [`utf8-must-be-valid-odin.wasm`](/text/utf8-must-be-valid-odin.wasm) is the Odin implementation.
- [`utf8-must-be-ascii.wasm`](/text/utf8-must-be-ascii.wasm) accepts ASCII bytes unchanged and reports the first non-ASCII byte offset.
- [`luhn.wasm`](/text/luhn.wasm) validates a number with the Luhn checksum and returns its digits without spaces or hyphens.
- [`tld-validator.wasm`](/text/tld-validator.wasm) validates a top-level domain label.

## Unicode 17

- [`unicode-17-normalize-nfc.wasm`](/text/unicode-17-normalize-nfc.wasm) normalizes UTF-8 text to Unicode NFC.
- [`unicode-17-lowercase.wasm`](/text/unicode-17-lowercase.wasm) applies Unicode default lowercase conversion.
- [`unicode-17-uppercase.wasm`](/text/unicode-17-uppercase.wasm) applies Unicode default uppercase conversion.

Related tool: [Unicode converter](/unicode).

## Text rendering

- [`text-to-bmp.wasm`](/text/text-to-bmp.wasm) renders UTF-8 text as a BMP image.
- [`text-to-og-image-font8x8.wasm`](/text/text-to-og-image-font8x8.wasm) renders text as a 1200×630 BMP with a small bitmap font.
- [`text-to-og-image-dejavu-sans-mono.wasm`](/text/text-to-og-image-dejavu-sans-mono.wasm) renders text as a 1200×630 BMP with DejaVu Sans Mono.
- [`text-to-og-image-svg-inter.wasm`](/text/text-to-og-image-svg-inter.wasm) renders form-encoded title and subtitle fields as an Open Graph SVG with Inter.
- [`text-to-svg-inter.wasm`](/text/text-to-svg-inter.wasm) renders one plain text value as wrapped Inter paths on a transparent, intrinsically sized SVG canvas.
- [`text-to-svg-jetbrains-mono-v2.304.wasm`](/text/text-to-svg-jetbrains-mono-v2.304.wasm) renders one plain text value as wrapped, monospaced JetBrains Mono 2.304 paths without ligatures.
- [`text-to-og-image-svg-dejavu-sans-mono.wasm`](/text/text-to-og-image-svg-dejavu-sans-mono.wasm) renders form-encoded title and subtitle fields as an Open Graph SVG with DejaVu Sans Mono.
- [`text-to-path-svg-dejavu-sans-mono.wasm`](/text/text-to-path-svg-dejavu-sans-mono.wasm) renders text as SVG glyph paths.
- [`text-to-path-svg-dejavu-sans-mono-bold.wasm`](/text/text-to-path-svg-dejavu-sans-mono-bold.wasm) renders text as bold SVG glyph paths.

Related tool: [Open Graph image maker](/og-image).

## Programming languages

### JavaScript (`text/javascript`)

- [`js-syntax-highlight-html.wasm`](/text/javascript/js-syntax-highlight-html.wasm) escapes JavaScript and adds eight semantic syntax classes. It returns `text/html`.
- [`js-to-bmp.wasm`](/text/javascript/js-to-bmp.wasm) renders the supported JavaScript syntax subset to a BMP image.
- [`js-to-bmp2.wasm`](/text/javascript/js-to-bmp2.wasm) provides the newer Zig implementation of the same JavaScript-to-BMP pipeline.

See the [syntax highlight comparison](/syntax-highlight-comparison) for its output contract, Shiki oracle, and performance measurements.

### C (`text/x-c`)

- [`c-to-bmp.wasm`](/text/x-c/c-to-bmp.wasm) renders the supported C syntax subset to a BMP image.

## Dates

- [`calendar-gregorian.wasm`](/text/calendar-gregorian.wasm) renders a `YYYY-MM` value as a Monday-first Markdown calendar.

## Currency

- [`iso-4217-alpha-to-numeric.wasm`](/text/iso-4217-alpha-to-numeric.wasm) converts an ISO 4217 alphabetic currency code to its numeric code.
- [`currency-format-usd-en-us.wasm`](/text/currency-format-usd-en-us.wasm) formats one decimal value as US English USD.

The locale-specific currency components accept a decimal value. A `currency` uniform selects the currency:

- [`currency-format-ar-eg.wasm`](/text/currency-format-ar-eg.wasm)
- [`currency-format-de-de.wasm`](/text/currency-format-de-de.wasm)
- [`currency-format-en-in.wasm`](/text/currency-format-en-in.wasm)
- [`currency-format-en-us.wasm`](/text/currency-format-en-us.wasm)
- [`currency-format-es-es.wasm`](/text/currency-format-es-es.wasm)
- [`currency-format-fr-fr.wasm`](/text/currency-format-fr-fr.wasm)
- [`currency-format-ja-jp.wasm`](/text/currency-format-ja-jp.wasm)
- [`currency-format-pt-br.wasm`](/text/currency-format-pt-br.wasm)
- [`currency-format-zh-cn.wasm`](/text/currency-format-zh-cn.wasm)

Related tool: [currency formatter](/currency).

## URI list (`text/uri-list`)

- [`data-uri-to-css-url.wasm`](/text/uri-list/data-uri-to-css-url.wasm) wraps a data URI for use as a CSS `url()` value.
- [`url-to-qr-svg.wasm`](/text/uri-list/url-to-qr-svg.wasm) renders one URL as an SVG QR code.

Related tools: [QR code maker](/qr) and [SVG data URI](/svg-data-uri).

## Mermaid (`text/vnd.mermaid`)

- [`mermaid-to-unicode-html.wasm`](/text/vnd.mermaid/mermaid-to-unicode-html.wasm) renders the supported Mermaid subset as Unicode box art in HTML.

Related tool: [Mermaid to Unicode box art](/mermaid).

## CSV (`text/csv`)

- [`content-recipe-to-browser-javascript.wasm`](/text/csv/content-recipe-to-browser-javascript.wasm) turns a component-recipe CSV row into browser JavaScript. It returns `text/javascript`.

Related tool: [component recipe finder](/recipes).

## Counts and examples

- [`wc.wasm`](/text/wc.wasm) counts lines, words, and bytes. [`wc-odin.wasm`](/text/wc-odin.wasm) is the Odin implementation.
- [`hello.wasm`](/text/hello.wasm), [`hello-naive.wasm`](/text/hello-naive.wasm), [`hello-c.wasm`](/text/hello-c.wasm), [`hello-zig.wasm`](/text/hello-zig.wasm), [`hello-odin.wasm`](/text/hello-odin.wasm), and [`hello-assemblyscript.wasm`](/text/hello-assemblyscript.wasm) are equivalent small components for implementation and benchmark comparisons.
- [`infinite-loop.wasm`](/text/infinite-loop.wasm) is an intentional non-terminating test fixture for host execution limits. Do not use it in a content pipeline.

Looking for raster formats instead? See the [image content components](/image).
