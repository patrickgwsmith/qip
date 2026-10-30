<title>SRI hash generator (subresource integrity)</title>

# SRI hash generator

Generate the Subresource Integrity (SRI) hash for a script, stylesheet or any
other file, ready to paste into an `integrity` attribute. Files are hashed
locally in your browser and never uploaded. Each algorithm is its own QIP
component:
<a href="/bytes/bytes-to-sri-sha256.wasm" download><qip-content-size src="/bytes/bytes-to-sri-sha256.wasm"></qip-content-size> for SHA-256</a>,
<a href="/bytes/bytes-to-sri-sha384.wasm" download><qip-content-size src="/bytes/bytes-to-sri-sha384.wasm"></qip-content-size> for SHA-384</a>
and <a href="/bytes/bytes-to-sri-sha512.wasm" download><qip-content-size src="/bytes/bytes-to-sri-sha512.wasm"></qip-content-size> for SHA-512</a>.

<style>
.tool-grid {
  display: grid;
  gap: 1rem;
}
@media (min-width: 860px) {
  .tool-grid { grid-template-columns: 1fr 1fr; }
}
.tool-panel {
  display: grid;
  gap: 0.5rem;
  align-content: start;
}
.tool-panel textarea {
  box-sizing: border-box;
  min-height: 14rem;
  width: 100%;
  resize: vertical;
  font: inherit;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
}
.tool-panel textarea.sri-dragging {
  outline: 2px dashed currentColor;
}
.tool-panel input[type="url"] {
  box-sizing: border-box;
  width: 100%;
}
#sri-value, #sri-snippet {
  min-height: 0;
}
#sri-value {
  height: 5rem;
}
#sri-snippet {
  height: 7rem;
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

<div class="tool-grid">
  <div class="tool-panel">
    <label class="tool-panel">
      <strong>Text</strong>
      <textarea id="sri-text" spellcheck="false">console.log("hello wasm");</textarea>
    </label>
    <label class="tool-panel">
      <strong>Or choose a file</strong>
      <input id="sri-file" type="file">
    </label>
    <label class="tool-panel">
      <strong>Algorithm</strong>
      <select id="sri-algorithm">
        <option value="sha256">SHA-256</option>
        <option value="sha384" selected>SHA-384 (recommended)</option>
        <option value="sha512">SHA-512</option>
      </select>
    </label>
    <label class="tool-panel">
      <strong>URL for the snippet</strong>
      <input id="sri-url" type="url" value="https://example.com/script.js" spellcheck="false">
    </label>
  </div>
  <div class="tool-panel">
    <label class="tool-panel">
      <strong>Integrity value</strong>
      <textarea id="sri-value" readonly spellcheck="false"></textarea>
    </label>
    <label class="tool-panel">
      <strong>HTML</strong>
      <textarea id="sri-snippet" readonly spellcheck="false"></textarea>
    </label>
  </div>
</div>

<p class="tool-actions">
  <button id="sri-copy-value" type="button">Copy integrity value</button>
  <button id="sri-copy-snippet" type="button">Copy HTML</button>
  <span id="sri-status" class="tool-status" role="status"></span>
</p>

<script type="module">
import { contentComponent, contentTypeBytes, contentTypeUTF8 } from "/qip-runner.js";

const textArea = document.getElementById("sri-text");
const fileInput = document.getElementById("sri-file");
const algorithmSelect = document.getElementById("sri-algorithm");
const urlInput = document.getElementById("sri-url");
const valueArea = document.getElementById("sri-value");
const snippetArea = document.getElementById("sri-snippet");
const copyValueButton = document.getElementById("sri-copy-value");
const copySnippetButton = document.getElementById("sri-copy-snippet");
const status = document.getElementById("sri-status");
const bytes = contentTypeBytes();
const text = contentTypeUTF8();
const algorithms = ["sha256", "sha384", "sha512"];
const modules = await Promise.all(algorithms.map((name) =>
  WebAssembly.compileStreaming(fetch("/bytes/bytes-to-sri-" + name + ".wasm"))
));
const components = new Map(algorithms.map((name, index) =>
  [name, contentComponent(bytes, modules[index], text)]
));
const textEncoder = new TextEncoder();
const maxInputBytes = 16 * 1024 * 1024;
let inputBytes = textEncoder.encode(textArea.value);
let inputLabel = "text";

function escapeAttribute(value) {
  return value.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");
}

