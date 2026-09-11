import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const moduleUrl = new URL("../image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossless.wasm", import.meta.url);

function makeBmp(pixels) {
  const width = pixels.length;
  const bmp = Buffer.alloc(54 + width * 4);
  bmp.write("BM", 0, "ascii");
  bmp.writeUInt32LE(bmp.length, 2);
  bmp.writeUInt32LE(54, 10);
  bmp.writeUInt32LE(40, 14);
  bmp.writeInt32LE(width, 18);
  bmp.writeInt32LE(-1, 22);
  bmp.writeUInt16LE(1, 26);
  bmp.writeUInt16LE(32, 28);
  bmp.writeUInt32LE(width * 4, 34);
  pixels.forEach((pixel, index) => {
    Buffer.from(pixel).copy(bmp, 54 + index * 4);
  });
  return bmp;
}

function withV5AlphaHeader(bmp) {
  const v5 = Buffer.alloc(bmp.length + 84);
  bmp.copy(v5, 0, 0, 54);
  bmp.copy(v5, 138, 54);
  v5.writeUInt32LE(v5.length, 2);
  v5.writeUInt32LE(138, 10);
  v5.writeUInt32LE(124, 14);
  v5.writeUInt32LE(3, 30);
  v5.writeUInt32LE(0x00ff0000, 54);
  v5.writeUInt32LE(0x0000ff00, 58);
  v5.writeUInt32LE(0x000000ff, 62);
  v5.writeUInt32LE(0xff000000, 66);
  v5.writeUInt32LE(0x73524742, 70);
  return v5;
}

function encode(exports, bmp) {
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), bmp.length).set(bmp);
  const size = qipRenderSize(exports, bmp.length);
  assert.ok(size > 0);
  return Buffer.from(new Uint8Array(
    exports.memory.buffer, qipRenderedOutputPointer(exports), size,
  ));
}

test("bmp-b8g8r8a8-srgb-to-webp-lossless emits VP8L and preserves transparent RGB exactly", async () => {
  const wasm = await readFile(moduleUrl);
  const { instance: { exports } } = await WebAssembly.instantiate(wasm, {});

  assert.equal(exports.memory.buffer.byteLength, 1536 * 1024 * 1024);
  assert.equal(exports.output_bytes_cap(), 128 * 1024 * 1024);
  assert.equal(exports.uniform_set_level(6), 6);
  assert.equal(exports.uniform_set_level(99), 9);
  assert.equal(exports.uniform_set_level(6), 6);

  const first = encode(exports, makeBmp([
    [10, 20, 30, 0],
    [40, 50, 60, 128],
  ]));
  assert.equal(first.subarray(0, 4).toString("ascii"), "RIFF");
  assert.equal(first.subarray(8, 12).toString("ascii"), "WEBP");
  assert.equal(first.subarray(12, 16).toString("ascii"), "VP8L");

  const changedTransparentRgb = encode(exports, makeBmp([
    [11, 22, 33, 0],
    [40, 50, 60, 128],
  ]));
  assert.notDeepEqual(first, changedTransparentRgb);

  const v5 = encode(exports, withV5AlphaHeader(makeBmp([
    [10, 20, 30, 0],
    [40, 50, 60, 128],
  ])));
  assert.deepEqual(v5, first, "V5 masks must not change lossless pixels");

  assert.ok(exports.arena_allocation_count() > 0);
  assert.equal(exports.arena_failed_allocation(), 0);
  assert.equal(exports.arena_free_unmatched_count(), 0);
  assert.equal(exports.arena_free_count(), exports.arena_free_matched_count());
  assert.ok(exports.arena_search_steps() >= exports.arena_allocation_count());
  assert.ok(exports.arena_max_search_steps() > 0);
  assert.ok(exports.arena_allocation_offset(0) > 0);
});
