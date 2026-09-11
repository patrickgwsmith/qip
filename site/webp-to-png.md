<title>WebP to PNG or BMP</title>

# WebP to PNG or BMP

Convert a WebP image to PNG or BMP locally in your browser. The image is not uploaded to a server.

<style>
.webp-decode-tool {
  display: grid;
  gap: 1rem;
}
.webp-decode-tool input,
.webp-decode-tool select,
.webp-decode-tool button {
  font: inherit;
}
.webp-decode-options {
  display: flex;
  flex-wrap: wrap;
  gap: 0.75rem;
  align-items: end;
}
.webp-decode-options label {
  display: grid;
  gap: 0.25rem;
}
.webp-decode-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  align-items: center;
}
.webp-decode-status {
  min-height: 1.5rem;
}
.webp-decode-preview {
  display: block;
  max-width: 100%;
  max-height: 36rem;
  object-fit: contain;
  border: 1px solid color-mix(in srgb, currentColor 20%, transparent);
}
.webp-decode-meta {
  font-variant-numeric: tabular-nums;
}
</style>

<div class="webp-decode-tool">
  <label>
    <strong>WebP</strong><br>
    <input id="webp-decode-input" type="file" accept="image/webp,.webp">
  </label>
  <p id="webp-decode-meta" class="webp-decode-meta"></p>

  <div class="webp-decode-options">
    <label>Output
      <select id="webp-decode-format">
        <option value="png" selected>PNG</option>
        <option value="bmp">32-bit BGRA BMP</option>
      </select>
    </label>
  </div>

  <p class="webp-decode-actions">
    <button id="webp-decode-convert" type="button" disabled>Convert</button>
    <button id="webp-decode-cancel" type="button" disabled>Cancel</button>
    <button id="webp-decode-download" type="button" disabled>Download</button>
  </p>
  <p id="webp-decode-status" class="webp-decode-status" role="status"></p>

  <img id="webp-decode-preview" class="webp-decode-preview"
    alt="Selected WebP preview" hidden>
</div>

<script type="module">
const fileInput = document.getElementById("webp-decode-input");
const formatSelect = document.getElementById("webp-decode-format");
const convertButton = document.getElementById("webp-decode-convert");
const cancelButton = document.getElementById("webp-decode-cancel");
const downloadButton = document.getElementById("webp-decode-download");
const status = document.getElementById("webp-decode-status");
const meta = document.getElementById("webp-decode-meta");
const preview = document.getElementById("webp-decode-preview");

let selectedFile = null;
let inputURL = "";
let outputURL = "";
let outputName = "output.png";
let worker = null;

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} bytes`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KiB`;
  return `${(bytes / (1024 * 1024)).toFixed(2)} MiB`;
}

function resetOutput() {
  if (outputURL !== "") URL.revokeObjectURL(outputURL);
  outputURL = "";
  downloadButton.disabled = true;
}

function finish() {
  worker = null;
  convertButton.disabled = selectedFile === null;
  cancelButton.disabled = true;
}

function publishOutput(output, format, inputName, width, height, elapsedMs, peakBytes) {
  const mime = format === "png" ? "image/png" : "image/bmp";
  outputURL = URL.createObjectURL(new Blob([output], { type: mime }));
  outputName = inputName.replace(/\.webp$/i, "") + `.${format}`;
  downloadButton.textContent = `Download ${format.toUpperCase()}`;
  downloadButton.disabled = false;
  status.textContent =
    `${width}×${height} ${format.toUpperCase()} · ` +
    `${formatBytes(output.length)} · ${(elapsedMs / 1000).toFixed(2)} s · ` +
    `decoder peak ${formatBytes(peakBytes)}.`;
  finish();
}

fileInput.addEventListener("change", () => {
  selectedFile = null;
  resetOutput();
  if (inputURL !== "") URL.revokeObjectURL(inputURL);
  inputURL = "";
  preview.hidden = true;
  meta.textContent = "";
  const file = fileInput.files?.[0];
  if (!file) {
    convertButton.disabled = true;
    status.textContent = "";
    return;
  }
  if (file.size > 64 * 1024 * 1024) {
    convertButton.disabled = true;
    status.textContent = "The WebP exceeds the component's 64 MiB input capacity.";
    return;
  }
  selectedFile = file;
  inputURL = URL.createObjectURL(file);
  preview.src = inputURL;
  preview.alt = `Preview of ${file.name}`;
  preview.hidden = false;
  preview.onload = () => {
    meta.textContent =
      `${preview.naturalWidth}×${preview.naturalHeight} · ${formatBytes(file.size)}`;
  };
  convertButton.disabled = false;
  status.textContent = "Ready to convert.";
});