function snippetFor(url, integrity) {
  const attributes = 'integrity="' + escapeAttribute(integrity) + '" crossorigin="anonymous"';
  const path = url.split(/[?#]/)[0].toLowerCase();
  if (path.endsWith(".css")) {
    return '<link rel="stylesheet" href="' + escapeAttribute(url) + '" ' + attributes + '>';
  }
  return '<script src="' + escapeAttribute(url) + '" ' + attributes + '></' + 'script>';
}

function update() {
  if (inputBytes.length > maxInputBytes) {
    valueArea.value = "";
    snippetArea.value = "";
    status.textContent = "Input is larger than the 16 MiB limit.";
    return;
  }
  try {
    const integrity = components.get(algorithmSelect.value)(inputBytes);
    valueArea.value = integrity;
    snippetArea.value = snippetFor(urlInput.value.trim(), integrity);
    status.textContent = "Hashed " + inputBytes.length + " bytes of " + inputLabel + ".";
  } catch (error) {
    status.textContent = error instanceof Error ? error.message : String(error);
  }
}

async function useFile(file) {
  inputBytes = new Uint8Array(await file.arrayBuffer());
  inputLabel = file.name;
  if (!urlInput.value.trim() || urlInput.value.startsWith("https://example.com/")) {
    urlInput.value = "https://example.com/" + file.name;
  }
  update();
}

textArea.addEventListener("input", () => {
  inputBytes = textEncoder.encode(textArea.value);
  inputLabel = "text";
  fileInput.value = "";
  update();
});
fileInput.addEventListener("change", () => {
  const file = fileInput.files?.[0];
  if (file) useFile(file);
});
textArea.addEventListener("dragover", (event) => {
  event.preventDefault();
  textArea.classList.add("sri-dragging");
});
textArea.addEventListener("dragleave", () => textArea.classList.remove("sri-dragging"));
textArea.addEventListener("drop", (event) => {
  event.preventDefault();
  textArea.classList.remove("sri-dragging");
  const file = event.dataTransfer?.files?.[0];
  if (file) useFile(file);
});
algorithmSelect.addEventListener("change", update);
urlInput.addEventListener("input", update);
copyValueButton.addEventListener("click", async () => {
  await navigator.clipboard.writeText(valueArea.value);
  status.textContent = "Copied integrity value.";
});
copySnippetButton.addEventListener("click", async () => {
  await navigator.clipboard.writeText(snippetArea.value);
  status.textContent = "Copied HTML.";
});
update();
</script>

Paste text or choose a file (you can also drop one onto the text box). The text
is hashed as UTF-8 exactly as typed, so a trailing newline changes the hash.
For a file you serve, choose the file itself rather than pasting it.

## Which algorithm?

Browsers support SHA-256, SHA-384 and SHA-512 in the `integrity` attribute.
SHA-384 is the common choice and what most CDNs publish. You can list more than
one value separated by spaces, but browsers only check the strongest algorithm
listed, so a single value is enough.

A cross-origin script or stylesheet also needs `crossorigin="anonymous"`, and
the server must send CORS headers, or the browser refuses to load it. The same
values appear in npm, Yarn, pnpm and Bun lockfiles (as `sha512-…`), in Nix
hashes and in the `integrity` field of import maps.

## Download

- <a href="/bytes/bytes-to-sri-sha256.wasm" download>bytes-to-sri-sha256.wasm</a> — <qip-content-size src="/bytes/bytes-to-sri-sha256.wasm"></qip-content-size>
- <a href="/bytes/bytes-to-sri-sha384.wasm" download>bytes-to-sri-sha384.wasm</a> — <qip-content-size src="/bytes/bytes-to-sri-sha384.wasm"></qip-content-size>
- <a href="/bytes/bytes-to-sri-sha512.wasm" download>bytes-to-sri-sha512.wasm</a> — <qip-content-size src="/bytes/bytes-to-sri-sha512.wasm"></qip-content-size>

## CLI equivalent

```bash
npx @qip.dev/qipx qip.dev run bytes/bytes-to-sri-sha384.wasm < script.js
```

qipx downloads the component from qip.dev and saves it at
`bytes/bytes-to-sri-sha384.wasm`. Each component reads up to 16 MiB of any bytes and writes the integrity value
as text with no trailing newline, such as
`sha384-ywB1P0WjXou1oD1pmsZQBycsMqsO3tFjGotgWkP/W+2AhgcroefMI1i67KE0yCWn` for
`abc`. The digest uses standard padded Base64 (`+`, `/` and `=`), as SRI
requires, not the URL-safe alphabet.
