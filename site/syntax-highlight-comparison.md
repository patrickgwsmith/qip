<title>Syntax highlight comparison</title>

# JavaScript syntax highlighter in [12.7 kB](/text/javascript/js-syntax-highlight-html.wasm) of WebAssembly

`js-syntax-highlight-html.wasm` highlighted 5.56 MB of `three.min.js` in 265 ms in
Chrome and 263 ms in Node. This was 2.0 times faster than
the impressively-language-agnostic small model [gpu-lexer](https://gpu-lexer.vercel.app/) at 533 ms on the same Apple M5.
Chrome executed the component on the CPU, while gpu-lexer used WebGPU. `js-syntax-highlight-html.wasm` labels agreed with Shiki on 99.97% of non-whitespace characters.

The component accepts raw `text/javascript` and returns escaped `text/html`.
The benchmark calls its QIP Content ABI directly from JavaScript.

<style>
.syntax-summary {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 0.75rem;
}
.syntax-summary div {
  padding: 0.75rem 1rem;
  border: 1px solid color-mix(in srgb, currentColor 24%, transparent);
  background: color-mix(in srgb, var(--bg) 92%, var(--text) 8%);
}
.syntax-summary strong,
.syntax-summary span {
  display: block;
}
.syntax-summary strong {
  font-size: 1.5rem;
  line-height: 1.25;
}
.syntax-summary span {
  opacity: 0.72;
  font-size: 0.8rem;
}
.syntax-demo {
  overflow: hidden;
  border: 1px solid color-mix(in srgb, currentColor 30%, transparent);
  border-radius: 0.5rem;
  background: #011627;
  color: #d6deeb;
}
.syntax-demo-grid {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
}
.syntax-demo-panel {
  display: grid;
  grid-template-rows: auto minmax(18rem, 1fr);
  min-width: 0;
}
.syntax-demo-panel + .syntax-demo-panel {
  border-left: 1px solid #29404f;
}
.syntax-demo-label,
.syntax-demo-status {
  padding: 0.5rem 0.75rem;
  color: #9fb3c8;
  background: #071d2e;
  font-size: 0.8rem;
}
.syntax-demo-result-label {
  display: flex;
  gap: 1rem;
  justify-content: space-between;
}
.syntax-demo-time {
  color: #7fdbca;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}
.syntax-demo textarea,
.syntax-demo pre {
  box-sizing: border-box;
  width: 100%;
  min-height: 18rem;
  margin: 0;
  padding: 1rem;
  overflow: auto;
  border: 0;
  border-radius: 0;
  outline-offset: -2px;
  resize: vertical;
  white-space: pre;
  color: inherit;
  background: transparent;
  font: 0.875rem/1.55 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  tab-size: 2;
}
.syntax-demo textarea:focus-visible {
  outline: 2px solid #82aaff;
}
.syntax-demo-status {
  min-height: 2rem;
  border-top: 1px solid #29404f;
}
.syntax-comment { color: #7f8c98; font-style: italic; }
.syntax-string { color: #ecc48d; }
.syntax-number { color: #f78c6c; }
.syntax-keyword { color: #c792ea; }
.syntax-type { color: #82aaff; }
.syntax-function { color: #dcdcaa; }
.syntax-constant { color: #ff5874; }
.syntax-operator { color: #7fdbca; }
.benchmark-chart {
  padding: 1rem;
  border: 1px solid color-mix(in srgb, currentColor 24%, transparent);
}
.benchmark-chart figcaption {
  margin-bottom: 0.75rem;
  font-weight: 700;
}
.benchmark-bars {
  display: grid;
  grid-template-columns: minmax(6.5rem, auto) minmax(8rem, 1fr) minmax(5rem, auto);
  gap: 0.5rem 0.75rem;
  align-items: center;
}
.benchmark-track {
  height: 0.75rem;
  background: color-mix(in srgb, currentColor 9%, transparent);
}
.benchmark-bar {
  width: max(0.35rem, var(--bar-width));
  height: 100%;
  background: color-mix(in srgb, var(--link) 72%, currentColor 28%);
}
.benchmark-bar.qip {
  background: #7fdbca;
}
.benchmark-time {
  text-align: right;
  font-variant-numeric: tabular-nums;
}
main table {
  display: block;
  max-width: 100%;
  overflow-x: auto;
}
@media (max-width: 46rem) {
  .syntax-summary,
  .syntax-demo-grid {
    grid-template-columns: minmax(0, 1fr);
  }
  .syntax-demo-panel + .syntax-demo-panel {
    border-top: 1px solid #29404f;
    border-left: 0;
  }
  .benchmark-bars {
    grid-template-columns: minmax(5.5rem, auto) minmax(4rem, 1fr) minmax(4.5rem, auto);
    font-size: 0.8rem;
  }
}
</style>

<div class="syntax-summary" role="group" aria-label="Syntax highlighter benchmark summary">
  <div><strong>265 ms</strong><span>10× three.min.js in Chrome</span></div>
  <div><strong>99.97%</strong><span>agreement with Shiki</span></div>
  <div><strong>12.7 kB</strong><span>Wasm module</span></div>
</div>

## Try it

Edit the JavaScript. The page uses qipx to load and run the same Wasm component
used in the benchmark. The component escapes the input before the preview
inserts its HTML.

<div class="syntax-demo" id="syntax-demo">
  <div class="syntax-demo-grid">
    <label class="syntax-demo-panel">
      <span class="syntax-demo-label">JavaScript</span>
      <textarea id="syntax-demo-input" spellcheck="false">// Edit this JavaScript.&#10;async function render(items) {&#10;  const total = items.reduce((sum, value) => sum + value, 0);&#10;  return Promise.resolve({ total, ready: true });&#10;}&#10;&#10;render([1, 2, 3]);</textarea>
    </label>
    <div class="syntax-demo-panel">
      <span class="syntax-demo-label syntax-demo-result-label">
        <span>Highlighted result</span>
        <span class="syntax-demo-time" id="syntax-demo-time">— ms</span>
      </span>
      <pre tabindex="0"><code id="syntax-demo-output">Loading WebAssembly…</code></pre>
    </div>
  </div>
  <div class="syntax-demo-status" id="syntax-demo-status" role="status">Loading 12.7 kB Wasm module…</div>
</div>

<script type="module">
import {
  contentTypeUTF8,
  newComponent,
  newContentComponentContract,
  render,
} from "/qipx.mjs";

const inputElement = document.getElementById("syntax-demo-input");
const outputElement = document.getElementById("syntax-demo-output");
const statusElement = document.getElementById("syntax-demo-status");
const timeElement = document.getElementById("syntax-demo-time");
const encoder = new TextEncoder();

function formatBytes(size) {
  return size < 1000 ? `${size} B` : `${(size / 1000).toFixed(1)} kB`;
}

try {
  const response = await fetch("/text/javascript/js-syntax-highlight-html.wasm");
  if (!response.ok) throw new Error(`Wasm request returned HTTP ${response.status}`);
  const wasmBytes = await response.arrayBuffer();
  const { instance } = await WebAssembly.instantiate(wasmBytes);
  const contract = newContentComponentContract({
    label: "JavaScript syntax highlighter",
    inputType: contentTypeUTF8("text/javascript"),
    outputType: contentTypeUTF8("text/html"),
  });
  const component = newComponent(instance, contract);

  function highlight(source) {
    const inputSize = encoder.encode(source).byteLength;
    const started = performance.now();
    const result = render(component, source);
    const html = result.outputString;
    const elapsed = performance.now() - started;
    return { html, inputSize, outputSize: result.outputBytes.byteLength, elapsed };
  }

  function update() {
    try {
      const result = highlight(inputElement.value);
      outputElement.innerHTML = result.html;
      timeElement.textContent = `${result.elapsed.toFixed(3)} ms`;
      statusElement.textContent =
        `${formatBytes(result.inputSize)} JavaScript → ${formatBytes(result.outputSize)} HTML`;
    } catch (error) {
      outputElement.textContent = inputElement.value;
      timeElement.textContent = "Error";
      statusElement.textContent = error instanceof Error ? error.message : String(error);
    }
  }

  let animationFrame = 0;
  inputElement.addEventListener("input", () => {
    cancelAnimationFrame(animationFrame);
    animationFrame = requestAnimationFrame(update);
  });
  update();
} catch (error) {
  outputElement.textContent = inputElement.value;
  timeElement.textContent = "Error";
  statusElement.textContent = error instanceof Error ? error.message : String(error);
}
</script>

<p><a href="/text/javascript/js-syntax-highlight-html.wasm" download>Download <code>js-syntax-highlight-html.wasm</code> (<qip-content-size src="/text/javascript/js-syntax-highlight-html.wasm"></qip-content-size>)</a></p>

## Run in qipx cli

```sh
npx @qip.dev/qipx qip.dev run -i input.js \
  text/javascript/js-syntax-highlight-html.wasm \
  -o highlighted.html
```

## Run in JavaScript

With a bundler that supports WebAssembly ES module integration, wrap the
component in a JavaScript module:

```js
import {
  memory,
  input_ptr,
  input_utf8_cap,
  render,
} from "./js-syntax-highlight-html.wasm";

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

export function highlightJavaScript(source) {
  const input = new Uint8Array(memory.buffer, input_ptr(), input_utf8_cap());
  const { read, written } = encoder.encodeInto(source, input);
  if (read !== source.length) {
    throw new RangeError(`Input exceeds the component capacity of ${input.byteLength} bytes`);
  }

  const result = render(written);
  const output = new Uint8Array(memory.buffer, Number((result >> 32n) & 0x7fff_ffffn), Number(result & 0xffff_ffffn));
  return decoder.decode(output);
}
```

## Speed comparison

<figure class="benchmark-chart">
  <figcaption>Time to highlight 10× three.min.js · lower is better</figcaption>
  <div class="benchmark-bars">
    <span>js-syntax-highlight-html.wasm</span><div class="benchmark-track"><div class="benchmark-bar qip" style="--bar-width: 0.77%"></div></div><span class="benchmark-time">265 ms</span>
    <span><a href="https://gpu-lexer.vercel.app/">gpu-lexer</a></span><div class="benchmark-track"><div class="benchmark-bar" style="--bar-width: 1.54%"></div></div><span class="benchmark-time">533 ms</span>
    <span>Sugar High</span><div class="benchmark-track"><div class="benchmark-bar" style="--bar-width: 3.61%"></div></div><span class="benchmark-time">1.25 s</span>
    <span>Prism</span><div class="benchmark-track"><div class="benchmark-bar" style="--bar-width: 5.29%"></div></div><span class="benchmark-time">1.83 s</span>
    <span>Starry Night</span><div class="benchmark-track"><div class="benchmark-bar" style="--bar-width: 38.13%"></div></div><span class="benchmark-time">13.19 s</span>
    <span>Shiki</span><div class="benchmark-track"><div class="benchmark-bar" style="--bar-width: 100%"></div></div><span class="benchmark-time">34.59 s</span>
  </div>
</figure>

The input was ten copies of
[`three@0.97.0/build/three.min.js`](https://unpkg.com/three@0.97.0/build/three.min.js),
or 5,556,500 bytes. The browser test used CPU WebAssembly in headless Chrome
152 with V8 15.2.124.21. The Node tests used Node.js 26.8.1 and V8
14.6.202.34. All tests ran sequentially on a MacBook Air with an Apple M5, a
10-core GPU, 24 GB of memory, and macOS 26.6.2. Each highlighter had one warm-up
run. The Wasm component and gpu-lexer had 40 measured runs in four batches. The
batch means were 238 to 301 ms for the Wasm component and 497 to 548 ms for
gpu-lexer. Sugar High and Prism had ten measured runs. Starry Night and Shiki
had three because each run took more than ten seconds. The gpu-lexer test used
[version 0.0.2](https://www.npmjs.com/package/gpu-lexer/v/0.0.2).

| Highlighter | Mean | Runtime | Input | Returned value |
| --- | ---: | --- | --- | --- |
| [`js-syntax-highlight-html.wasm`](/text/javascript/js-syntax-highlight-html.wasm) | 265 ms | Chrome/WebAssembly CPU | 5.56 MB raw JavaScript | 26.09 MB HTML |
| [`js-syntax-highlight-html.wasm`](/text/javascript/js-syntax-highlight-html.wasm) | 263 ms | Node/V8 | 5.56 MB raw JavaScript | 26.09 MB HTML |
| [gpu-lexer](https://gpu-lexer.vercel.app/) 0.0.2 | 533 ms | Chrome/WebGPU | 5.56 MB raw JavaScript | 1,054,839 token ranges |
| [Sugar High 2.3.1](https://github.com/huozhi/sugar-high) | 1.25 s | Node/V8 | 5.56 MB raw JavaScript | 147.50 MB HTML |
| [Prism 1.30.0](https://github.com/PrismJS/prism) | 1.83 s | Node/V8 | 5.56 MB raw JavaScript | 59.11 MB HTML |
| [Starry Night 3.11.0](https://github.com/wooorm/starry-night) | 13.19 s | Node/V8 | 5.56 MB raw JavaScript | HAST with 1,485,453 nodes |
| Shiki 4.4.3 | 34.59 s | Node/V8 | 5.56 MB raw JavaScript | 1,160,820 tokens |

These libraries return different data structures. HTML generators allocate and
copy markup. Starry Night builds a syntax tree. Shiki returns detailed tokens.
gpu-lexer returns source ranges. The table measures the complete returned value,
not token recognition alone.

### Why the component returns less HTML

The component copies plain identifiers, whitespace, and punctuation without
wrappers. It adds a flat `span` only to comments, strings, numbers, keywords,
types, functions, constants, and operators. Each highlighted run adds 33 to 37
bytes of markup. The component adds no line wrappers, inline styles, or nested
token elements.

Sugar High wraps every token and every line. Its default token markup contains
both a class and an inline color style. Prism also wraps punctuation and can
produce nested token spans. Those choices support their styling models, but
they create more markup for punctuation-heavy minified code.

For this input, the component's 26.09 MB result was 56% smaller than Prism's
HTML and 82% smaller than Sugar High's HTML. Its output is still 4.7 times
larger than the source because `three.min.js` contains many short highlighted
tokens.

## Agreement with Shiki

Shiki 4.4.3 is the reference when the component and another highlighter
disagree. The score maps Shiki's TextMate scopes and the component's HTML
classes to the nine token types used by gpu-lexer: plain, comment, string,
number, keyword, type, function, constant, and operator.

| Fixture | Bytes | Shiki agreement |
| --- | ---: | ---: |
| [React 19.2.8 development](https://unpkg.com/react@19.2.8/cjs/react.development.js) | 47,219 | 100.00% |
| [`three.min.js`](https://unpkg.com/three@0.97.0/build/three.min.js) | 555,650 | 99.97% |
| [Underscore 1.13.8](https://unpkg.com/underscore@1.13.8/underscore.js) | 68,916 | 99.95% |
| [Lodash 4.18.1](https://unpkg.com/lodash@4.18.1/lodash.js) | 545,945 | 99.99% |

The score compares the class of each non-whitespace source character. The
runner also decodes the component's HTML and requires it to reproduce the
complete input. The component cannot gain points by dropping text.

These are focused JavaScript regression measurements. They are not comparable
to gpu-lexer's Top-25 score. That score covers many languages and gives an
unsupported language a score of zero.

The four files exercise different JavaScript patterns. React covers anonymous
functions, function-valued properties, CommonJS names, uppercase parameters,
and reserved words used as property names. Three.js covers constructors without
parentheses and nested conditional expressions.

## How the executable oracle works

The project uses two oracle layers:

1. `compare-shiki.mjs` downloads four pinned JavaScript files, verifies their byte lengths and SHA-256 digests, runs Shiki and the Wasm component, and reports each disagreement.
2. A developer reduces a useful disagreement to a short input and exact HTML output in `syntax-highlight-javascript-semantic.fixtures.txt`.
3. `syntax-highlight-javascript-semantic.comply.zig` embeds that fixture file and compiles it into a 5.7 kB Compliance module.
4. `qip comply` runs those exact cases against the highlighter. A changed byte, missing span, extra span, or escaping error fails the check.

The large files find repeated errors. The small Compliance cases define the
stable contract without storing React, Three.js, Underscore, Lodash, or Shiki
inside the oracle.

Each fixture has three markers:

```text
=== INPUT ===
const message = '<QIP & JavaScript>';
=== OUTPUT ===
<span class="syntax-keyword">const</span> message ...
=== END ===
```

The fixture parser runs at Zig compile time. It splits the checked-in text into
five input/output pairs. An `inline for` then emits five unconditional calls to
the imported `qip.must_render_exactly` function. The parser is not present in
the compiled oracle.

For each call, the QIP host:

1. reads the input and expected-output slices from the oracle's memory;
2. copies the input into the highlighter's memory;
3. calls the highlighter's `render(i32) -> i64` export;
4. reads the returned pointer and byte length; and
5. compares the returned bytes with the expected HTML.

The ordinal identifies a failed case. The host reports its input, expected
output, and actual output. The oracle returns `5`, and the host checks that it
observed exactly five calls.

Run the contract with:

```sh
qip comply \
  text/javascript/js-syntax-highlight-html.wasm \
  --with compliance/syntax-highlight-javascript-semantic.comply.wasm \
  --straight-line-oracles
```

`--straight-line-oracles` inspects the compiled oracle. It permits constants,
direct oracle calls, dropped return values, and the final return. It rejects
branches, loops, helper calls, indirect calls, and memory instructions. This
check prevents a fixture oracle from conditionally skipping a case. It does
not restrict the highlighter implementation.

Run the larger Shiki comparison and benchmark with:

```sh
make -C benchmarks/syntax-highlight-comparison install
make -C benchmarks/syntax-highlight-comparison compare
make -C benchmarks/syntax-highlight-comparison benchmark
```

Use JSON output to inspect confusion matrices and per-class precision and
recall:

```sh
cd benchmarks/syntax-highlight-comparison
npm run compare -- --json react-development
```

## Output classes

The component uses the same nine-class vocabulary as gpu-lexer's comparison,
but not its token decisions. Plain text has no element. The eight highlighted
types use a `syntax-` prefix to avoid generic application class names.

| Token | HTML class |
| --- | --- |
| Comment | `syntax-comment` |
| String or regular expression | `syntax-string` |
| Number | `syntax-number` |
| Keyword | `syntax-keyword` |
| Type | `syntax-type` |
| Function | `syntax-function` |
| Constant | `syntax-constant` |
| Operator | `syntax-operator` |
| Plain text | No element |

These are not Shiki CSS classes. Shiki normally returns TextMate scopes,
tokens, and theme colors. The component's smaller vocabulary keeps presentation
separate from token meaning.

The comparison normalizes Shiki scopes in this order:

| Shiki TextMate scope | Common token |
| --- | --- |
| `comment*` | Comment |
| `string*` or a scope that contains `regexp` | String |
| `constant.numeric*` | Number |
| `keyword.operator*` | Operator |
| `entity.name.function*` or `support.function*` | Function |
| Type, class, interface, enum, or supported class scopes | Type |
| Language constants and language variables | Constant |
| Other `keyword*` or `storage*` scopes | Keyword |
| All other scopes | Plain text |

The remaining differences come from context that a small lexer does not fully
parse and from formatting-sensitive TextMate scopes. The component does not add
a special case only to imitate an unusual scope decision. A new rule must
describe useful JavaScript behavior and have a reduced Compliance case.

## When to use another highlighter

Use this QIP component for fast JavaScript highlighting, compact WebAssembly,
and stable semantic classes. Use Shiki when exact TextMate scope coverage and
theme compatibility justify its cost. Use Starry Night when you need
GitHub-compatible `pl-*` classes or a HAST tree. Use Prism or Sugar High when
their CSS and browser integration fit your application.

The lexer uses deliberate heuristics. It is not a complete JavaScript parser,
and it does not support the language range of Shiki, Starry Night, or gpu-lexer.

## Did the Compliance oracle help?

Yes. Shiki found the disagreements, but the Compliance oracle made each fix
quick to verify. Once a disagreement became a small fixture, we could run its
exact input and output check after every lexer change. This caught regressions
without running Shiki or processing the four large library files again.

The five-case Compliance command took a mean of 15.82 ms across 20 local runs.
The median was 15.51 ms. This time includes CLI startup, Wasm validation,
`--straight-line-oracles` validation, both module instances, and all five exact
output comparisons. It does not include rebuilding the Wasm files.

The two layers have different jobs. Use the slower Shiki comparison to discover
new classes of disagreement. Reduce each useful example and add it to the
Compliance fixture. The 16 ms Compliance check then becomes the normal inner
loop.