formatSelect.addEventListener("change", resetOutput);

convertButton.addEventListener("click", async () => {
  if (!selectedFile || worker !== null) return;
  resetOutput();
  const format = formatSelect.value;
  const inputName = selectedFile.name;
  convertButton.disabled = true;
  cancelButton.disabled = false;
  status.textContent = `Decoding WebP and producing ${format.toUpperCase()} in a worker…`;
  try {
    const input = await selectedFile.arrayBuffer();
    worker = new Worker("/webp-decode-worker.js", { type: "module" });
    worker.onmessage = (event) => {
      if (event.data.type === "error") {
        status.textContent = event.data.message;
        finish();
        return;
      }
      const bmp = new Uint8Array(event.data.output);
      if (format === "bmp") {
        publishOutput(
          bmp,
          format,
          inputName,
          event.data.width,
          event.data.height,
          event.data.elapsedMs,
          event.data.peakBytes,
        );
        return;
      }

      const decodeResult = event.data;
      worker?.terminate();
      status.textContent = "WebP decoded. Encoding PNG in a fresh worker…";
      worker = new Worker("/bmp-to-png-worker.js", { type: "module" });
      worker.onmessage = (pngEvent) => {
        if (pngEvent.data.type === "error") {
          status.textContent = pngEvent.data.message;
          finish();
          return;
        }
        publishOutput(
          new Uint8Array(pngEvent.data.output),
          format,
          inputName,
          decodeResult.width,
          decodeResult.height,
          decodeResult.elapsedMs + pngEvent.data.elapsedMs,
          decodeResult.peakBytes,
        );
      };
      worker.onerror = (pngError) => {
        status.textContent = pngError.message || "The PNG worker failed.";
        finish();
      };
      worker.postMessage({ input: bmp.buffer }, [bmp.buffer]);
    };
    worker.onerror = (event) => {
      status.textContent = event.message || "The conversion worker failed.";
      finish();
    };
    worker.postMessage({ input }, [input]);
  } catch (error) {
    status.textContent = error instanceof Error ? error.message : String(error);
    worker?.terminate();
    finish();
  }
});

cancelButton.addEventListener("click", () => {
  worker?.terminate();
  finish();
  status.textContent = "Conversion cancelled.";
});

downloadButton.addEventListener("click", () => {
  if (outputURL === "") return;
  const link = document.createElement("a");
  link.href = outputURL;
  link.download = outputName;
  link.click();
});

addEventListener("beforeunload", () => {
  worker?.terminate();
  if (inputURL !== "") URL.revokeObjectURL(inputURL);
  if (outputURL !== "") URL.revokeObjectURL(outputURL);
});
</script>

Both output paths accept images up to 25 MP, with neither dimension above 8192
pixels. Animated WebP is rejected rather than reduced to one frame. Conversion
runs in disposable workers so the decoder and PNG encoder do not keep their
fixed Wasm memory attached to the page.

## Components

- <a href="/image/webp/webp-to-bmp-b8g8r8a8-srgb.wasm" download>webp-to-bmp-b8g8r8a8-srgb.wasm</a> — <qip-content-size src="/image/webp/webp-to-bmp-b8g8r8a8-srgb.wasm"></qip-content-size>
- <a href="/image/bmp/bmp-to-png.wasm" download>bmp-to-png.wasm</a> — <qip-content-size src="/image/bmp/bmp-to-png.wasm"></qip-content-size>

## CLI equivalent

```bash
qip run image/webp/webp-to-bmp-b8g8r8a8-srgb.wasm \
  < input.webp > output.bmp

qip run image/webp/webp-to-bmp-b8g8r8a8-srgb.wasm \
  image/bmp/bmp-to-png.wasm \
  < input.webp > output.png
```
