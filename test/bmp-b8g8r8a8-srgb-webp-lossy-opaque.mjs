import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const moduleUrl = new URL(
  "../image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy-opaque.wasm",
  import.meta.url,
);

function rgbAt(x, y) {
  return {
    r: (x * 19 + y * 7) & 0xff,
    g: (x * 5 + y * 17) & 0xff,
    b: (x * 13 + y * 3) & 0xff,
  };
}

function buildBmp(width, height, { bits = 32, v5Alpha = false, pixels } = {}) {
  const dibSize = v5Alpha ? 124 : 40;
  const pixelOffset = 14 + dibSize;
  const stride = Math.ceil(width * bits / 32) * 4;
  const bmp = Buffer.alloc(pixelOffset + stride * height);
  bmp.write("BM", 0, "ascii");
  bmp.writeUInt32LE(bmp.length, 2);
  bmp.writeUInt32LE(pixelOffset, 10);
  bmp.writeUInt32LE(dibSize, 14);
  bmp.writeInt32LE(width, 18);
  bmp.writeInt32LE(height, 22);
  bmp.writeUInt16LE(1, 26);
  bmp.writeUInt16LE(bits, 28);
  bmp.writeUInt32LE(v5Alpha ? 3 : 0, 30);
  bmp.writeUInt32LE(stride * height, 34);
  if (v5Alpha) {
    bmp.writeUInt32LE(0x00ff0000, 54);
    bmp.writeUInt32LE(0x0000ff00, 58);
    bmp.writeUInt32LE(0x000000ff, 62);
    bmp.writeUInt32LE(0xff000000, 66);
    bmp.writeUInt32LE(0x73524742, 70);
  }
  for (let fileY = 0; fileY < height; fileY += 1) {
    const y = height - 1 - fileY;
    for (let x = 0; x < width; x += 1) {
      const pixel = pixels?.(x, y) ?? { ...rgbAt(x, y), a: 255 };
      const offset = pixelOffset + fileY * stride + x * bits / 8;
      bmp[offset] = pixel.b;
      bmp[offset + 1] = pixel.g;
      bmp[offset + 2] = pixel.r;
      if (bits === 32) bmp[offset + 3] = pixel.a ?? 255;
    }
  }
  return bmp;
}

function encode(exports, bmp) {
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), bmp.length).set(bmp);
  const size = qipRenderSize(exports, bmp.length);
  assert.ok(size > 0);
  return Buffer.from(exports.memory.buffer, qipRenderedOutputPointer(exports), size);
}

function composite(channel, background, alpha) {
  return Math.floor((channel * alpha + background * (255 - alpha) + 127) / 255);
}

test("opaque WebP accepts BGR/BGRX and composites declared V5 alpha", async () => {
  const wasm = await readFile(moduleUrl);
  const { instance: { exports } } = await WebAssembly.instantiate(wasm, {});

  assert.equal(exports.memory.buffer.byteLength, 448 * 1024 * 1024);
  assert.equal(exports.input_bytes_cap(), 25_000_000 * 4 + 64 * 1024);
  assert.equal(exports.output_bytes_cap(), 64 * 1024 * 1024);
  assert.equal(exports.uniform_set_quality(95), 95);
  assert.equal(exports.uniform_set_method(6), 6);
  assert.equal(exports.uniform_set_sharp_yuv(1), 1);
  assert.equal(exports.uniform_set_low_memory(1), 1);

  const bgr = buildBmp(63, 47, { bits: 24 });
  const bgrx = buildBmp(63, 47, {
    pixels: (x, y) => ({ ...rgbAt(x, y), a: (x * 29 + y * 11) & 0xff }),
  });
  const bgrOutput = encode(exports, bgr);
  const bgrPixels = Buffer.from(new Uint8Array(
    exports.memory.buffer, exports.input_ptr(), 63 * 47 * 4,
  ));
  const bgrxOutput = encode(exports, bgrx);
  const bgrxPixels = Buffer.from(new Uint8Array(
    exports.memory.buffer, exports.input_ptr(), 63 * 47 * 4,
  ));
  const firstPixelDifference = bgrPixels.findIndex((byte, index) => byte !== bgrxPixels[index]);
  assert.equal(firstPixelDifference, -1,
    `BGR expansion differs at byte ${firstPixelDifference}, pixel ${Math.floor(firstPixelDifference / 4)}: ` +
    `${[...bgrPixels.subarray(firstPixelDifference - 8, firstPixelDifference + 12)]} != ` +
    `${[...bgrxPixels.subarray(firstPixelDifference - 8, firstPixelDifference + 12)]}`);
  assert.deepEqual(bgrOutput, bgrxOutput,
    "the fourth byte of legacy 32-bit BI_RGB must be ignored");
  assert.equal(bgrOutput.subarray(0, 4).toString("ascii"), "RIFF");
  assert.equal(bgrOutput.subarray(8, 12).toString("ascii"), "WEBP");
  assert.equal(bgrOutput.subarray(12, 16).toString("ascii"), "VP8 ");
  assert.ok(!bgrOutput.includes(Buffer.from("ALPH")));

  const background = 0x2468ac;
  assert.equal(exports.uniform_set_background_color_rgb(0xff2468ac), background);
  const withAlpha = (x, y) => ({
    ...rgbAt(x, y),
    a: (x * 37 + y * 23) & 0xff,
  });
  const flattened = (x, y) => {
    const source = withAlpha(x, y);
    return {
      r: composite(source.r, 0x24, source.a),
      g: composite(source.g, 0x68, source.a),
      b: composite(source.b, 0xac, source.a),
      a: 0,
    };
  };
  const alphaOutput = encode(exports, buildBmp(64, 48, {
    v5Alpha: true,
    pixels: withAlpha,
  }));
  const precompositedOutput = encode(exports, buildBmp(64, 48, {
    pixels: flattened,
  }));
  assert.deepEqual(alphaOutput, precompositedOutput,
    "V5 alpha must be composited over the selected background before encoding");
  assert.ok(!alphaOutput.includes(Buffer.from("ALPH")));

  assert.ok(exports.arena_peak_bytes() > 0);
  assert.ok(exports.arena_allocation_count() > 0);
  assert.equal(exports.arena_failed_allocation(), 0);
  assert.equal(exports.arena_free_unmatched_count(), 0);
  assert.equal(exports.arena_free_count(), exports.arena_free_matched_count());
});
