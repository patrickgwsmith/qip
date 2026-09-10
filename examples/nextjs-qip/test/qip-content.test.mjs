import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { createTSXHighlighter } from "../lib/qip-content.js";

const exampleDir = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const component = await readFile(
  path.join(
    exampleDir,
    "..",
    "..",
    "components",
    "text",
    "html",
    "html-code-syntax-highlight-tsx.wasm",
  ),
);

test("the example wraps the TSX syntax-highlighting component", async () => {
  const { instance } = await WebAssembly.instantiate(component, {});
  const highlightTSX = createTSXHighlighter(instance.exports);

  const output = highlightTSX("const view = <Button label={name} />;");
  assert.match(output, /class="language-tsx hljs"/);
  assert.match(output, /hljs-keyword">const<\/span>/);
  assert.match(output, /hljs-name">Button<\/span>/);
});

test("the wrapper escapes source before constructing component input", async () => {
  const { instance } = await WebAssembly.instantiate(component, {});
  const highlightTSX = createTSXHighlighter(instance.exports);

  const output = highlightTSX(`<script>alert("no")<\/script>`);
  assert.doesNotMatch(output, /<script>/);
  assert.match(output, /&lt;/);
});
