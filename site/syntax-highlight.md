<title>Syntax highlighter</title>

# Syntax highlighter

Paste code and convert to highlighted HTML locally in your browser.
Each language is its own small component — TypeScript’s is
<a href="/text/html/html-code-syntax-highlight-tsx.wasm" download><qip-content-size src="/text/html/html-code-syntax-highlight-tsx.wasm"></qip-content-size> of WebAssembly</a>
— chained with an HTML escaper and a Night Owl stylesheet.

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
  min-height: 18rem;
  width: 100%;
  resize: vertical;
  font: inherit;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
}
.tool-panel select {
  font: inherit;
  justify-self: start;
}
#highlight-preview {
  overflow-x: auto;
}
#highlight-preview pre {
  margin: 0;
}
details.raw-html {
  margin-block: 1rem;
}
details.raw-html summary {
  cursor: pointer;
}
details.raw-html button {
  font: inherit;
  margin-inline: 0.5rem;
}
details.raw-html textarea {
  box-sizing: border-box;
  min-height: 18rem;
  width: 100%;
  resize: vertical;
  margin-top: 0.5rem;
  font: inherit;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
}
</style>

<div class="tool-grid">
  <div class="tool-panel">
    <label for="highlight-language"><strong>Language</strong></label>
    <select id="highlight-language">
      <option value="tsx" selected>TypeScript / JavaScript / JSX</option>
      <option value="html">HTML / XML</option>
      <option value="css">CSS</option>
      <option value="go">Go</option>
      <option value="swift">Swift</option>
      <option value="ruby">Ruby</option>
      <option value="zig">Zig</option>
      <option value="c">C</option>
      <option value="bash">Bash / shell</option>
      <option value="wasm">WebAssembly text</option>
    </select>
    <label for="highlight-input"><strong>Enter code</strong></label>
    <textarea id="highlight-input" spellcheck="false">// Highlighted locally, in ~9 KB of wasm.&#10;type Size = { bytes: number };&#10;&#10;export function label({ bytes }: Size): string {&#10;  return `${(bytes / 1000).toFixed(2)} kB`;&#10;}</textarea>
  </div>
  <div class="tool-panel">
    <strong>Preview</strong>
    <div id="highlight-preview"></div>
  </div>
</div>

<details class="raw-html">
  <summary><strong>Output HTML</strong><stop-propagation><click-notify animate><button id="highlight-copy" type="button">Copy output HTML</button></click-notify></stop-propagation></summary>
  <textarea id="highlight-output" spellcheck="false" readonly></textarea>
</details>

<script type="module">
import "/stop-propagation.js";
import "/click-notify.js";
import "/aria-notify.js";
import { contentComponent, contentTypeUTF8 } from "/qip-runner.js";

const languageSelect = document.getElementById("highlight-language");
const input = document.getElementById("highlight-input");
const previewElement = document.getElementById("highlight-preview");
const output = document.getElementById("highlight-output");
const copyButton = document.getElementById("highlight-copy");
const jsExample = document.querySelector("#highlight-js-example code");
const jsExampleTemplate = jsExample.innerHTML;
const text = contentTypeUTF8();
const html = contentTypeUTF8("text/html");
const languageClasses = {
  zig: "language-zig",
  c: "language-c",
  bash: "language-bash",
  tsx: "language-tsx",
  html: "language-html",
  css: "language-css",
  go: "language-go",
  swift: "language-swift",
  ruby: "language-ruby",
  wasm: "language-wat",
};
const samples = {
  zig: 'const std = @import("std");\n\npub fn main() void {\n    // Highlighted locally, in ~7 KB of wasm.\n    std.debug.print("hello {s}\\n", .{"wasm"});\n}',
  c: '#include <stdio.h>\n\nint main(void) {\n    /* Highlighted locally, in ~6 KB of wasm. */\n    printf("hello %s\\n", "wasm");\n    return 0;\n}',
  bash: '# Highlighted locally, in ~7 KB of wasm.\nfor f in *.wasm; do\n  wc -c "$f"\ndone | sort -n',
  tsx: '// Highlighted locally, in ~9 KB of wasm.\ntype Size = { bytes: number };\n\nexport function label({ bytes }: Size): string {\n  return `${(bytes / 1000).toFixed(2)} kB`;\n}',
  html: '<!-- Highlighted locally, in ~16 KB of wasm. -->\n<nav aria-label="Main">\n  <a href="/">Home</a>\n  <a href="/tools">Tools</a>\n</nav>',
  css: '/* Highlighted locally, in ~7 KB of wasm. */\n.card:hover {\n  color: #c792ea;\n  transform: translateY(-0.125rem);\n}',
  go: 'package main\n\nimport "fmt"\n\ntype Size struct {\n\tBytes int\n}\n\nfunc (s Size) Label() string {\n\treturn fmt.Sprintf("Size: %d bytes", s.Bytes)\n}',
  swift: 'import Foundation\n\nstruct Size {\n  let bytes: Int\n}\n\nfunc label(_ size: Size) -> String {\n  "Size: \\(size.bytes) bytes"\n}',
  ruby: 'class Size\n  attr_reader :bytes\n\n  def initialize(bytes:)\n    @bytes = bytes\n  end\n\n  def label\n    "Size: #{@bytes} bytes"\n  end\nend',
  wasm: '(module\n  ;; Highlighted locally, in ~8 KB of wasm.\n  (func (export "double") (param i32) (result i32)\n    (i32.mul (local.get 0) (i32.const 2))))',
};
const languages = Object.keys(languageClasses);
const modules = await Promise.all([
  ...languages.map((language) =>
    WebAssembly.compileStreaming(
      fetch("/text/html/html-code-syntax-highlight-" + language + ".wasm"),
    ),
  ),
  WebAssembly.compileStreaming(fetch("/text/html/html-escape.wasm")),
  WebAssembly.compileStreaming(fetch("/text/html/html-add-highlight-stylesheet-night-owl.wasm")),
]);
const highlightComponents = {};
languages.forEach((language, i) => {
  highlightComponents[language] = contentComponent(html, modules[i], html);
});
const escapeComponent = contentComponent(text, modules[languages.length], html);
const stylesheetComponent = contentComponent(html, modules[languages.length + 1], html);

