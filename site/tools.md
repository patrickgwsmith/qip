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

These tools process input in your browser. Nothing is uploaded unless a tool is marked as a network tool; its page explains what it sends. You can download the same `.wasm` files to run in JavaScript or in your terminal. Powered by [QIP content components](/docs/component-contract). For reusable behavior tests, see the [Compliance oracle downloads](/oracles).

Browse the complete lists of [`text/*` components](/text), [`image/*` components](/image), and [`audio/*` components](/audio) when you need the reusable module rather than a browser interface.

- [Markdown to HTML](/markdown-to-html) renders either GitHub Flavored Markdown or CommonMark 0.31.2.
- [Open Graph image](/image/og-image) previews a title and subtitle in Inter Display and DejaVu Sans Mono, then downloads self-contained SVG.
- [QR code](/image/qr) turns a URL into a downloadable SVG QR code.
- [Emoji finder](/emoji) searches emoji by name, emoji, or code point and shows Unicode details.
- [Mermaid to Unicode box art](/mermaid) converts a strict Mermaid subset into terminal-style diagrams and styled HTML.
- [Currency formatter](/currency) formats decimal amounts using a selected locale and ISO 4217 currency.
- [Unicode transforms](/unicode) applies Unicode 17 uppercase and lowercase mappings to pasted text.
- [JSON prettifier](/json-prettify) validates and indents JSON.
- [Base64 encoder and decoder](/base64) converts text or bytes to and from Base64.
- [SRI hash generator](/sri) outputs the subresource integrity value for a script, stylesheet or file, with a copy-ready `integrity` attribute.
- [AWS SigV4 request signer](/sigv4) outputs the signed headers for an AWS request without sending it.
- **Network tool:** [DNS over HTTPS lookup](/dns) sends a selected DNS question to Cloudflare or Google and decodes the reply like `dig`.
- [PDF to text](/pdf) extracts positioned text from born-digital PDFs locally.
- [Convert to favicon](/image/favicon) converts a PNG or BMP into a `favicon.ico`.
- [Convert to WebP](/image/convert-to-webp) converts JPEG, PNG, AVIF, WebP, or BMP to lossy or exact lossless WebP locally.
- [Compress image](/image/compress) compares lossy WebP, AVIF, JPEG, and JPEG XL encodes locally, ordered by file size.
- [Resize image](/image/resize) uses Lanczos3 for reduction and Mitchell-Netravali bicubic reconstruction for enlargement.
- [Convert WebP to PNG](/image/webp-to-png) decodes static lossy or lossless WebP locally.
- [WAV to MP3 encoder](/mp3) encodes 16-bit PCM WAV to constant-bitrate MP3 locally with LAME.
- [Syntax highlighter](/syntax-highlight) turns pasted code into self-contained highlighted HTML.
- [Syntax highlight comparison](/syntax-highlight-comparison) compares QIP with gpu-lexer, Sugar High, Prism, Starry Night, and Shiki.
- [HTML accessibility tree](/accessibility-tree) shows the roles and accessible names screen readers compute from your HTML.
- [CSS minifier](/css-minifier) removes unnecessary CSS whitespace and comments.
- [CSS expression calculator](/css-expression-calculator) resolves viewport units, safe-area insets, and keyboard insets for editable mobile scenarios.
- [IEEE 754 floating-point inspector](/ieee-754-floats) exposes the sign, exponent, and fraction bits of editable `f32` and `f64` values.
- [WebAssembly module inspector](/wasm-inspector) measures module structure, memory, control flow, calls, SIMD, and potentially trapping instructions.
- [WGSL shaders](/wgsl) runs compute and fragment image effects with WebGPU and as compiled WebAssembly, then compares the outputs bit for bit.
- [QIP component debugger](/component-debugger) interprets a scalar QIP component one WebAssembly instruction at a time and shows its call stack, operand stack, memory activity, and loop counts as plain text.
- [Shadow rendering comparison](/shadow-rendering) compares adjustable shadows across browsers, mobile platforms, Figma, and Photoshop.
- [Encode SVG as data URI](/image/svg-data-uri) percent-encodes SVG bytes for HTML or CSS.
