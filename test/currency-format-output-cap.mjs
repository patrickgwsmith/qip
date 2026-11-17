import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const locales = ["en-us", "en-in", "de-de", "fr-fr", "es-es", "pt-br", "ar-eg", "ja-jp", "zh-cn", "usd-en-us"];
// 96 integer nines that round up to 97 digits: the longest possible output.
const longest = `-${"9".repeat(96)}.9999`;

for (const locale of locales) {
  test(`currency-format-${locale}.wasm keeps its longest output within output_utf8_cap`, async () => {
    const bytes = await readFile(new URL(`../text/currency-format-${locale}.wasm`, import.meta.url));
    const { instance } = await WebAssembly.instantiate(bytes);
    const exports = instance.exports;
    const input = Buffer.from(longest);
    new Uint8Array(exports.memory.buffer).set(input, exports.input_ptr());
    const result = exports.render(input.length);
    const size = Number(result & 0xffffffffn);
    const cap = exports.output_utf8_cap();
    assert.ok(size <= cap, `output of ${size} bytes exceeds output_utf8_cap ${cap}`);
  });
}
