<title>JSON Schema validator (draft 2020-12)</title>

# JSON Schema validator

Check a JSON document against a [JSON Schema](https://json-schema.org/)
draft 2020-12 schema, or compile the schema into its own WebAssembly
validator. Everything runs in this page and nothing is uploaded. Both are QIP
components written in Zig:

- <a href="/application/json/json-schema-2020-12-must-be-valid.wasm" download>`json-schema-2020-12-must-be-valid.wasm`</a>
  (<qip-content-size src="/application/json/json-schema-2020-12-must-be-valid.wasm"></qip-content-size>)
  takes a schema and a document together and validates them in one call.
- <a href="/application/json/json-schema-to-wasm.wasm" download>`json-schema-to-wasm.wasm`</a>
  (<qip-content-size src="/application/json/json-schema-to-wasm.wasm"></qip-content-size>)
  compiles a schema once into a validator component that takes bare documents.

Both pass all 1,298 cases of the official
[JSON-Schema-Test-Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite)
for draft 2020-12.

<style>
.schema-grid { display: grid; gap: 1rem; margin: 1rem 0; }
@media (min-width: 860px) { .schema-grid { grid-template-columns: 1fr 1fr; } }
.schema-panel { display: grid; gap: 0.5rem; align-content: start; }
.schema-panel label { display: grid; gap: 0.25rem; font-weight: 600; }
.schema-panel textarea, .schema-panel select {
  box-sizing: border-box;
  width: 100%;
  font: inherit;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-weight: 400;
}
.schema-panel textarea { min-height: 18rem; resize: vertical; tab-size: 2; }
#schema-remotes { min-height: 6rem; }
.schema-actions { display: flex; flex-wrap: wrap; gap: 0.5rem 1rem; align-items: center; margin: 0.5rem 0 1.5rem; }
.schema-verdict { display: block; min-height: 1.5rem; }
/* The site draws <output> light, so these colors are for a light box. */
.schema-verdict .schema-ok { color: #11632b; font-weight: 600; }
.schema-verdict .schema-bad { color: #a40000; font-weight: 600; }
#schema-compile-status .schema-bad { color: #ff7a6e; font-weight: 600; }
.schema-table { width: 100%; margin: 1rem 0; font-variant-numeric: tabular-nums; }
.schema-table td:not(:first-child), .schema-table th:not(:first-child) { text-align: right; }
</style>

<p class="schema-panel"><label>Start from an example
  <select id="schema-preset"></select>
</label></p>

<div class="schema-grid">
  <div class="schema-panel">
    <label>Schema
      <textarea id="schema-schema" spellcheck="false"></textarea>
    </label>
  </div>
  <div class="schema-panel">
    <label>Document (instance)
      <textarea id="schema-instance" spellcheck="false"></textarea>
    </label>
  </div>
</div>

<details>
<summary>Remote schemas for <code>$ref</code> (optional)</summary>
<div class="schema-panel">
  <label>A JSON object from absolute URI to schema
    <textarea id="schema-remotes" spellcheck="false" placeholder='{"https://example.com/address.json": {"type": "object"}}'></textarea>
  </label>
</div>
</details>

<output id="schema-verdict" class="schema-verdict" aria-live="polite">Loading the validator…</output>

<div class="schema-actions">
  <button id="schema-compile" type="button" disabled>Compile schema to Wasm</button>
  <span id="schema-compile-status" role="status"></span>
</div>

The page validates as you type. **Valid** and **Invalid** say whether the
document conforms. If the schema itself can't be used, the validator stops
with an error instead of calling the document invalid. That happens with
invalid JSON, a `$ref` that doesn't resolve, an unsupported regular
expression or an unknown required vocabulary. So a broken schema never looks
like a bad document.

**Compile schema to Wasm** turns the schema into a standalone validator and
offers it as a download. The page then checks the document with the compiled
module too and says whether it agrees.

## What it supports

- **All of draft 2020-12's core, applicator, unevaluated and validation
  vocabularies,** including `$dynamicRef`, `unevaluatedProperties` and
  `unevaluatedItems`. The 2020-12 meta-schemas are built in.
- **`format` and `content*` are annotations,** as the default 2020-12 dialect
  says, so they never make a document invalid.
- **Remote `$ref`s are preloaded, never fetched.** Pass them as `"schemas"`,
  keyed by absolute URI, the same way ata-validator's `schemas` option and
  @cfworker/json-schema's `addSchema` work. Documents that declare `$id` are
  also found by that `$id`.
- **Numbers are compared exactly by their decimal text,** never as
  floating-point. `1.0` equals `1`, `0.0075` is a multiple of `0.0001`, and
  `1e400` is greater than `1e308`. JavaScript validators can disagree on
  numbers that doubles can't tell apart.
- **`pattern` uses ECMA-262 syntax with the `u` flag:** literals, `.`, `^`,
  `$`, classes, `\d \w \s \b` and their negations, `\p{Letter}`, groups,
  alternation and greedy or lazy quantifiers. Matching takes linear time, so
  a pattern can't cause catastrophic backtracking. Lookaround and
  backreferences are rejected as unsupported.

Patterns match anywhere in the string, as the specification says, so
`[a-z]+` also accepts `abc<script>`. Write `^[a-z]+$` to match the whole
string.

## Correctness

The [Compliance oracle](/oracles) `json-schema-2020-12.comply.wasm` packages
the JSON-Schema-Test-Suite's 1,298 draft 2020-12 core cases, without the
`optional/` tests. The same oracle drives the QIP components and, through a
small adapter, two JavaScript libraries.

<table class="schema-table">
<thead><tr><th scope="col">Validator</th><th scope="col">Passed</th><th scope="col"></th></tr></thead>
<tbody>
<tr><td>QIP <code>json-schema-2020-12-must-be-valid</code></td><td>1,298 / 1,298</td><td>100.00%</td></tr>
<tr><td>QIP compiled with <code>json-schema-to-wasm</code></td><td>1,298 / 1,298</td><td>100.00%</td></tr>
<tr><td><a href="https://www.npmjs.com/package/ata-validator">ata-validator</a> 1.62.1</td><td>1,298 / 1,298</td><td>100.00%</td></tr>
<tr><td><a href="https://www.npmjs.com/package/@cfworker/json-schema">@cfworker/json-schema</a> 4.1.4</td><td>1,257 / 1,298</td><td>96.84%</td></tr>
</tbody>
</table>

cfworker always asserts `format` (15 cases), resolves `$dynamicRef` like
`$ref` in most cases (22), and misses 4 other edge cases.

The oracle passes only when an invalid case is cleanly rejected. A validator
that fails by crashing on a schema doesn't count as rejecting the document.

A second oracle, `json-schema-2020-12-interoperable-regex.comply.wasm`, holds
the 1,292 cases whose patterns stay inside the spec's
[interoperable regular expression subset](https://json-schema.org/draft/2020-12/json-schema-core#section-6.4),
plus `.` and escaped syntax characters such as `\.`. It's for validators that
accept only that subset.

## Speed

Node v26.3.0 on Apple Silicon, fastest of 31 runs, each workload in a fresh
process. Read the ratios rather than the exact times.

<table class="schema-table">
<thead><tr><th scope="col">Workload</th><th scope="col">QIP</th><th scope="col">ata-validator</th><th scope="col">@cfworker/json-schema</th></tr></thead>
<tbody>
<tr><td>Whole suite, each schema compiled and used once</td><td><strong>1.77 ms</strong></td><td>19.8 ms</td><td>39.2 ms</td></tr>
<tr><td>0.75 MB document, schema compiled each time</td><td>6.18 ms</td><td><strong>2.03 ms</strong></td><td>24.5 ms</td></tr>
<tr><td>0.75 MB document, schema already compiled, from bytes</td><td><strong>1.96 ms</strong></td><td>2.03 ms</td><td>—</td></tr>
<tr><td>0.75 MB document, schema already compiled, from a parsed object</td><td>—</td><td><strong>0.52 ms</strong></td><td>22.6 ms</td></tr>
</tbody>
</table>

- **Many small schemas, each used once:** the one-call validator is about 11
  times faster than ata and 22 times faster than cfworker. ata generates and
  compiles JavaScript for every schema, and that is most of its cost here.
- **One schema used many times:** compile it with `json-schema-to-wasm`.
  Compiling the order schema takes about 0.1 ms. The compiled module then
  validates the 0.75 MB document from raw bytes in 1.96 ms, level with ata
  parsing the same bytes. Its own JSON parsing takes about 0.6 ms of that,
  faster than `JSON.parse` on the same bytes (1.5 ms).
- **Already-parsed objects:** ata is faster when the document is already a
  JavaScript object, because it skips parsing. A Wasm validator always reads
  bytes.

The benchmark harness is in `benchmarks/json-schema-2020-12/` in the qip
repository.

## Use it outside the browser

The one-call validator takes a JSON envelope with the schema, the document
and any remote schemas, in any key order. When the document conforms, it
outputs the document's exact bytes, so it can sit in a pipeline:

```sh
printf '{"schema": {"type": "array", "items": {"type": "integer"}}, "instance": [1, 2, 3]}' \
  | npx @qip.dev/qipx qip.dev run application/json/json-schema-2020-12-must-be-valid.wasm
```

To reuse a schema, compile it once. The compiler takes the same envelope
without `"instance"`. The second command prints `[1, 2, 3]`, and the third
fails because `"x"` isn't an integer:

```sh
printf '{"schema": {"type": "array", "items": {"type": "integer"}}}' \
  | npx @qip.dev/qipx qip.dev run -o ints.wasm application/json/json-schema-to-wasm.wasm
printf '[1, 2, 3]' | npx @qip.dev/qipx run ints.wasm
printf '[1, "x"]' | npx @qip.dev/qipx run ints.wasm
```

qipx downloads each component from qip.dev the first time and saves it at
the same path, such as `application/json/json-schema-to-wasm.wasm`. The
compiled `ints.wasm` is a local file, so those two commands need no host.

The compiled module runs in any QIP host: the browser, Node, Go, Rust and
Swift. It keeps the schema it checks in a custom section named
`qip.json-schema`. The compiler checks every keyword and pattern up front, so
a broken schema fails when you compile it, not when the first document
reaches the broken part.

Each component reads up to 4 MiB of input. Rejection carries no detail: it
says the document doesn't conform, not where. To find the failing part,
validate pieces of the document against parts of the schema, or use a
JavaScript library that reports errors.

See [JSON components](/text#json-application-json) for other
`application/json` components.

<script type="module">
const encoder = new TextEncoder();
const decoder = new TextDecoder();

const PRESETS = [
  {
    name: "Order with $ref, pattern and enum",
    schema: {
      $schema: "https://json-schema.org/draft/2020-12/schema",
      type: "object",
      required: ["id", "status", "lines"],
      properties: {
        id: { type: "string", pattern: "^ord_[0-9a-z]{8}$" },
        status: { enum: ["pending", "paid", "shipped"] },
        lines: { type: "array", minItems: 1, items: { $ref: "#/$defs/line" } },
      },
      unevaluatedProperties: false,
      $defs: {
        line: {
          type: "object",
          required: ["sku", "quantity", "price"],
          properties: {
            sku: { type: "string", pattern: "^[A-Z]{3}-[0-9]{4}$" },
            quantity: { type: "integer", minimum: 1 },
            price: { type: "number", minimum: 0, multipleOf: 0.01 },
          },
          additionalProperties: false,
        },
      },
    },
    instance: {
      id: "ord_7f3k9q2m",
      status: "paid",
      lines: [
        { sku: "TEA-0042", quantity: 2, price: 7.5 },
        { sku: "MUG-0007", quantity: 1, price: 12.99 },
      ],
    },
  },
  {
    name: "Conditional fields with if/then/else",
    schema: {
      type: "object",
      required: ["country", "postal_code"],
      properties: { country: { enum: ["US", "AU", "GB"] }, postal_code: { type: "string" } },
      if: { properties: { country: { const: "US" } } },
      then: { properties: { postal_code: { pattern: "^[0-9]{5}(-[0-9]{4})?$" } } },
      else: { properties: { postal_code: { pattern: "^[0-9A-Z ]{3,8}$" } } },
    },
    instance: { country: "US", postal_code: "9021" },
  },
  {
    name: "Exact decimal multipleOf",
    schema: { type: "array", items: { type: "number", multipleOf: 0.0001 } },
    instance: [0.0075, 19.99, 1e-4],
  },
  {
    name: "Remote $ref",
    schema: {
      type: "object",
      properties: { shipping: { $ref: "https://example.com/address.json" } },
    },
    remotes: {
      "https://example.com/address.json": {
        type: "object",
        required: ["street", "city"],
        properties: { street: { type: "string" }, city: { type: "string" } },
      },
    },
    instance: { shipping: { street: "1 Main St", city: "Sydney" } },
  },
  {
    name: "Unsupported pattern (lookahead)",
    schema: { type: "string", pattern: "^(?=.*[0-9]).{8,}$" },
    instance: "hunter22",
  },
];

const schemaArea = document.getElementById("schema-schema");
const instanceArea = document.getElementById("schema-instance");
const remotesArea = document.getElementById("schema-remotes");
const presetSelect = document.getElementById("schema-preset");
const verdict = document.getElementById("schema-verdict");
const compileButton = document.getElementById("schema-compile");
const compileStatus = document.getElementById("schema-compile-status");

const [validatorModule, compilerModule] = await Promise.all([
  WebAssembly.compileStreaming(fetch("/application/json/json-schema-2020-12-must-be-valid.wasm")),
  WebAssembly.compileStreaming(fetch("/application/json/json-schema-to-wasm.wasm")),
]);

// A reusable instance per module. Each render resets the component's own
// memory, so an instance is only replaced after it traps.
function reusable(module) {
  let exports = null;
  return (bytes) => {
    exports ??= new WebAssembly.Instance(module, {}).exports;
    const cap = (exports.input_bytes_cap ?? exports.input_utf8_cap)() >>> 0;
    if (bytes.length > cap) throw new RangeError(`Input is ${bytes.length} bytes; the limit is ${cap}.`);
    new Uint8Array(exports.memory.buffer, exports.input_ptr() >>> 0, bytes.length).set(bytes);
    let result;
    try {
      result = BigInt.asUintN(64, exports.render(bytes.length));
    } catch (error) {
      exports = null;
      throw error;
    }
    if (result >> 63n) return null;
    const ptr = Number((result >> 32n) & 0x7fffffffn);
    const size = Number(result & 0xffffffffn);
    return new Uint8Array(exports.memory.buffer, ptr, size).slice();
  };
}

const validate = reusable(validatorModule);
const compileSchema = reusable(compilerModule);
let compiled = null;
let downloadURL = null;

presetSelect.append(new Option("Custom", ""));
PRESETS.forEach((preset, index) => presetSelect.append(new Option(preset.name, String(index))));

function escapeHTML(text) {
  return text.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
}

// Returns an error message when a box doesn't hold JSON, so the page can say
// which box is wrong; the components themselves only trap.
function jsonProblem(label, text, { optional = false, object = false } = {}) {
  if (optional && !text.trim()) return null;
  try {
    const value = JSON.parse(text);
    if (object && (value === null || typeof value !== "object" || Array.isArray(value))) {
      return `${label} must be a JSON object.`;
    }
    return null;
  } catch (error) {
    return `${label} isn't valid JSON: ${error.message}`;
  }
}

function envelope({ withInstance }) {
  const parts = [];
  if (remotesArea.value.trim()) parts.push(`"schemas":${remotesArea.value}`);
  parts.push(`"schema":${schemaArea.value}`);
  if (withInstance) parts.push(`"instance":${instanceArea.value}`);
  return encoder.encode(`{${parts.join(",")}}`);
}

const SCHEMA_ERROR = "The schema can't be used. Check for a $ref that doesn't resolve, an unsupported pattern (lookaround or backreferences), an invalid keyword value or an unknown required vocabulary.";

function check() {
  const problem =
    jsonProblem("The schema", schemaArea.value) ??
    jsonProblem("The remote schemas", remotesArea.value, { optional: true, object: true }) ??
    jsonProblem("The document", instanceArea.value);
  if (problem) {
    verdict.innerHTML = `<span class="schema-bad">${escapeHTML(problem)}</span>`;
    return;
  }
  const input = envelope({ withInstance: true });
  const started = performance.now();
  let output;
  try {
    output = validate(input);
  } catch (error) {
    verdict.innerHTML = `<span class="schema-bad">Error.</span> ${escapeHTML(error instanceof RangeError ? error.message : SCHEMA_ERROR)}`;
    return;
  }
  const ms = performance.now() - started;
  // Browsers coarsen performance.now(), often to 0.1 ms.
  const timing = ` Checked ${input.length.toLocaleString()} bytes in ${ms < 0.1 ? "under 0.1" : ms.toFixed(1)} ms.`;
  let compiledNote = "";
  if (compiled && compiled.source === schemaArea.value + "\0" + remotesArea.value) {
    try {
      const accepted = compiled.validate(encoder.encode(instanceArea.value)) !== null;
      compiledNote = ` The compiled module ${accepted ? "accepts" : "rejects"} it too.`;
      if (accepted !== (output !== null)) compiledNote = " The compiled module disagrees. Please report this.";
    } catch {
      compiledNote = " The compiled module trapped.";
    }
  }
  verdict.innerHTML = output !== null
    ? `<span class="schema-ok">Valid.</span>${escapeHTML(timing + compiledNote)}`
    : `<span class="schema-bad">Invalid.</span> The document doesn't conform to the schema.${escapeHTML(timing + compiledNote)}`;
}

function clearCompiled() {
  compiled = null;
  if (downloadURL) URL.revokeObjectURL(downloadURL);
  downloadURL = null;
  compileStatus.textContent = "";
}

function compile() {
  clearCompiled();
  const problem =
    jsonProblem("The schema", schemaArea.value) ??
    jsonProblem("The remote schemas", remotesArea.value, { optional: true, object: true });
  if (problem) {
    compileStatus.innerHTML = `<span class="schema-bad">${escapeHTML(problem)}</span>`;
    return;
  }
  let bytes;
  try {
    bytes = compileSchema(envelope({ withInstance: false }));
  } catch (error) {
    compileStatus.innerHTML = `<span class="schema-bad">${escapeHTML(error instanceof RangeError ? error.message : "The compiler ran out of room for this schema.")}</span>`;
    return;
  }
  if (bytes === null) {
    compileStatus.innerHTML = `<span class="schema-bad">Can't compile.</span> ${escapeHTML(SCHEMA_ERROR)}`;
    return;
  }
  compiled = {
    source: schemaArea.value + "\0" + remotesArea.value,
    validate: reusable(new WebAssembly.Module(bytes)),
  };
  downloadURL = URL.createObjectURL(new Blob([bytes], { type: "application/wasm" }));
  const size = bytes.length < 1000 ? `${bytes.length} B` : `${(bytes.length / 1000).toFixed(1)} KB`;
  compileStatus.innerHTML = `Compiled to ${size}. <a href="${downloadURL}" download="json-schema-validator.wasm">Download json-schema-validator.wasm</a>`;
  check();
}

function choosePreset() {
  const preset = PRESETS[Number(presetSelect.value)];
  if (!preset) return;
  schemaArea.value = JSON.stringify(preset.schema, null, 2);
  instanceArea.value = JSON.stringify(preset.instance, null, 2);
  remotesArea.value = preset.remotes ? JSON.stringify(preset.remotes, null, 2) : "";
  remotesArea.closest("details").open = Boolean(preset.remotes);
  clearCompiled();
  check();
}

presetSelect.addEventListener("change", choosePreset);
for (const area of [schemaArea, remotesArea]) {
  area.addEventListener("input", () => {
    presetSelect.value = "";
    clearCompiled();
    check();
  });
}
instanceArea.addEventListener("input", () => {
  presetSelect.value = "";
  check();
});
compileButton.addEventListener("click", compile);

presetSelect.value = "0";
choosePreset();
compileButton.disabled = false;
</script>
