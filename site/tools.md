<title>QIP Tools</title>

<style>
    main {
        ul {
            margin: 0;
            padding: 0;
            list-style: none;
        }
        ul li {
            margin-top: 1lh;
        }
    }
</style>

# QIP Tools

Tools that run entirely in your browser. Nothing is uploaded. You can download the same `.wasm` files to run in JavaScript or in your terminal. Powered by [QIP content components](/docs/component-contract). For reusable behavior tests, see the [Compliance oracle downloads](/oracles).

Browse the complete lists of [`text/*` components](/text) and [`image/*` components](/image) when you need the reusable module rather than a browser interface.

- [Markdown to HTML](/markdown-to-html) renders either GitHub Flavored Markdown or CommonMark 0.31.2.
- [Open Graph image maker](/og-image) previews a title and subtitle in Inter Display and DejaVu Sans Mono, then downloads self-contained SVG.
- [QR code maker](/qr) turns a URL into a downloadable SVG QR code.
- [Mermaid to Unicode box art](/mermaid) converts a strict Mermaid subset into terminal-style diagrams and styled HTML.
- [Currency formatter](/currency) formats decimal amounts using a selected locale and ISO 4217 currency.
- [Unicode transforms](/unicode) applies Unicode 17 uppercase and lowercase mappings to pasted text.
- [JSON prettifier](/json-prettify) validates and indents JSON.
- [Base64 encoder and decoder](/base64) converts text or bytes to and from Base64.
- [PDF to text](/pdf) extracts positioned text from born-digital PDFs locally.
- [Favicon generator](/favicon) converts a PNG or BMP into a `favicon.ico`.
- [BMP to WebP encoder](/webp) produces lossy or exact lossless WebP locally.
- [Image compressor](/image-compress) compares lossy WebP, AVIF, and JPEG encodes locally, ordered by file size.
- [High-quality image resizer](/image-resize) uses Lanczos3 for reduction and Mitchell-Netravali bicubic reconstruction for enlargement.
- [WebP to PNG or BMP](/webp-to-png) decodes static lossy or lossless WebP locally.
- [Syntax highlighter](/syntax-highlight) turns pasted code into self-contained highlighted HTML.
- [Syntax highlight comparison](/syntax-highlight-comparison) compares QIP with gpu-lexer, Sugar High, Prism, Starry Night, and Shiki.
- [HTML accessibility tree](/accessibility-tree) shows the roles and accessible names screen readers compute from your HTML.
- [CSS minifier](/css-minifier) removes unnecessary CSS whitespace and comments.
- [CSS expression calculator](/css-expression-calculator) resolves viewport units, safe-area insets, and keyboard insets for editable mobile scenarios.
- [IEEE 754 floating-point inspector](/ieee-754-floats) exposes the sign, exponent, and fraction bits of editable `f32` and `f64` values.
- [WebAssembly module inspector](/wasm-inspector) measures module structure, memory, control flow, calls, SIMD, and potentially trapping instructions.
- [QIP component debugger](/component-debugger) interprets a scalar QIP component one WebAssembly instruction at a time and shows its call stack, operand stack, memory activity, and loop counts as plain text.
- [Shadow rendering comparison](/shadow-rendering) compares adjustable shadows across browsers, mobile platforms, Figma, and Photoshop.
- [SVG data URI](/svg-data-uri) percent-encodes SVG bytes for HTML or CSS.
