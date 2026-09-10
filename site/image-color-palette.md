<title>Image color palette extractor</title>

# Image color palette extractor

Upload a BMP image and extract its dominant colors locally with a QIP component.

<style>
.palette-tool {
  display: grid;
  gap: 1rem;
}
.palette-tool input,
.palette-tool button {
  font: inherit;
}
.palette {
  display: grid;
  gap: 0.75rem;
}
.palette-color {
  display: grid;
  grid-template-columns: 4rem minmax(0, 1fr);
  gap: 0.75rem;
  align-items: center;
}
.palette-swatch {
  aspect-ratio: 1;
  border: 1px solid color-mix(in srgb, currentColor 25%, transparent);
}
.palette-code {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
}
.tool-status {
  min-height: 1.5rem;
}
</style>

<div class="palette-tool">
  <label>
    <strong>BMP image</strong><br>
    <input id="palette-input" type="file" accept="image/bmp,.bmp" />
  </label>
  <p id="palette-status" class="tool-status" role="status"></p>
  <div id="palette-output" class="palette"></div>
</div>

<script type="module">
import { contentComponent, contentTypeBytes, contentTypeUTF8 } from "/qip-runner.js";

const fileInput = document.getElementById("palette-input");
const status = document.getElementById("palette-status");
const output = document.getElementById("palette-output");
const bytes = contentTypeBytes();
const text = contentTypeUTF8();
const componentModule = await WebAssembly.compileStreaming(fetch("/image/bmp/bmp-color-palette.wasm"));
const extractPaletteComponent = contentComponent(bytes, componentModule, text);

function showPalette(tokensDocument) {
  output.replaceChildren();
  const tokens = Object.entries(tokensDocument.palette ?? {})
    .filter(([name]) => !name.startsWith("$"));
  for (const [name, token] of tokens) {
    const color = token.$value;
    const details = token.$extensions?.["dev.qip.image-palette"];
    if (!color || !details) continue;
    const row = document.createElement("div");
    row.className = "palette-color";

    const swatch = document.createElement("div");
    swatch.className = "palette-swatch";
    swatch.style.background = color.hex;

    const text = document.createElement("div");
    const code = document.createElement("div");
    code.className = "palette-code";
    code.textContent = `${name}: ${color.hex}`;
    const meta = document.createElement("div");
    meta.textContent = `${details.percent}% (${details.count} pixels)`;
    text.append(code, meta);
    row.append(swatch, text);
    output.append(row);
  }
}

fileInput.addEventListener("change", async () => {
  const file = fileInput.files?.[0];
  if (!file) return;
  try {
    const inputBytes = new Uint8Array(await file.arrayBuffer());
    const result = extractPaletteComponent(inputBytes);
    showPalette(JSON.parse(result));
    status.textContent = "Palette extracted.";
  } catch (error) {
    output.replaceChildren();
    status.textContent = error instanceof Error ? error.message : String(error);
  }
});
</script>

## CLI equivalent

```bash
qip run components/image/bmp/bmp-color-palette.wasm < image.bmp
```

The component treats the BMP channel values as sRGB and emits
[DTCG 2025.10 color tokens](https://www.designtokens.org/TR/2025.10/color/)
with the `application/design-tokens+json` content type. BMP color profiles are
outside this component's narrow input profile. Pixel counts and percentages
are available in each token's `dev.qip.image-palette` extension.
