<title>HTML accessibility tree</title>

# HTML accessibility tree

Paste HTML and see its accessibility tree — the roles and accessible names a
screen reader works from — computed locally in
<a href="/text/html/html-to-accessibility-tree.wasm" download><qip-content-size src="/text/html/html-to-accessibility-tree.wasm"></qip-content-size>
of WebAssembly</a>.

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
</style>

<div class="tool-grid">
  <label class="tool-panel">
    <strong>HTML</strong>
    <textarea id="a11y-input" spellcheck="false"><header><nav aria-label="Main"><a href="/">Home</a> <a href="/pricing">Pricing</a></nav></header>
<main>
  <h1>Checkout</h1>
  <form>
    <label>Email <input type="email"></label>
    <button>Pay now</button>
  </form>
</main></textarea>
  </label>
  <label class="tool-panel">
    <strong>Accessibility tree</strong>
    <textarea id="a11y-output" spellcheck="false" readonly></textarea>
  </label>
</div>

<p class="tool-actions">
  <click-notify animate><button id="a11y-copy" type="button">Copy</button></click-notify>
</p>

<script type="module">
import "/click-notify.js";
import "/aria-notify.js";
import { contentComponent, contentTypeUTF8 } from "/qip-runner.js";

const input = document.getElementById("a11y-input");
const output = document.getElementById("a11y-output");
const copyButton = document.getElementById("a11y-copy");
const html = contentTypeUTF8("text/html");
const markdown = contentTypeUTF8("text/markdown");
const componentModule = await WebAssembly.compileStreaming(fetch("/text/html/html-to-accessibility-tree.wasm"));
const accessibilityTreeComponent = contentComponent(html, componentModule, markdown);

function computeTree() {
  try {
    output.value = accessibilityTreeComponent(input.value);
  } catch (error) {
    output.value = error instanceof Error ? error.message : String(error);
  }
}

copyButton.addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(output.value);
    copyButton.dispatchEvent(new CustomEvent("qip:success", { bubbles: true, detail: "Copied" }));
  } catch {
    copyButton.dispatchEvent(new CustomEvent("qip:failed", { bubbles: true, detail: "Copy failed" }));
  }
});
input.addEventListener("input", computeTree);
computeTree();
</script>

The tree is Markdown: one list item per accessible node, `` `role` `` then
**accessible name**. Content that produces no accessible node — wrapper
`div`s, unlabeled decoration, `aria-hidden` subtrees — simply doesn't appear,
which is the point: if a control is missing here, a screen reader can't reach
it either. Handles documents up to 256 KiB.

## Download

- <a href="/text/html/html-to-accessibility-tree.wasm" download>html-to-accessibility-tree.wasm</a> — <qip-content-size src="/text/html/html-to-accessibility-tree.wasm"></qip-content-size>

## CLI equivalent

```bash
npx qipdo qip.dev text/html/html-to-accessibility-tree.wasm < page.html
```
