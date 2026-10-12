<title>Favicon generator</title>

# Favicon generator

Convert a PNG or BMP up to 256×256 into a `favicon.ico` locally in your
browser, in
<a href="/image/png/png-to-bmp-b8g8r8a8-srgb.wasm" download><qip-content-size src="/image/png/png-to-bmp-b8g8r8a8-srgb.wasm"></qip-content-size></a>
plus <a href="/image/bmp/bmp-to-ico.wasm" download><qip-content-size src="/image/bmp/bmp-to-ico.wasm"></qip-content-size> of WebAssembly</a>.

<style>
.file-tool {
  display: grid;
  gap: 1rem;
}
.file-tool input,
.file-tool button {
  font: inherit;
}
.preview {
  width: 4rem;
  height: 4rem;
  image-rendering: pixelated;
  border: 1px solid color-mix(in srgb, currentColor 20%, transparent);
}
.tool-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  align-items: center;
}
.tool-status {
  min-height: 1.5rem;
}
</style>

<div class="file-tool">
  <label>
    <strong>PNG or BMP</strong><br>
    <input id="favicon-input" type="file" accept="image/png,image/bmp,.png,.bmp" />
  </label>
  <p class="tool-actions">
    <button id="favicon-download" type="button" disabled>Download favicon.ico</button>
    <span id="favicon-status" class="tool-status" role="status"></span>
  </p>
  <img id="favicon-preview" class="preview" alt="" hidden />
</div>

<script type="module">
import { contentComponent, contentTypeBytes } from "/qip-runner.js";

const fileInput = document.getElementById("favicon-input");
const downloadButton = document.getElementById("favicon-download");
const status = document.getElementById("favicon-status");
const preview = document.getElementById("favicon-preview");
const bytes = contentTypeBytes();
const [pngToBmpModule, bmpToIcoModule] = await Promise.all([
  WebAssembly.compileStreaming(fetch("/image/png/png-to-bmp-b8g8r8a8-srgb.wasm")),
  WebAssembly.compileStreaming(fetch("/image/bmp/bmp-to-ico.wasm")),
]);
const pngToBmpComponent = contentComponent(bytes, pngToBmpModule, bytes);
const bmpToIcoComponent = contentComponent(bytes, bmpToIcoModule, bytes);
let currentUrl = "";

function isPNG(data) {
  return data.length > 8 && data[0] === 0x89 && data[1] === 0x50 && data[2] === 0x4e && data[3] === 0x47;
}

function isBMP(data) {
  return data.length > 2 && data[0] === 0x42 && data[1] === 0x4d;
}

fileInput.addEventListener("change", async () => {
  const file = fileInput.files?.[0];
  if (!file) return;
  try {
    const input = new Uint8Array(await file.arrayBuffer());
    let bmp;
    if (isPNG(input)) {
      bmp = pngToBmpComponent(input);
      if (bmp.length === 0) {
        throw Error("Unsupported PNG: must be 8 bits per channel and non-interlaced.");
      }
    } else if (isBMP(input)) {
      bmp = input;
    } else {
      throw Error("Choose a PNG or BMP file.");
    }
    const ico = bmpToIcoComponent(bmp);
    if (ico.length === 0) {
      throw Error("Image must be between 1×1 and 256×256 pixels.");
    }
    if (currentUrl !== "") {
      URL.revokeObjectURL(currentUrl);
    }
    const blob = new Blob([ico], { type: "image/x-icon" });
    currentUrl = URL.createObjectURL(blob);
    preview.src = currentUrl;
    preview.hidden = false;
    downloadButton.disabled = false;
    status.textContent = "favicon.ico ready (" + ico.length + " bytes).";
  } catch (error) {
    downloadButton.disabled = true;
    preview.hidden = true;
    status.textContent = error instanceof Error ? error.message : String(error);
  }
});

downloadButton.addEventListener("click", () => {
  if (currentUrl === "") return;
  const link = document.createElement("a");
  link.href = currentUrl;
  link.download = "favicon.ico";
  link.click();
});
</script>

The `.ico` holds one 32-bit BGRA image at the source size, with transparency
preserved. Browsers scale a single 32×32 or 64×64 entry well; keep the source
square for best results.

## Download

- <a href="/image/png/png-to-bmp-b8g8r8a8-srgb.wasm" download>png-to-bmp-b8g8r8a8-srgb.wasm</a> — <qip-content-size src="/image/png/png-to-bmp-b8g8r8a8-srgb.wasm"></qip-content-size>
- <a href="/image/bmp/bmp-to-ico.wasm" download>bmp-to-ico.wasm</a> — <qip-content-size src="/image/bmp/bmp-to-ico.wasm"></qip-content-size>

## CLI equivalent

```bash
qip run image/png/png-to-bmp-b8g8r8a8-srgb.wasm image/bmp/bmp-to-ico.wasm \
  < icon.png > favicon.ico
```

An SVG works too, rasterized at its declared size (doubling is optional):

```bash
qip run image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm image/bmp/bmp-double.wasm \
  image/bmp/bmp-to-ico.wasm < icon.svg > favicon.ico
```
