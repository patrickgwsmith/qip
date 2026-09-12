import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  registerGenericComplianceTests,
  runComplianceComponent,
} from "./lib/compliance-harness.mjs";
import {
  renderSize,
  renderedOutputPointer,
} from "./lib/content-component-host.mjs";

const complianceBytes = await readFile(
  new URL("../compliance/unicode-17-normalize-nfc.comply.wasm", import.meta.url),
);
const implementationBytes = await readFile(
  new URL("../text/unicode-17-normalize-nfc.wasm", import.meta.url),
);
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

registerGenericComplianceTests(test, complianceBytes, {
  curatedCount: 24,
  expectSeedVariation: false,
});

async function load() {
  const { instance } = await WebAssembly.instantiate(implementationBytes);
  const exports = instance.exports;
  const readI32 = (name) => typeof exports[name] === "function"
    ? exports[name]()
    : exports[name].value;
  return { exports, readI32 };
}

function renderBytes(module, input) {
  new Uint8Array(
    module.exports.memory.buffer,
    module.readI32("input_ptr"),
    input.byteLength,
  ).set(input);
  const outputLength = renderSize(module.exports, input.byteLength);
  return Buffer.from(new Uint8Array(
    module.exports.memory.buffer,
    renderedOutputPointer(module.exports),
    outputLength,
  ));
}

test("duel: unicode-17-normalize-nfc.wasm satisfies the Compliance oracle", async () => {
  const module = await load();
  const { cases } = await runComplianceComponent(complianceBytes);
  const failures = cases
    .filter((entry) => !renderBytes(module, entry.input).equals(entry.expected))
    .map((entry) => entry.ordinal);
  assert.deepEqual(failures, []);
});

test("deterministic sequences agree with an independent JavaScript NFC implementation", async () => {
  const module = await load();
  const starters = ["A", "D", "E", "a", "e", "o", "\u03A9", "\u03B1", "\u1100", "\u1161"];
  const marks = ["", "\u0300", "\u0301", "\u0304", "\u0307", "\u0308", "\u031B", "\u0323", "\u0327"];

  for (const starter of starters) {
    for (const first of marks) {
      for (const second of marks) {
        const input = starter + first + second;
        const actual = decoder.decode(renderBytes(module, encoder.encode(input)));
        assert.equal(actual, input.normalize("NFC"), JSON.stringify(input));
      }
    }
  }
});

test("the maximum ASCII input is preserved", async () => {
  const module = await load();
  const input = Buffer.alloc(module.readI32("input_utf8_cap"), 0x61);
  assert.deepEqual(renderBytes(module, input), input);
});

test("malformed UTF-8 traps", async () => {
  for (const input of [
    Buffer.from([0xff]),
    Buffer.from([0xc3]),
    Buffer.from([0x80]),
    Buffer.from([0xed, 0xa0, 0x80]),
    Buffer.from([0xf4, 0x90, 0x80, 0x80]),
  ]) {
    const module = await load();
    new Uint8Array(
      module.exports.memory.buffer,
      module.readI32("input_ptr"),
      input.byteLength,
    ).set(input);
    assert.throws(() => module.exports.render(input.byteLength), WebAssembly.RuntimeError);
  }
});
