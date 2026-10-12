<title>SVG data URI</title>

# SVG data URI

Convert SVG bytes into a percent-encoded data URI that is safe inside either single- or double-quoted CSS. A second component wraps any lowercase `data:` URI as a CSS `url("…")` value.

```bash
printf %s '<svg fill="none"/>' \
  | qip run image/svg+xml/svg-to-data-uri.wasm
# data:image/svg+xml,%3Csvg%20fill=%22none%22/%3E

printf %s '<svg fill="none"/>' \
  | qip run image/svg+xml/svg-to-data-uri.wasm \
    text/uri-list/data-uri-to-css-url.wasm
# url("data:image/svg+xml,%3Csvg%20fill=%22none%22/%3E")
```

`svg-to-data-uri.wasm` preserves the input bytes rather than parsing, minifying, or sanitizing the SVG. It percent-encodes quotes, whitespace, `#`, `%`, backslashes, non-ASCII UTF-8 bytes, and other URI-sensitive bytes. The CSS wrapper additionally escapes raw quotes, backslashes, and control bytes before adding `url("` and `")`.

Both components use one 64 KiB memory page. They expand the input backward in the same buffer, allowing up to 20 KiB of input and 60 KiB of output without a second allocation.

Use an external SVG file instead when the image is large, shared across many pages, or should be cached independently. These components encode SVG; they do not make untrusted markup safe.
