import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import { constants } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";

const decoderPath = fileURLToPath(new URL(
  "../image/webp/webp-to-bmp-b8g8r8a8-srgb.wasm",
  import.meta.url,
));
const lossyEncoderPath = fileURLToPath(new URL(
  "../image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy-opaque.wasm",
  import.meta.url,
));
const losslessEncoderPath = fileURLToPath(new URL(
  "../image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossless.wasm",
  import.meta.url,
));

function buildBMP(width, height, alpha = false) {
  const stride = width * 4;
  const bmp = Buffer.alloc(54 + stride * height);
  bmp.write("BM", 0, "ascii");
  bmp.writeUInt32LE(bmp.length, 2);
  bmp.writeUInt32LE(54, 10);
  bmp.writeUInt32LE(40, 14);
  bmp.writeInt32LE(width, 18);
  bmp.writeInt32LE(height, 22);
  bmp.writeUInt16LE(1, 26);
  bmp.writeUInt16LE(32, 28);
  for (let fileY = 0; fileY < height; fileY += 1) {
    const y = height - 1 - fileY;
    for (let x = 0; x < width; x += 1) {
      const offset = 54 + fileY * stride + x * 4;
      bmp[offset] = (x * 31 + y * 7) & 0xff;
      bmp[offset + 1] = (x * 11 + y * 37) & 0xff;
      bmp[offset + 2] = (x * 43 + y * 13) & 0xff;
      bmp[offset + 3] = alpha ? (x * 53 + y * 29) & 0xff : 255;
    }
  }
  return bmp;
}

async function instantiate(modulePath) {
  const wasm = await readFile(modulePath);
  const { instance: { exports } } = await WebAssembly.instantiate(wasm, {});
  exports._initialize?.();
  return exports;
}

function exportedString(exports, ptrName, sizeName) {
  return Buffer.from(
    exports.memory.buffer,
    exports[ptrName](),
    exports[sizeName](),
  ).toString("utf8");
}

async function encode(modulePath, bmp, configure) {
  const exports = await instantiate(modulePath);
  configure?.(exports);
  new Uint8Array(exports.memory.buffer).set(bmp, exports.input_ptr());
  const size = qipRenderSize(exports, bmp.length);
  assert.ok(size > 0, "fixture encoder must produce WebP");
  return Buffer.from(exports.memory.buffer, qipRenderedOutputPointer(exports), size);
}

function decode(exports, webp) {
  new Uint8Array(exports.memory.buffer).set(webp, exports.input_ptr());
  const size = qipRenderSize(exports, webp.length);
  return Buffer.from(exports.memory.buffer, qipRenderedOutputPointer(exports), size);
}

function assertBMPHeader(bmp, width, height) {
  assert.equal(bmp.subarray(0, 2).toString("ascii"), "BM");
  assert.equal(bmp.readUInt32LE(2), bmp.length);
  assert.equal(bmp.readUInt32LE(10), 54);
  assert.equal(bmp.readUInt32LE(14), 40);
  assert.equal(bmp.readInt32LE(18), width);
  assert.equal(bmp.readInt32LE(22), -height);
  assert.equal(bmp.readUInt16LE(26), 1);
  assert.equal(bmp.readUInt16LE(28), 32);
  assert.equal(bmp.readUInt32LE(30), 0);
  assert.equal(bmp.readUInt32LE(34), width * height * 4);
}

function topDownPixels(bottomUpBMP, width, height) {
  const stride = width * 4;
  const pixels = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y += 1) {
    bottomUpBMP.copy(
      pixels,
      y * stride,
      54 + (height - 1 - y) * stride,
      54 + (height - y) * stride,
    );
  }
  return pixels;
}

function markAnimated(webp, width, height) {
  const extended = Buffer.alloc(webp.length + 18);
  extended.write("RIFF", 0, "ascii");
  extended.writeUInt32LE(extended.length - 8, 4);
  extended.write("WEBP", 8, "ascii");
  extended.write("VP8X", 12, "ascii");
  extended.writeUInt32LE(10, 16);
  extended[20] = 0x02;
  extended.writeUIntLE(width - 1, 24, 3);
  extended.writeUIntLE(height - 1, 27, 3);
  webp.copy(extended, 30, 12);
  return extended;
}

test("webp-to-bmp-b8g8r8a8-srgb decodes lossy and lossless WebP", async (t) => {
  for (const path of [decoderPath, lossyEncoderPath, losslessEncoderPath]) {
    try {
      await access(path, constants.R_OK);
    } catch {
      t.skip("build components first");
      return;
    }
  }

  const decoder = await instantiate(decoderPath);
  assert.equal(decoder.input_bytes_cap(), 64 * 1024 * 1024);
  assert.equal(decoder.output_bytes_cap(), 25_000_000 * 4 + 54);
  assert.equal(decoder.memory.buffer.byteLength, 448 * 1024 * 1024);
  assert.equal(
    exportedString(decoder, "input_content_type_ptr", "input_content_type_size"),
    "image/webp",
  );
  assert.equal(
    exportedString(decoder, "output_content_type_ptr", "output_content_type_size"),
    "image/bmp",
  );

  const opaqueBMP = buildBMP(17, 11);
  const lossyWebP = await encode(lossyEncoderPath, opaqueBMP, (exports) => {
    exports.uniform_set_quality(80);
    exports.uniform_set_method(0);
  });
  const lossyBMP = decode(decoder, lossyWebP);
  assertBMPHeader(lossyBMP, 17, 11);
  for (let i = 54 + 3; i < lossyBMP.length; i += 4) {
    assert.equal(lossyBMP[i], 255, "opaque WebP must decode with opaque alpha");
  }
  assert.ok(decoder.arena_peak_bytes() > 0);
  assert.ok(decoder.arena_allocation_count() > 0);
  assert.equal(decoder.arena_failed_allocation(), 0);
  assert.equal(decoder.arena_live_bytes(), 0);
  assert.equal(decoder.arena_free_unmatched_count(), 0);
  assert.equal(
    decode(decoder, markAnimated(lossyWebP, 17, 11)).length,
    0,
    "animated WebP must be rejected rather than reduced to one frame",
  );

  const alphaBMP = buildBMP(13, 9, true);
  const losslessWebP = await encode(losslessEncoderPath, alphaBMP, (exports) => {
    exports.uniform_set_level(0);
  });
  const losslessBMP = decode(decoder, losslessWebP);
  assertBMPHeader(losslessBMP, 13, 9);
  assert.deepEqual(
    losslessBMP.subarray(54),
    topDownPixels(alphaBMP, 13, 9),
    "lossless WebP must preserve BGRA, including RGB under transparency",
  );

  const second = decode(decoder, losslessWebP);
  assert.deepEqual(second, losslessBMP, "reused instance must decode deterministically");
});

test("webp-to-bmp-b8g8r8a8-srgb rejects malformed input", async (t) => {
  try {
    await access(decoderPath, constants.R_OK);
  } catch {
    t.skip("build components first");
    return;
  }
  const decoder = await instantiate(decoderPath);
  const memory = new Uint8Array(decoder.memory.buffer);
  memory.fill(0, decoder.input_ptr(), decoder.input_ptr() + 64);
  assert.equal(qipRenderSize(decoder, 0), 0);
  assert.equal(qipRenderSize(decoder, 64), 0);
});
