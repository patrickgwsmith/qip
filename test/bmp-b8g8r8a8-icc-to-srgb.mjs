import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { constants } from "node:fs";
import { access, readFile } from "node:fs/promises";
import test from "node:test";

const moduleUrl = new URL(
  "../image/bmp/bmp-b8g8r8a8-icc-to-srgb.wasm",
  import.meta.url,
);
const profileUrl = new URL(
  "../third_party/libavif-1.4.1/tests/data/sRGB2014.icc",
  import.meta.url,
);
const conversionProfileUrl = new URL(
  "../third_party/lcms2-2.19.1/testbed/crayons.icc",
  import.meta.url,
);

function buildBmp(width, height, pixels, { topDown = false } = {}) {
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
  bmp.writeUInt32LE(stride * height, 34);
  for (let fileY = 0; fileY < height; fileY += 1) {
    const y = topDown ? fileY : height - 1 - fileY;
    Buffer.from(pixels[y]).copy(bmp, 54 + fileY * stride);
  }
  return bmp;
}

function withEmbeddedProfile(bmp, profile) {
  const pixelOffset = 138;
  const pixelBytes = bmp.length - 54;
  const profileOffset = pixelOffset + pixelBytes;
  const v5 = Buffer.alloc(profileOffset + profile.length);
  bmp.copy(v5, 0, 0, 54);
  bmp.copy(v5, pixelOffset, 54);
  v5.writeUInt32LE(v5.length, 2);
  v5.writeUInt32LE(pixelOffset, 10);
  v5.writeUInt32LE(124, 14);
  v5.writeUInt32LE(3, 30);
  v5.writeUInt32LE(0x00ff0000, 54);
  v5.writeUInt32LE(0x0000ff00, 58);
  v5.writeUInt32LE(0x000000ff, 62);
  v5.writeUInt32LE(0xff000000, 66);
  v5.writeUInt32LE(0x4d424544, 70);
  // bV5ProfileData is relative to the start of the V5 header at file offset 14.
  v5.writeUInt32LE(profileOffset - 14, 126);
  v5.writeUInt32LE(profile.length, 130);
  profile.copy(v5, profileOffset);
  return v5;
}

function withLinkedProfile(bmp) {
  const v5 = Buffer.alloc(138 + (bmp.length - 54) + 8);
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
  v5.writeUInt32LE(0x4c494e4b, 70);
  v5.writeUInt32LE(128, 126);
  v5.writeUInt32LE(8, 130);
  return v5;
}

function encode(exports, input) {
  const memory = new Uint8Array(exports.memory.buffer);
  memory.set(input, exports.input_ptr());
  const size = qipRenderSize(exports, input.length);
  assert.ok(size > 0, "valid BMP must produce output");
  return Buffer.from(memory.subarray(qipRenderedOutputPointer(exports), qipRenderedOutputPointer(exports) + size));
}

async function loadModule(t) {
  try {
    await access(moduleUrl, constants.R_OK);
  } catch {
    t.skip("build components first");
    return null;
  }
  const { instance } = await WebAssembly.instantiate(await readFile(moduleUrl), {});
  return instance.exports;
}

test("normalizes legacy, top-down, and V5 sRGB BMPs to bottom-up B8G8R8A8", async (t) => {
  const exports = await loadModule(t);
  if (!exports) return;

  assert.equal(exports.memory.buffer.byteLength, 512 * 1024 * 1024);
  assert.equal(exports.input_bytes_cap(), 25_000_000 * 4 + 64 * 1024);
  assert.equal(exports.output_bytes_cap(), 25_000_000 * 4 + 54);

  const pixels = [
    Buffer.from([0, 0, 255, 255]),
    Buffer.from([0, 255, 0, 127]),
  ];
  const bottomUp = buildBmp(1, 2, pixels);
  const topDown = buildBmp(1, 2, pixels, { topDown: true });
  const expected = encode(exports, bottomUp);
  assert.deepEqual(encode(exports, topDown), expected);
  assert.equal(expected.readInt32LE(22), 2);
  assert.deepEqual(expected.subarray(54), Buffer.concat([pixels[1], pixels[0]]));

  const profile = await readFile(profileUrl);
  const embedded = encode(exports, withEmbeddedProfile(bottomUp, profile));
  assert.equal(embedded.length, expected.length);
  assert.equal(embedded[57], 127);
  assert.equal(embedded[61], 255);

  const conversionProfile = await readFile(conversionProfileUrl);
  const converted = encode(exports, withEmbeddedProfile(bottomUp, conversionProfile));
  assert.equal(converted.length, expected.length);
  assert.equal(converted[57], 127);
  assert.equal(converted[61], 255);
  assert.equal(exports.arena_failed_allocation(), 0);
  assert.equal(exports.arena_free_unmatched_count(), 0);
  assert.equal(exports.arena_free_count(), exports.arena_free_matched_count());
  assert.ok(exports.arena_peak_bytes() > 0);
});

test("rejects linked profiles and malformed BMPs", async (t) => {
  const exports = await loadModule(t);
  if (!exports) return;

  const pixels = [Buffer.from([1, 2, 3, 255])];
  const bmp = buildBmp(1, 1, pixels);
  const memory = new Uint8Array(exports.memory.buffer);
  memory.set(withLinkedProfile(bmp), exports.input_ptr());
  assert.equal(qipRenderSize(exports, 138 + 4 + 8), 0);
  memory.set(Buffer.from("BM"), exports.input_ptr());
  assert.equal(qipRenderSize(exports, 2), 0);
});
