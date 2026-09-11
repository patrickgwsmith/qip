<title>URL to QR code SVG</title>

# QR code generator

<form aria-labelledby="form-qr-url-heading">
    <h2 id="form-qr-url-heading">URL to QR Code SVG</h2>
    <qip-edit>
        <source src="/text/uri-list/url-to-qr-svg.wasm" type="application/wasm" />
        <input
            type="url"
            name="input"
            value="https://example.com"
            placeholder="Type or paste a URL"
            spellcheck="false"
            style="min-width: 100%; border-radius: 0; border: none; padding: 0.5em 1em;"
        />
        <output name="output"><img alt="QR code SVG preview" /></output>
    </qip-edit>
</form>

## CLI equivalent

```bash
go install github.com/royalicing/qip@latest

echo "https://example.com" \
| qip run text/uri-list/url-to-qr-svg.wasm \
> qr.svg
```

This module expects `text/uri-list` and outputs `image/svg+xml`.