function replaceExampleLiteral(source, literal, value) {
  const escaped = value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
  return source.replaceAll(literal, () => escaped);
}

function updateJavaScriptExample(language) {
  const moduleName = `html-code-syntax-highlight-${language}.wasm`;
  let example = replaceExampleLiteral(
    jsExampleTemplate,
    "html-code-syntax-highlight-tsx.wasm",
    moduleName,
  );
  example = replaceExampleLiteral(example, "language-tsx", languageClasses[language]);
  jsExample.innerHTML = example;
}

function highlight() {
  const language = languageSelect.value;
  try {
    // "</code></pre" must not appear joined: the Markdown renderer would
    // end this raw-HTML script block at that line.
    const wrapped =
      '<pre><code class="' + languageClasses[language] + '">' +
      escapeComponent(input.value) +
      "</code></pre" + ">";
    const highlighted = stylesheetComponent(highlightComponents[language](wrapped));
    previewElement.innerHTML = highlighted;
    output.value = highlighted;
  } catch (error) {
    previewElement.textContent = error instanceof Error ? error.message : String(error);
    output.value = "";
  }
}

// Whatever the code box holds on load counts as the unedited sample.
let currentSample = input.value;

copyButton.addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(output.value);
    copyButton.dispatchEvent(new CustomEvent("qip:success", { bubbles: true, detail: "Copied" }));
  } catch {
    copyButton.dispatchEvent(new CustomEvent("qip:failed", { bubbles: true, detail: "Copy failed" }));
  }
});
input.addEventListener("input", highlight);
languageSelect.addEventListener("change", () => {
  const sample = samples[languageSelect.value];
  if (input.value === currentSample && sample !== undefined) {
    input.value = sample;
    currentSample = sample;
  }
  updateJavaScriptExample(languageSelect.value);
  highlight();
});
updateJavaScriptExample(languageSelect.value);
highlight();
</script>

The output embeds its own `<style>`, so it pastes straight into a blog post
or email with no external stylesheet.

## What gets parsed

These components do more than color isolated keywords. Each one keeps enough
context to recognize declarations and nested language constructs while staying
small enough to ship as a language-specific Wasm module. For example:

- function, method, class, struct, and parameter names get their own scopes;
- Swift, C#, JavaScript, Python, and Ruby interpolation is parsed inside strings;
- JavaScript template substitutions and JSX tags keep their nested highlighting;
- Bash strings can contain variables and command substitutions;
- HTML can switch into JavaScript, and CSS distinguishes selectors, properties,
  custom properties, and conditional features; and
- C preprocessor directives and WebAssembly instructions retain their internal
  structure instead of becoming one uniformly colored token.

The result uses Highlight.js class names such as `hljs-keyword`, `hljs-title`,
and `hljs-params`, so existing Highlight.js themes can style it. It is a compact
contextual parser rather than a compiler front end: malformed code is preserved
as escaped text, and it does not try to validate types or resolve names.

Each language also has a comply component containing source snippets paired
with the HTML produced by Highlight.js. The highlighter and its executable
expectations are built separately and then compared byte for byte. Adding a
special case to the parser therefore requires adding the corresponding output
to the other side of the ledger.

## JavaScript

<section id="highlight-js-example">

<copy-code>

