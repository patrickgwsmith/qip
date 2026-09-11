<title>JSON prettifier</title>

# JSON prettifier

Paste JSON and format it locally with a QIP component.

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
}
.tool-panel textarea {
  box-sizing: border-box;
  min-height: 22rem;
  width: 100%;
  resize: vertical;
  font: inherit;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
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
  <label class="tool-panel">
    <strong>JSON</strong>
    <textarea id="json-input" spellcheck="false">{"name":"QIP","values":[1,true,null],"nested":{"portable":true}}</textarea>
  </label>
  <label class="tool-panel">
    <strong>Formatted JSON</strong>
    <textarea id="json-output" spellcheck="false" readonly></textarea>
  </label>
</div>

<p class="tool-actions">
  <button id="json-format" type="button">Format</button>
  <button id="json-copy" type="button">Copy</button>
  <span id="json-status" class="tool-status" role="status"></span>
</p>

<script type="module">
import { contentComponent, contentTypeUTF8 } from "/qip-runner.js";

const input = document.getElementById("json-input");
const output = document.getElementById("json-output");
const formatButton = document.getElementById("json-format");
const copyButton = document.getElementById("json-copy");
const status = document.getElementById("json-status");
const text = contentTypeUTF8();
const componentModule = await WebAssembly.compileStreaming(fetch("/application/json/json-prettify.wasm"));
const formatJSONComponent = contentComponent(text, componentModule, text);

function formatJSON() {
  try {
    output.value = formatJSONComponent(input.value);
    status.textContent = "Formatted.";
  } catch (error) {
    status.textContent = error instanceof Error ? error.message : String(error);
  }
}

formatButton.addEventListener("click", formatJSON);
copyButton.addEventListener("click", async () => {
  await navigator.clipboard.writeText(output.value);
  status.textContent = "Copied.";
});
input.addEventListener("input", formatJSON);
formatJSON();
</script>

## CLI equivalent

```bash
qip run application/json/json-prettify.wasm < input.json > formatted.json
```
