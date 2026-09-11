import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";

const componentPath = join(
  process.cwd(),
  "image/jp2/jp2-to-bmp-b8g8r8a8-srgb.wasm",
);
const fixturePath = join(process.cwd(), "fixtures/25mp-lossless.jp2");

function exportedString(exports, pointerName, sizeName) {
  const bytes = new Uint8Array(
    exports.memory.buffer,
    exports[pointerName](),
    exports[sizeName](),
  );
  return new TextDecoder().decode(bytes);
}

test("JP2 decodes losslessly to the expected 25 MP BGRA BMP", async () => {
  const [wasm, fixture] = await Promise.all([
    readFile(componentPath),
    readFile(fixturePath),
  ]);
  const instance = await WebAssembly.instantiate(wasm);
  const exports = instance.instance.exports;

  assert.equal(
    exportedString(
      exports,
      "input_content_type_ptr",
      "input_content_type_size",
    ),
    "image/jp2",
  );
  assert.equal(
    exportedString(
      exports,
      "output_content_type_ptr",
      "output_content_type_size",
    ),
    "image/bmp",
  );

  const input = new Uint8Array(
    exports.memory.buffer,
    exports.input_ptr(),
    exports.input_bytes_cap(),
  );
  input.set(fixture);
  input[0] ^= 1;
  assert.equal(qipRenderSize(exports, fixture.length), 0);
  input.set(fixture);

  const outputSize = qipRenderSize(exports, fixture.length);
  assert.equal(outputSize, 100_000_054);
  const output = new Uint8Array(
    exports.memory.buffer,
    qipRenderedOutputPointer(exports),
    outputSize,
  );
  const view = new DataView(
    exports.memory.buffer,
    qipRenderedOutputPointer(exports),
    outputSize,
  );
  assert.equal(String.fromCharCode(output[0], output[1]), "BM");
  assert.equal(view.getUint32(18, true), 5000);
  assert.equal(view.getInt32(22, true), -5000);
  assert.equal(view.getUint16(28, true), 32);
  assert.equal(
    createHash("sha256").update(output).digest("hex"),
    "59ab817d4a7186a514235cf7c1031edff9583d44504ce56a30e6050e6910fa9a",
  );

  assert.equal(exports.arena_failed_allocation(), 0);
  assert.equal(exports.arena_live_bytes(), 0);
  assert.equal(exports.arena_free_unmatched_count(), 0);
  assert.ok(exports.arena_peak_bytes() <= 384 * 1024 * 1024);
});
