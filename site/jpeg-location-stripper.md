<title>JPEG location stripper</title>

# JPEG location stripper

Remove GPS EXIF metadata from a JPEG locally with a QIP component.

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
  max-width: min(100%, 42rem);
  height: auto;
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
    <strong>JPEG</strong><br>
    <input id="jpeg-input" type="file" accept="image/jpeg" />
  </label>
  <p class="tool-actions">
    <button id="jpeg-download" type="button" disabled>Download cleaned JPEG</button>
    <span id="jpeg-status" class="tool-status" role="status"></span>
  </p>
  <img id="jpeg-preview" class="preview" alt="" hidden />
</div>

<script type="module">
import { contentComponent, contentTypeBytes } from "/qip-runner.js";

const fileInput = document.getElementById("jpeg-input");
const downloadButton = document.getElementById("jpeg-download");
const status = document.getElementById("jpeg-status");
const preview = document.getElementById("jpeg-preview");
const bytes = contentTypeBytes();
const componentModule = await WebAssembly.compileStreaming(fetch("/image/jpeg/jpeg-strip-gps-exif.wasm"));
const stripGPSComponent = contentComponent(bytes, componentModule, bytes);
let currentUrl = "";
let currentName = "cleaned.jpg";

function setDownload(bytes, name) {
  if (currentUrl !== "") {
    URL.revokeObjectURL(currentUrl);
  }
  const blob = new Blob([bytes], { type: "image/jpeg" });
  currentUrl = URL.createObjectURL(blob);
  currentName = name.replace(/\.jpe?g$/i, "") + "-clean.jpg";
  preview.src = currentUrl;
  preview.hidden = false;
  downloadButton.disabled = false;
}

fileInput.addEventListener("change", async () => {
  const file = fileInput.files?.[0];
  if (!file) return;
  try {
    const inputBytes = new Uint8Array(await file.arrayBuffer());
    const result = stripGPSComponent(inputBytes);
    setDownload(result, file.name);
    status.textContent = "Cleaned JPEG ready.";
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
  link.download = currentName;
  link.click();
});
</script>

## CLI equivalent

```bash
qip run image/jpeg/jpeg-strip-gps-exif.wasm < photo.jpg > photo-clean.jpg
```
