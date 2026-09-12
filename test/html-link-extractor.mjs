import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { decodeRenderResult } from "./lib/content-component-host.mjs";
import { generateHTMLLinkExtractorBenchmark } from "../tools/generate-html-link-extractor-benchmark.mjs";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const wasm = await readFile("text/html/html-link-extractor.wasm");

async function load() {
  return (await WebAssembly.instantiate(wasm, {})).instance.exports;
}

function readI32Export(exports, name) {
  const value = exports[name];
  return typeof value === "function" ? value() : value.value;
}

function render(exports, text) {
  const input = encoder.encode(text);
  assert.ok(input.byteLength <= readI32Export(exports, "input_utf8_cap"));
  const inputPointer = readI32Export(exports, "input_ptr");
  new Uint8Array(exports.memory.buffer, inputPointer, input.byteLength).set(input);

  const result = decodeRenderResult(exports.render(input.byteLength));
  assert.equal(result.failed, false);
  return decoder.decode(
    new Uint8Array(exports.memory.buffer, result.outputPointer, result.value),
  );
}

test("html-link-extractor resolves aria-labelledby in reference order", async () => {
  const exports = await load();
  const html = [
    "<span id=first>First <b>label</b></span>",
    "<img id=logo alt='QIP logo'>",
    "<a href=/x aria-label=Fallback aria-labelledby='logo first'>Ignored</a>",
  ].join("");
  assert.equal(render(exports, html), "/x QIP logo First label\n");
});

test("html-link-extractor omits non-rendered anchor content", async () => {
  const exports = await load();
  assert.equal(
    render(
      exports,
      "<a href=/x>Before<!-- hidden > text --><script>hidden < tag</script><style>hidden</style>after</a>",
    ),
    "/x Beforeafter\n",
  );
});

test("html-link-extractor keeps output within its advertised capacity", async () => {
  const exports = await load();
  const inputCapacity = readI32Export(exports, "input_utf8_cap");
  const html = `<a href=/x>${"a".repeat(inputCapacity - 15)}</a>`;
  assert.equal(encoder.encode(html).byteLength, inputCapacity);
  const output = render(exports, html);
  assert.ok(encoder.encode(output).byteLength <= readI32Export(exports, "output_utf8_cap"));
  assert.equal(output, `/x ${"a".repeat(inputCapacity - 15)}\n`);
});

test("html-link-extractor preserves labels after its ID index fills", async () => {
  const exports = await load();
  let html = "";
  for (let i = 0; i < 1100; i++) {
    html += `<i id=i${i}>Label ${i}</i>`;
  }
  html += "<a href=/last aria-labelledby=i1099>Ignored</a>";
  assert.ok(encoder.encode(html).byteLength <= readI32Export(exports, "input_utf8_cap"));
  assert.equal(render(exports, html), "/last Label 1099\n");
});

test("html-link-extractor produces exact output for the label-heavy benchmark", async () => {
  const exports = await load();
  let expected = "";
  for (let i = 0; i < 128; i++) {
    expected += `/p${i} Label ${i} Label ${(i + 17) % 128} Label ${(i + 53) % 128} Label ${(i + 91) % 128}\n`;
  }
  assert.equal(render(exports, generateHTMLLinkExtractorBenchmark()), expected);
});
