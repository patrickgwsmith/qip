import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { decodeRenderResult } from "./lib/content-component-host.mjs";

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

function readI32Export(exports, name) {
  const value = exports[name];
  return typeof value === "function" ? value() : value.value;
}

function writeInput(exports, text) {
  const bytes = encoder.encode(text);
  const inputPtr = readI32Export(exports, "input_ptr");
  const inputCap = readI32Export(exports, "input_utf8_cap");
  assert.ok(bytes.length <= inputCap);
  new Uint8Array(exports.memory.buffer, inputPtr, bytes.length).set(bytes);
  return bytes.length;
}

function renderText(exports, text) {
  const inputLen = writeInput(exports, text);
  const result = decodeRenderResult(exports.render(inputLen));
  assert.equal(result.failed, false);
  return decoder.decode(new Uint8Array(exports.memory.buffer, result.outputPointer, result.value));
}

test("luhn rejects invalid input and recovers on the same instance", async () => {
  const { instance } = await WebAssembly.instantiate(
    await readFile("text/luhn.wasm"),
    {},
  );
  const exports = instance.exports;

  for (const invalid of ["", "   ", "4", "49927398717", "49927398x16", "4992\t7398716"]) {
    const inputLen = writeInput(exports, invalid);
    assert.equal(decodeRenderResult(exports.render(inputLen)).failed, true);
  }

  assert.equal(renderText(exports, " 4992-7398 716 "), "49927398716");
});
