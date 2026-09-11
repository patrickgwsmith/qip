<title>CSS minifier</title>

# CSS minifier

Paste CSS and minify it locally with a QIP component.

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
    <strong>CSS</strong>
    <textarea id="css-input" spellcheck="false">/* Card styles */
.card > a {
  color: red;
  margin: 0;
}</textarea>
  </label>
  <label class="tool-panel">
    <strong>Minified CSS</strong>
    <textarea id="css-output" spellcheck="false" readonly></textarea>
  </label>
</div>

<p class="tool-actions">
  <button id="css-minify" type="button">Minify</button>
  <button id="css-copy" type="button">Copy</button>
  <span id="css-status" class="tool-status" role="status"></span>
</p>

<script type="module">
import { contentComponent, contentTypeUTF8 } from "/qip-runner.js";

const input = document.getElementById("css-input");
const output = document.getElementById("css-output");
const minifyButton = document.getElementById("css-minify");
const copyButton = document.getElementById("css-copy");
const status = document.getElementById("css-status");
const text = contentTypeUTF8();
const componentModule = await WebAssembly.compileStreaming(fetch("/text/css/css-minify.wasm"));
const minifyCSSComponent = contentComponent(text, componentModule, text);

function minifyCSS() {
  try {
    output.value = minifyCSSComponent(input.value);
    status.textContent = "Minified.";
  } catch (error) {
    status.textContent = error instanceof Error ? error.message : String(error);
  }
}

minifyButton.addEventListener("click", minifyCSS);
copyButton.addEventListener("click", async () => {
  await navigator.clipboard.writeText(output.value);
  status.textContent = "Copied.";
});
input.addEventListener("input", minifyCSS);
minifyCSS();
</script>

## CLI equivalent

```bash
qip run text/css/css-minify.wasm < style.css > style.min.css
```
