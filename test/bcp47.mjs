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

async function load(name) {
  return (await WebAssembly.instantiate(await readFile(`text/${name}.wasm`), {})).instance.exports;
}

function run(exports, text) {
  const bytes = encoder.encode(text);
  const inputPtr = readI32Export(exports, "input_ptr");
  assert.ok(bytes.length <= readI32Export(exports, "input_utf8_cap"));
  new Uint8Array(exports.memory.buffer, inputPtr, bytes.length).set(bytes);
  const result = decodeRenderResult(exports.render(bytes.length));
  if (result.failed) {
    const modes = readI32Export(exports, "failure_modes_per_input_offset");
    return { offset: Math.floor(result.value / modes), mode: result.value % modes };
  }
  return decoder.decode(new Uint8Array(exports.memory.buffer, result.outputPointer, result.value));
}

// RFC 5646 appendix A examples, plus grandfathered and private-use forms.
const valid = [
  "de", "fr", "ja", "i-enochian", "zh-Hant", "zh-Hans", "sr-Cyrl", "sr-Latn",
  "zh-cmn-Hans-CN", "cmn-Hans-CN", "zh-yue-HK", "yue-HK", "zh-Hans-CN",
  "sr-Latn-RS", "sl-rozaj", "sl-rozaj-biske", "sl-nedis", "de-CH-1901",
  "sl-IT-nedis", "hy-Latn-IT-arevela", "de-DE", "en-US", "es-419",
  "de-CH-x-phonebk", "az-Arab-x-AZE-derbend", "x-whatever",
  "qaa-Qaaa-QM-x-southern", "de-Qaaa", "sr-Latn-QM", "sr-Qaaa-RS",
  "en-US-u-islamcal", "zh-CN-a-myext-x-private", "en-a-myext-b-another",
  "EN-gb-OED", "zh-min-nan",
];

test("bcp47-must-be-valid accepts valid tags unchanged", async () => {
  const exports = await load("bcp47-must-be-valid");
  for (const tag of valid) assert.equal(run(exports, tag), tag);
});

test("bcp47-must-be-valid reports offset and failure mode, then recovers", async () => {
  const exports = await load("bcp47-must-be-valid");
  const cases = [
    ["", 0, 0],
    ["en_US", 2, 0],
    ["de-419-DE", 7, 0],
    ["a-DE", 0, 0],
    ["en-", 3, 0],
    ["qq-ZZ", 0, 1],
    ["en-Abcd-US", 3, 1],
    ["sl-rozaj-ROZAJ", 9, 2],
    ["ar-a-aaa-b-bbb-a-ccc", 15, 3],
  ];
  for (const [tag, offset, mode] of cases) {
    assert.deepEqual(run(exports, tag), { offset, mode }, tag);
  }
  assert.equal(run(exports, "en-GB"), "en-GB");
});

test("bcp47-must-be-well-formed checks grammar only", async () => {
  const exports = await load("bcp47-must-be-well-formed");
  for (const tag of [...valid, "qq-ZZ", "sl-rozaj-ROZAJ", "ar-a-aaa-b-bbb-a-ccc"]) {
    assert.equal(run(exports, tag), tag);
  }
  assert.deepEqual(run(exports, "de-419-DE"), { offset: 7, mode: 0 });
  assert.deepEqual(run(exports, "en-a"), { offset: 4, mode: 0 });
  assert.deepEqual(run(exports, "en-é"), { offset: 3, mode: 0 });
  assert.equal(run(exports, "x-a"), "x-a");
});