```js
const [highlighter, escaper, stylesheet] = await Promise.all([
  WebAssembly.instantiateStreaming(
    fetch("/text/html/html-code-syntax-highlight-tsx.wasm"),
  ),
  WebAssembly.instantiateStreaming(
    fetch("/text/html/html-escape.wasm"),
  ),
  WebAssembly.instantiateStreaming(
    fetch("/text/html/html-add-highlight-stylesheet-night-owl.wasm"),
  ),
]);
const encoder = new TextEncoder(), decoder = new TextDecoder();

function run(component, source) {
  const {
    memory,
    input_ptr,
    input_utf8_cap,
    render,
  } = component.instance.exports;
  const input = encoder.encode(source);
  if (input.length > input_utf8_cap()) throw new RangeError("Input is too large");
  new Uint8Array(memory.buffer, input_ptr(), input.length).set(input);
  const result = BigInt.asUintN(64, render(input.length));
  if ((result >> 63n) !== 0n) throw new Error("component rejected input");
  const outputSize = Number(result & 0xffff_ffffn);
  const outputPtr = Number((result >> 32n) & 0x7fff_ffffn);
  return decoder.decode(new Uint8Array(memory.buffer, outputPtr, outputSize));
}

function highlight(source) {
  const escaped = run(escaper, source);
  const codeBlock =
    '<pre><code class="language-tsx">' + escaped + "</code></pre>";
  return run(stylesheet, run(highlighter, codeBlock));
}

const source = document.querySelector("#source").textContent;
document.querySelector("#highlighted").innerHTML = highlight(source);
```

</copy-code>

</section>

The language highlighter accepts HTML, so the source is escaped before it is
wrapped in a `<code>` element. The stylesheet stage makes the returned fragment
self-contained.

## Download

- <a href="/text/html/html-code-syntax-highlight-zig.wasm" download>html-code-syntax-highlight-zig.wasm</a> — <qip-content-size src="/text/html/html-code-syntax-highlight-zig.wasm"></qip-content-size>
- <a href="/text/html/html-code-syntax-highlight-c.wasm" download>html-code-syntax-highlight-c.wasm</a> — <qip-content-size src="/text/html/html-code-syntax-highlight-c.wasm"></qip-content-size>
- <a href="/text/html/html-code-syntax-highlight-bash.wasm" download>html-code-syntax-highlight-bash.wasm</a> — <qip-content-size src="/text/html/html-code-syntax-highlight-bash.wasm"></qip-content-size>
- <a href="/text/html/html-code-syntax-highlight-tsx.wasm" download>html-code-syntax-highlight-tsx.wasm</a> — <qip-content-size src="/text/html/html-code-syntax-highlight-tsx.wasm"></qip-content-size>
- <a href="/text/html/html-code-syntax-highlight-html.wasm" download>html-code-syntax-highlight-html.wasm</a> — <qip-content-size src="/text/html/html-code-syntax-highlight-html.wasm"></qip-content-size>
- <a href="/text/html/html-code-syntax-highlight-css.wasm" download>html-code-syntax-highlight-css.wasm</a> — <qip-content-size src="/text/html/html-code-syntax-highlight-css.wasm"></qip-content-size>
- <a href="/text/html/html-code-syntax-highlight-go.wasm" download>html-code-syntax-highlight-go.wasm</a> — <qip-content-size src="/text/html/html-code-syntax-highlight-go.wasm"></qip-content-size>
- <a href="/text/html/html-code-syntax-highlight-swift.wasm" download>html-code-syntax-highlight-swift.wasm</a> — <qip-content-size src="/text/html/html-code-syntax-highlight-swift.wasm"></qip-content-size>
- <a href="/text/html/html-code-syntax-highlight-ruby.wasm" download>html-code-syntax-highlight-ruby.wasm</a> — <qip-content-size src="/text/html/html-code-syntax-highlight-ruby.wasm"></qip-content-size>
- <a href="/text/html/html-code-syntax-highlight-wasm.wasm" download>html-code-syntax-highlight-wasm.wasm</a> — <qip-content-size src="/text/html/html-code-syntax-highlight-wasm.wasm"></qip-content-size>
- <a href="/text/html/html-escape.wasm" download>html-escape.wasm</a> — <qip-content-size src="/text/html/html-escape.wasm"></qip-content-size>
- <a href="/text/html/html-add-highlight-stylesheet-night-owl.wasm" download>html-add-highlight-stylesheet-night-owl.wasm</a> — <qip-content-size src="/text/html/html-add-highlight-stylesheet-night-owl.wasm"></qip-content-size>

## CLI equivalent

The highlighters transform whole HTML documents: each rewrites
`<pre><code class="language-…">` blocks for its language and leaves
everything else untouched, so they chain safely.

```bash
qip run text/html/html-code-syntax-highlight-zig.wasm \
  text/html/html-code-syntax-highlight-go.wasm \
  text/html/html-code-syntax-highlight-swift.wasm \
  text/html/html-code-syntax-highlight-ruby.wasm \
  text/html/html-code-syntax-highlight-css.wasm \
  text/html/html-code-syntax-highlight-bash.wasm \
  text/html/html-add-highlight-stylesheet-night-owl.wasm \
  < page.html > highlighted.html
```
