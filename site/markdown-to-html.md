<title>Markdown to HTML</title>

# Markdown to HTML

<style>
.tool-grid {
  display: grid;
  gap: 1rem;
}
@media (min-width: 900px) {
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
.source-output {
  display: block;
  min-height: 22rem;
  padding: 0;
  overflow: auto;
}
.source-output pre {
  min-height: 22rem;
  margin: 0;
  padding: 0.75rem;
}
.rendered-preview {
  display: block;
  min-height: 22rem;
  padding: 0;
  border: 1px solid color-mix(in srgb, currentColor 20%, transparent);
}
.rendered-preview iframe {
  display: block;
  width: 100%;
  min-height: 22rem;
  border: 0;
  background: white;
}
</style>

## GitHub Flavored Markdown

This QIP component combines CommonMark 0.31.2 with GFM tables, task lists,
strikethrough, extended autolinks, and tag filtering in
<a href="/text/markdown/gfm-commonmark.0.31.2.wasm" download><qip-content-size src="/text/markdown/gfm-commonmark.0.31.2.wasm"></qip-content-size>
of WebAssembly</a>.

<form aria-label="GitHub Flavored Markdown to HTML">
  <qip-edit>
    <source src="/text/markdown/gfm-commonmark.0.31.2.wasm" type="application/wasm" />
    <label class="tool-panel">
      <strong>GitHub-Flavored Markdown input</strong>
      <textarea name="input" spellcheck="false"># Project status&#10;&#10;| Feature | Status |&#10;| --- | --- |&#10;| Tables | Ready |&#10;| Task lists | In progress |&#10;&#10;- [x] Render CommonMark 0.31.2&#10;- [x] Add ~~plain Markdown~~ GFM&#10;- [ ] Ship it&#10;&#10;Visit https://github.github.com/gfm/</textarea>
    </label>
    <label class="tool-panel"><strong>HTML output</strong>
      <output name="output" class="rendered-preview">
        <iframe title="Rendered GFM preview" sandbox></iframe>
      </output>
    </label>
  </qip-edit>
</form>

## CommonMark 0.31.2

This QIP component is just CommonMark 0.31.2 in
<a href="/text/markdown/commonmark.0.31.2.wasm" download><qip-content-size src="/text/markdown/commonmark.0.31.2.wasm"></qip-content-size>
of WebAssembly</a>.

<form aria-label="CommonMark to HTML">
  <qip-edit>
    <source src="/text/markdown/commonmark.0.31.2.wasm" type="application/wasm" />
    <label class="tool-panel">
      <strong>CommonMark input</strong>
      <textarea name="input" spellcheck="false"># Hello from QIP&#10;&#10;This CommonMark is rendered by a browser-loaded WebAssembly component.&#10;&#10;</textarea>
    </label>
    <label class="tool-panel"><strong>HTML output</strong>
      <output name="output" class="rendered-preview">
        <iframe title="Rendered CommonMark preview" sandbox></iframe>
      </output>
    </label>
  </qip-edit>
</form>

## Download

- <a href="/text/markdown/gfm-commonmark.0.31.2.wasm" download>gfm-commonmark.0.31.2.wasm</a> — <qip-content-size src="/text/markdown/gfm-commonmark.0.31.2.wasm"></qip-content-size>
- <a href="/text/markdown/commonmark.0.31.2.wasm" download>commonmark.0.31.2.wasm</a> — <qip-content-size src="/text/markdown/commonmark.0.31.2.wasm"></qip-content-size>

## CLI

```bash
go install github.com/royalicing/qip@latest
qip run text/markdown/gfm-commonmark.0.31.2.wasm < page.md > page.html
qip run text/markdown/commonmark.0.31.2.wasm < page.md > page.html
```

## JavaScript

<copy-code>

```js
const markdownRenderer = await WebAssembly.instantiateStreaming(
  fetch("gfm-commonmark.0.31.2.wasm"),
);
const encoder = new TextEncoder(), decoder = new TextDecoder();

function renderMarkdown(source) {
  const {
    memory,
    input_ptr,
    input_utf8_cap,
    render,
  } = markdownRenderer.instance.exports;
  const input = encoder.encode(source);
  if (input.length > input_utf8_cap()) throw new RangeError("Markdown input is too large");
  new Uint8Array(memory.buffer, input_ptr(), input.length).set(input);
  const result = BigInt.asUintN(64, render(input.length));
  if ((result >> 63n) !== 0n) throw new Error("component rejected input");
  const outputSize = Number(result & 0xffff_ffffn);
  const outputPtr = Number((result >> 32n) & 0x7fff_ffffn);
  return decoder.decode(new Uint8Array(memory.buffer, outputPtr, outputSize));
}

const markdown = `# Project status

| Feature | Status |
| --- | --- |
| Tables | Ready |
| Task lists | In progress |

- [x] Render CommonMark 0.31.2
- [x] Add ~~plain Markdown~~ GFM
- [ ] Ship it

Visit https://github.github.com/gfm/`;

document.querySelector("main article").innerHTML = renderMarkdown(markdown);
```

</copy-code>
