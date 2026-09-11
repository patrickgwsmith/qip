import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import { constants } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";

const modulePath = fileURLToPath(new URL(
  "../image/bmp/bmp-b8g8r8a8-srgb-to-avif-lossy.wasm",
  import.meta.url,
));

function buildBMP(width, height, { topDown = false, alpha = 255 } = {}) {
  const stride = width * 4;
  const bmp = Buffer.alloc(54 + stride * height);
  bmp.write("BM", 0, "ascii");
  bmp.writeUInt32LE(bmp.length, 2);
  bmp.writeUInt32LE(54, 10);
  bmp.writeUInt32LE(40, 14);
  bmp.writeInt32LE(width, 18);
  bmp.writeInt32LE(topDown ? -height : height, 22);
  bmp.writeUInt16LE(1, 26);
  bmp.writeUInt16LE(32, 28);
  for (let fileY = 0; fileY < height; fileY += 1) {
    const y = topDown ? fileY : height - 1 - fileY;
    for (let x = 0; x < width; x += 1) {
      const offset = 54 + fileY * stride + x * 4;
      bmp[offset] = (x * 13 + y * 3) & 0xff;
      bmp[offset + 1] = (x * 5 + y * 17) & 0xff;
      bmp[offset + 2] = (x * 19 + y * 7) & 0xff;
      bmp[offset + 3] = alpha;
    }
  }
  return bmp;
}

function withV5AlphaHeader(bmp) {
  const pixelOffset = bmp.readUInt32LE(10);
  const v5 = Buffer.alloc(bmp.length + 84);
  bmp.copy(v5, 0, 0, 54);
  bmp.copy(v5, 138, pixelOffset);
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

function exportedString(exports, ptrName, sizeName) {
  return Buffer.from(
    exports.memory.buffer,
    exports[ptrName](),
    exports[sizeName](),
  ).toString("utf8");
}

function encode(exports, bmp) {
  const memory = new Uint8Array(exports.memory.buffer);
  memory.set(bmp, exports.input_ptr());
  const outputSize = qipRenderSize(exports, bmp.length);
  return Buffer.from(exports.memory.buffer, qipRenderedOutputPointer(exports), outputSize);
}

test("bmp-b8g8r8a8-srgb-to-avif-lossy emits deterministic AVIF and preserves the input contract", async (t) => {
  try {
    await access(modulePath, constants.R_OK);
  } catch {
    t.skip("build components first");
    return;
  }

  const wasm = await readFile(modulePath);
  const { instance: { exports } } = await WebAssembly.instantiate(wasm, {});

  assert.equal(exports.input_bytes_cap(), 12_000_000 * 4 + 64 * 1024);
  assert.equal(exports.output_bytes_cap(), 64 * 1024 * 1024);
  assert.equal(exports.memory.buffer.byteLength, 1024 * 1024 * 1024);
  assert.equal(exportedString(exports, "input_content_type_ptr", "input_content_type_size"), "image/bmp");
  assert.equal(exportedString(exports, "output_content_type_ptr", "output_content_type_size"), "image/avif");
  assert.equal(exports.uniform_set_quality(70), 70);
  assert.equal(exports.uniform_set_quality_alpha(100), 100);
  assert.equal(exports.uniform_set_speed(8), 8);
  assert.equal(exports.uniform_set_subsample(0), 0);
  assert.equal(exports.uniform_set_quality(101), 100);
  assert.equal(exports.uniform_set_speed(11), 10);
  exports.uniform_set_quality(70);
  exports.uniform_set_speed(8);

  const invalid = new Uint8Array(exports.memory.buffer);
  invalid.fill(0, exports.input_ptr(), exports.input_ptr() + 54);
  assert.equal(qipRenderSize(exports, 54), 0, "invalid BMP must produce no output");

  const input = buildBMP(64, 48);
  const first = encode(exports, input);
  assert.ok(first.length > 20);
  assert.equal(first.subarray(4, 8).toString("ascii"), "ftyp");
  assert.equal(first.subarray(8, 12).toString("ascii"), "avif");
  assert.ok(exports.arena_peak_bytes() > 0);
  assert.ok(exports.arena_allocation_count() > 0);
  assert.ok(exports.arena_free_count() > 0);
  assert.equal(exports.arena_free_count(), exports.arena_free_matched_count());
  assert.equal(exports.arena_free_unmatched_count(), 0);
  assert.equal(exports.arena_failed_allocation(), 0);

  const second = encode(exports, input);
  assert.deepEqual(second, first, "reused instance must encode deterministically");

  const topDown = buildBMP(64, 48, { topDown: true });
  const topDownOutput = encode(exports, topDown);
  assert.deepEqual(topDownOutput, first, "top-down and bottom-up BMPs must match");

  const transparent = buildBMP(64, 48, { alpha: 0 });
  const transparentOutput = encode(exports, transparent);
  assert.ok(transparentOutput.length > 20);
  assert.notDeepEqual(transparentOutput, first, "alpha must affect the AVIF output");

  const v5 = withV5AlphaHeader(transparent);
  const v5Output = encode(exports, v5);
  assert.ok(v5Output.length > 20);
  assert.notDeepEqual(v5Output, first, "V5 alpha masks must be accepted");
});
