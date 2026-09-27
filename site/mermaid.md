<title>Mermaid to Unicode box art</title>

# Mermaid to Unicode box art

Render a strict Mermaid subset as terminal-style Unicode box art in
<a href="/text/vnd.mermaid/mermaid-to-unicode-html.wasm" download><qip-content-size src="/text/vnd.mermaid/mermaid-to-unicode-html.wasm"></qip-content-size>
of WebAssembly</a>. It runs locally in your browser and as a CLI.

<style>
.mermaid-examples,
.mermaid-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  align-items: center;
}
.mermaid-examples {
  margin-block: 1rem;
}
.mermaid-examples button[aria-pressed="true"] {
  color: Canvas;
  background: CanvasText;
}
.mermaid-grid {
  display: grid;
  gap: 1rem;
}
.mermaid-panel {
  display: grid;
  gap: 0.5rem;
  min-width: 0;
}
.mermaid-panel textarea {
  box-sizing: border-box;
  width: 100%;
  resize: vertical;
  font: 0.875rem/1.35 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  tab-size: 2;
}
.mermaid-output {
  box-sizing: border-box;
  min-height: 28rem;
  margin: 0;
  padding: 1rem;
  overflow: auto;
  color: #e6edf3;
  background: #14161c;
  border-radius: 0.5rem;
  font: 0.8125rem/1.2 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace !important;
  line-height: 1.2;
  font-variant-ligatures: none;
}
.mermaid-output .b  { color: #7d8590; }
.mermaid-output .n  { color: #e6edf3; }
.mermaid-output .e  { color: #6e7681; }
.mermaid-output .el { color: #e3b341; }
.mermaid-output .t  { color: #79c0ff; font-weight: bold; }
.mermaid-output .i  { font-style: italic; }
.mermaid-status {
  min-height: 1.5rem;
}
</style>

<div class="mermaid-examples" aria-label="Example diagrams">
  <button type="button" data-example="flowchart" aria-pressed="true">Flowchart</button>
  <button type="button" data-example="subgraphs" aria-pressed="false">Subgraphs</button>
  <button type="button" data-example="sequence" aria-pressed="false">Sequence</button>
  <button type="button" data-example="state" aria-pressed="false">State</button>
  <button type="button" data-example="class" aria-pressed="false">Class</button>
  <button type="button" data-example="er" aria-pressed="false">Entity relationship</button>
</div>

<div class="mermaid-grid">
  <label class="mermaid-panel">
    <strong>Mermaid source</strong>
    <textarea id="mermaid-input" rows="10" spellcheck="false" autocapitalize="off" autocorrect="off">graph TD
  Start[Request received] --> Auth{Authenticated?}
  Auth -->|yes| Rate{Rate limit OK?}
  Auth -->|no| R401[401 Unauthorized]
  Rate -->|yes| H(Handle request)
  Rate -->|no| R429[429 Too Many Requests]
  H -.-> Log[Audit log]
  H ==> Resp[200 OK]</textarea>
  </label>
  <section class="mermaid-panel" aria-labelledby="mermaid-output-heading">
    <strong id="mermaid-output-heading">Unicode box art</strong>
    <pre id="mermaid-output" class="mermaid-output" aria-live="polite"></pre>
  </section>
</div>

<p class="mermaid-actions">
  <button id="mermaid-copy" type="button">Copy as text</button>
  <button id="mermaid-copy-html" type="button">Copy as HTML</button>
  <span id="mermaid-status" class="mermaid-status" role="status"></span>
</p>

This component supports the demonstrated flowchart, subgraph, sequence, state,
class, and ER forms and traps on unsupported syntax. A top-to-bottom flowchart
can contain one rooted tree with no more than 16 nodes, 32 edges, and two
forward children per node. Solid feedback edges declared after the forward
tree can return to ancestor nodes. Longer solid arrows such as `--->` and
`---->` are accepted. Extra dashes do not increase the rank distance. The
renderer reuses right-side feedback lanes to keep cyclic graphs compact.

## Download

- <a href="/text/vnd.mermaid/mermaid-to-unicode-html.wasm" download>mermaid-to-unicode-html.wasm</a> — <qip-content-size src="/text/vnd.mermaid/mermaid-to-unicode-html.wasm"></qip-content-size>

## CLI

```sh
printf 'graph TD\n  Request --> Response\n' | npx @qip.dev/qipx qip.dev run text/vnd.mermaid/mermaid-to-unicode-html.wasm > graph.html
```

## JavaScript

<copy-code>

```js
const mermaidRenderer = await WebAssembly.instantiateStreaming(
  fetch("mermaid-to-unicode-html.wasm"),
);
const encoder = new TextEncoder(), decoder = new TextDecoder();

function renderMermaid(source) {
  const {
    memory,
    input_ptr,
    input_utf8_cap,
    render,
  } = mermaidRenderer.instance.exports;
  const input = encoder.encode(source);
  if (input.length > input_utf8_cap()) throw new RangeError("Mermaid input is too large");
  new Uint8Array(memory.buffer, input_ptr(), input.length).set(input);
  const result = BigInt.asUintN(64, render(input.length));
  if ((result >> 63n) !== 0n) throw new Error("rejected input");
  const outputSize = Number(result & 0xffff_ffffn);
  const outputPtr = Number((result >> 32n) & 0x7fff_ffffn);
  return decoder.decode(new Uint8Array(memory.buffer, outputPtr, outputSize));
}

const diagram = `graph TD
  Start[Request received] --> Auth{Authenticated?}
  Auth -->|yes| Rate{Rate limit OK?}
  Auth -->|no| R401[401 Unauthorized]
  Rate -->|yes| H(Handle request)
  Rate -->|no| R429[429 Too Many Requests]
  H -.-> Log[Audit log]
  H ==> Resp[200 OK]`;

document.querySelector("#diagram").innerHTML = renderMermaid(diagram);
```

</copy-code>

The component returns an HTML fragment containing the box art and styling spans. Insert it as HTML to preserve the colors, or use the element's `textContent` when you only need plain Unicode text.

## Notes

Inspired by [Simon Willison’s Mermaid utility](https://tools.simonwillison.net/grok-mermaid).

<script type="module">
import { contentComponent, contentTypeUTF8 } from "/qip-runner.js";

const examples = {
  flowchart: `graph TD
  Start[Request received] --> Auth{Authenticated?}
  Auth -->|yes| Rate{Rate limit OK?}
  Auth -->|no| R401[401 Unauthorized]
  Rate -->|yes| H(Handle request)
  Rate -->|no| R429[429 Too Many Requests]
  H -.-> Log[Audit log]
  H ==> Resp[200 OK]`,
  subgraphs: `flowchart LR
  subgraph Client
    UI[Browser UI] --> SW[Service worker]
  end
  subgraph Server
    API[API gateway] --> DB[Postgres]
  end
  SW -->|HTTPS| API`,
  sequence: `sequenceDiagram
  participant U as User
  participant B as Browser
  participant W as WASM module
  U->>B: Edit mermaid source
  B->>W: wasm_render_html()
  W-->>B: Unicode box art
  B-->>U: Rendered diagram`,
  state: `stateDiagram-v2
  [*] --> Idle
  Idle --> Loading : fetch
  Loading --> Ready : success
  Loading --> Error : failure
  Error --> Loading : retry
  Ready --> [*]`,
  class: `classDiagram
  class Animal {
    +String name
    +makeSound()
  }
  Animal <|-- Dog
  Animal <|-- Cat
  Dog : +fetch()`,
  er: `erDiagram
  CUSTOMER ||--o{ ORDER : places
  ORDER ||--|{ LINE_ITEM : contains
  CUSTOMER {
    string name
    string email
  }`,
};

const input = document.getElementById("mermaid-input");
const output = document.getElementById("mermaid-output");
const copyButton = document.getElementById("mermaid-copy");
const copyHtmlButton = document.getElementById("mermaid-copy-html");
const status = document.getElementById("mermaid-status");
const exampleButtons = [...document.querySelectorAll("[data-example]")];
const mermaid = contentTypeUTF8("text/vnd.mermaid");
const html = contentTypeUTF8("text/html");
const componentModule = await WebAssembly.compileStreaming(
  fetch("/text/vnd.mermaid/mermaid-to-unicode-html.wasm"),
);
const renderMermaid = contentComponent(mermaid, componentModule, html);

function render() {
  try {
    output.innerHTML = renderMermaid(input.value);
    status.textContent = "";
  } catch {
    output.replaceChildren();
    status.textContent = "Unsupported or malformed Mermaid input.";
  }
}

let renderFrame = 0;
input.addEventListener("input", () => {
  for (const button of exampleButtons) button.setAttribute("aria-pressed", "false");
  cancelAnimationFrame(renderFrame);
  renderFrame = requestAnimationFrame(render);
});

for (const button of exampleButtons) {
  button.addEventListener("click", () => {
    input.value = examples[button.dataset.example];
    for (const candidate of exampleButtons) {
      candidate.setAttribute("aria-pressed", String(candidate === button));
    }
    render();
  });
}

function showCopySucceeded(button) {
  button.classList.remove("succeeded");
  void button.offsetWidth;
  button.classList.add("succeeded");
}

for (const button of [copyButton, copyHtmlButton]) {
  button.addEventListener("animationend", () => {
    button.classList.remove("succeeded");
  });
}

async function copyOutput(button, value) {
  try {
    await navigator.clipboard.writeText(value);
    status.textContent = "";
    showCopySucceeded(button);
  } catch {
    status.textContent = "Copy failed.";
  }
}

copyButton.addEventListener("click", () => {
  copyOutput(copyButton, output.textContent);
});

copyHtmlButton.addEventListener("click", () => {
  copyOutput(copyHtmlButton, output.innerHTML);
});

render();
</script>
