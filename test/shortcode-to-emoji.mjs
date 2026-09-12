import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { decodeRenderResult } from "./lib/content-component-host.mjs";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const wasm = await readFile("text/shortcode-to-emoji.wasm");

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
  const output = new Uint8Array(
    exports.memory.buffer,
    result.outputPointer,
    result.value,
  );
  return { bytes: output, text: decoder.decode(output) };
}

test("shortcode-to-emoji replaces known names and preserves unknown names", async () => {
  const exports = await load();
  assert.equal(
    render(exports, ":a: :smile: :unknown_shortcode: :rocket:").text,
    "🅰️ 😄 :unknown_shortcode: 🚀",
  );
});

test("shortcode-to-emoji accepts the maximum expanding input", async () => {
  const exports = await load();
  const inputCapacity = readI32Export(exports, "input_utf8_cap");
  const repeats = Math.floor(inputCapacity / 3);
  const remainder = inputCapacity % 3;
  const output = render(exports, ":a:".repeat(repeats) + "x".repeat(remainder));

  assert.equal(output.bytes.byteLength, repeats * 7 + remainder);
  assert.equal(output.text.slice(0, 3), "🅰️");
  assert.equal(output.text.endsWith("x".repeat(remainder)), true);
});
