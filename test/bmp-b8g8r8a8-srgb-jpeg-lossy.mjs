import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const encoderModule = await WebAssembly.compile(
  await readFile("image/bmp/bmp-b8g8r8a8-srgb-to-jpeg-lossy.wasm"),
);
const decoderModule = await WebAssembly.compile(
  await readFile("image/jpeg/jpeg-to-bmp-b8g8r8a8-srgb.wasm"),
);
const decoder = new TextDecoder();

test("the encoder declares one fixed 512 MiB memory", () => {
  const { exports } = new WebAssembly.Instance(encoderModule, {});
  assert.equal(exports.memory.buffer.byteLength, 512 * 1024 * 1024);
  assert.equal(exports.input_bytes_cap(), 25_000_000 * 4 + 64 * 1024);
  assert.equal(exports.output_bytes_cap(), 80 * 1024 * 1024);
  assert.throws(() => exports.memory.grow(1), RangeError);
});

function exportedString(exports, pointerName, sizeName) {
  return decoder.decode(
    new Uint8Array(exports.memory.buffer, exports[pointerName](), exports[sizeName]()),
  );
}

function makeBmp(width, height, pixel, explicitAlpha = false) {
  const pixelOffset = explicitAlpha ? 138 : 54;
  const bytes = Buffer.alloc(pixelOffset + width * height * 4);
  bytes.write("BM");
  bytes.writeUInt32LE(bytes.length, 2);
  bytes.writeUInt32LE(pixelOffset, 10);
  bytes.writeUInt32LE(explicitAlpha ? 124 : 40, 14);
  bytes.writeInt32LE(width, 18);
  bytes.writeInt32LE(height, 22);
  bytes.writeUInt16LE(1, 26);
  bytes.writeUInt16LE(32, 28);
  bytes.writeUInt32LE(explicitAlpha ? 3 : 0, 30);
  bytes.writeUInt32LE(width * height * 4, 34);
  if (explicitAlpha) {
    bytes.writeUInt32LE(0x00ff0000, 54);
    bytes.writeUInt32LE(0x0000ff00, 58);
    bytes.writeUInt32LE(0x000000ff, 62);
    bytes.writeUInt32LE(0xff000000, 66);
    bytes.writeUInt32LE(0x73524742, 70);
  }
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const [r, g, b, a = 255] = pixel(x, y);
      const at = pixelOffset + (y * width + x) * 4;
      bytes[at] = b;
      bytes[at + 1] = g;
      bytes[at + 2] = r;
      bytes[at + 3] = a;
    }
  }
  return bytes;
}

function encode(bmp, { quality = 85, subsample = 2, background = 0xffffff } = {}) {
  const { exports } = new WebAssembly.Instance(encoderModule, {});
  assert.equal(exportedString(exports, "input_content_type_ptr", "input_content_type_size"), "image/bmp");
  assert.equal(exportedString(exports, "output_content_type_ptr", "output_content_type_size"), "image/jpeg");
  exports.uniform_set_quality(quality);
  exports.uniform_set_subsample(subsample);
  exports.uniform_set_background_color_rgb(background);
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), bmp.length).set(bmp);
  const size = qipRenderSize(exports, bmp.length);
  assert.ok(size > 100);
  assert.ok(exports.arena_peak_bytes() > 0);
  assert.equal(exports.arena_live_bytes(), 0);
  assert.equal(exports.arena_failed_allocation(), 0);
  assert.equal(exports.arena_free_unmatched_count(), 0);
  return Buffer.from(new Uint8Array(exports.memory.buffer, qipRenderedOutputPointer(exports), size));
}

function sof(jpeg) {
  for (let i = 0; i + 10 < jpeg.length; i += 1) {
    if (jpeg[i] === 0xff && (jpeg[i + 1] === 0xc0 || jpeg[i + 1] === 0xc2)) {
      return {
        marker: jpeg[i + 1],
        height: jpeg.readUInt16BE(i + 5),
        width: jpeg.readUInt16BE(i + 7),
        ySampling: jpeg[i + 11],
      };
    }
  }
  throw new Error("JPEG has no SOF marker");
}

function decodeJpeg(jpeg) {
  const { exports } = new WebAssembly.Instance(decoderModule, {});
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), jpeg.length).set(jpeg);
  const size = qipRenderSize(exports, jpeg.length);
  assert.ok(size > 54);
  return Buffer.from(new Uint8Array(exports.memory.buffer, qipRenderedOutputPointer(exports), size));
}

test("MozJPEG emits deterministic baseline JPEG that QIP decodes", () => {
  const bmp = makeBmp(64, 48, (x, y) => [x * 4, y * 5, (x * 3 + y * 2) & 255]);
  const jpeg = encode(bmp);
  assert.equal(jpeg.readUInt16BE(0), 0xffd8);
  assert.equal(jpeg.readUInt16BE(jpeg.length - 2), 0xffd9);
  assert.deepEqual(sof(jpeg), { marker: 0xc0, width: 64, height: 48, ySampling: 0x22 });
  assert.deepEqual(jpeg, encode(bmp));
  const decoded = decodeJpeg(jpeg);
  assert.equal(decoded.readInt32LE(18), 64);
  assert.equal(decoded.readInt32LE(22), 48);
});

test("quality and chroma subsampling uniforms change the encoding", () => {
  const bmp = makeBmp(96, 64, (x, y) => [x * 2, y * 4, (x * 7 + y * 11) & 255]);
  const low = encode(bmp, { quality: 30, subsample: 2 });
  const high = encode(bmp, { quality: 95, subsample: 0 });
  assert.ok(low.length < high.length);
  assert.equal(sof(low).ySampling, 0x22);
  assert.equal(sof(high).ySampling, 0x11);
});

test("explicit BMP alpha composites onto the configured background", () => {
  const transparentRed = makeBmp(8, 8, () => [255, 0, 0, 0], true);
  const decoded = decodeJpeg(encode(transparentRed, { quality: 100, subsample: 0 }));
  const pixelOffset = decoded.readUInt32LE(10);
  assert.ok(decoded[pixelOffset] > 245);
  assert.ok(decoded[pixelOffset + 1] > 245);
  assert.ok(decoded[pixelOffset + 2] > 245);
});
