<title>Unicode transforms</title>

# Unicode transforms

Type or paste text below. Conversion runs locally in your browser.

<style>
.tool-grid {
  display: grid;
  gap: 1rem;
}
@media (min-width: 860px) {
  .tool-grid { grid-template-columns: 1fr 1fr 1fr; }
}
.tool-panel {
  display: grid;
  gap: 0.5rem;
  align-content: start;
}
.tool-panel textarea {
  box-sizing: border-box;
  min-height: 10rem;
  width: 100%;
  resize: vertical;
  font: inherit;
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
    <strong>Text</strong>
    <textarea id="case-input" spellcheck="false">Straße İstanbul ΘΕΣΣΑΛΟΝΊΚΗ — ΣΟΦΟΣ ΟΔΥΣΣΕΥΣ! ﬁne ǅungla</textarea>
  </label>
  <label class="tool-panel">
    <strong>Lowercase</strong>
    <textarea id="case-lower" spellcheck="false" readonly></textarea>
  </label>
  <label class="tool-panel">
    <strong>Uppercase</strong>
    <textarea id="case-upper" spellcheck="false" readonly></textarea>
  </label>
</div>

<p class="tool-actions">
  <button type="button" data-sample="ΘΕΣΣΑΛΟΝΊΚΗ ΣΟΦΟΣ σοφός">Greek final sigma</button>
  <button type="button" data-sample="straße GROẞ ﬁ ﬂ ﬃ ŉ">German &amp; ligatures</button>
  <button type="button" data-sample="İstanbul ı I i̇">Dotted &amp; dotless i</button>
  <button type="button" data-sample="𐐐𐐨 𐵰𐵐 ꭰꮣ ᏣᎳᎩ">Deseret, Garay, Cherokee</button>
  <span id="case-status" class="tool-status" role="status"></span>
</p>

<script type="module">
import { contentComponent, contentTypeUTF8 } from "/qip-runner.js";

const input = document.getElementById("case-input");
const lowerOutput = document.getElementById("case-lower");
const upperOutput = document.getElementById("case-upper");
const status = document.getElementById("case-status");
const text = contentTypeUTF8();
const [lowerModule, upperModule] = await Promise.all([
  WebAssembly.compileStreaming(fetch("/text/unicode-17-lowercase.wasm")),
  WebAssembly.compileStreaming(fetch("/text/unicode-17-uppercase.wasm")),
]);
const toLower = contentComponent(text, lowerModule, text);
const toUpper = contentComponent(text, upperModule, text);

function transform() {
  try {
    lowerOutput.value = toLower(input.value);
    upperOutput.value = toUpper(input.value);
    status.textContent = "";
  } catch (error) {
    status.textContent = error instanceof Error ? error.message : String(error);
  }
}

for (const button of document.querySelectorAll("[data-sample]")) {
  button.addEventListener("click", () => {
    input.value = button.dataset.sample;
    transform();
  });
}
input.addEventListener("input", transform);
transform();
</script>

The samples exercise rules that ASCII-only conversion misses. `ΣΟΦΟΣ` ends with the final sigma `ς`; `straße` becomes `STRASSE`; and `İ` becomes `i̇` (an `i` followed by a combining dot). Garay casing requires Unicode 16 or newer.

## Why the Unicode version is explicit

Browsers, operating systems, programming languages, databases, and server distributions ship different revisions of Unicode data. Many use ICU and CLDR, but they do not all update together. The same application can therefore see different case mappings, normalization, collation, or locale formatting depending on where it runs. Newer scripts are a visible example: an older runtime may leave their letters unchanged because it does not yet know they have case.

These components carry their own Unicode 17 data. The revision is part of each filename—`unicode-17-lowercase.wasm` and `unicode-17-uppercase.wasm`—so upgrading to Unicode 18 will be an explicit component change rather than an incidental platform update.

Both implement Unicode Default Case Conversion for the root locale. Locale-specific casing for Turkish, Azerbaijani, and Lithuanian belongs in separate, explicitly named components.

## Use the components

```bash
echo "ΘΕΣΣΑΛΟΝΊΚΗ ΣΟΦΟΣ" | qip run text/unicode-17-lowercase.wasm
# θεσσαλονίκη σοφος

echo "straße" | qip run text/unicode-17-uppercase.wasm
# STRASSE
```

In a browser, the helper used by this page wraps the component's small memory-and-render contract:

```js
import { contentComponent, contentTypeUTF8 } from "/qip-runner.js";

const text = contentTypeUTF8();
const module = await WebAssembly.compileStreaming(
  fetch("/text/unicode-17-lowercase.wasm"),
);
const lowercase = contentComponent(text, module, text);

lowercase("ΘΕΣΣΑΛΟΝΊΚΗ ΣΟΦΟΣ"); // "θεσσαλονίκη σοφος"
```

The same component runs in Node or any other WebAssembly host. You can also [import it directly as a WebAssembly ES module](/docs/running-in-javascript).

## Check another implementation

The uppercase component has an executable compliance component at `compliance/unicode-17-uppercase.comply.wasm`. Its 100 deterministic cases combine examples, seeded fuzzing, and properties such as idempotence. A failure can be reproduced from the component hash, seed, and case ordinal.

The repository includes Node and Go examples. Node's `toUpperCase`, backed here by ICU 78 and Unicode 17, passes all 100 cases. Go's standard library fails 38 because it uses Unicode 15 tables and simple per-rune mappings rather than full mappings. See `compliance/hosts/uppercase-node/` and `compliance/hosts/uppercase-go/`.

Normalization and locale-aware date, number, and currency components can follow the same model: the Unicode or CLDR revision belongs in the artifact rather than being inherited silently from the environment.
