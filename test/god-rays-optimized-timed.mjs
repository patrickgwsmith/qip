import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const wasm = await readFile("gui/god-rays-optimized.wasm");

function instantiate() {
  return new WebAssembly.Instance(new WebAssembly.Module(wasm), {}).exports;
}

function setDefaults(exports, speed = 0.75) {
  const values = {
    density: 0.3,
    spotty: 0.3,
    mid_size: 0.2,
    mid_intensity: 0.4,
    intensity: 0.8,
    bloom: 0.4,
    colors_count: 4,
    color_back: 0x000000ff,
    color_bloom: 0x0000ffff,
    color_1: 0xa600ff6e,
    color_2: 0x6200fff0,
    color_3: 0xffffffff,
    color_4: 0x33fff5ff,
    color_5: 0,
    fit: 1,
    scale: 1,
    rotation: 0,
    origin_x: 0.5,
    origin_y: 0.5,
    offset_x: 0,
    offset_y: -0.55,
    world_width: 0,
    world_height: 0,
    pixel_ratio: 1,
    speed,
    frame: 0,
  };
  for (const [key, value] of Object.entries(values)) {
    exports[`uniform_set_${key}`](value);
  }
}

function output(exports, size) {
  return new Uint8Array(exports.memory.buffer, qipRenderedOutputPointer(exports), size);
}

function digest(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

test("god-rays-optimized exposes the Timed KTX2 contract", () => {
  const exports = instantiate();
  for (const legacy of ["tick", "begin_at", "commit", "key_event", "pointer_event", "render_width_px", "render_height_px", "output_rgba8_srgb_bytes"]) {
    assert.equal(exports[legacy], undefined);
  }
  assert.equal(typeof exports.begin_update_at, "function");
  assert.equal(typeof exports.finish_update, "function");
  assert.equal(exports.input_bytes_cap(), 0);

  const contentType = new TextDecoder("utf-8", { fatal: true }).decode(
    new Uint8Array(
      exports.memory.buffer,
      exports.output_content_type_ptr(),
      exports.output_content_type_size(),
    ),
  );
  assert.equal(contentType, "image/ktx2");
});

test("initial Content render produces a canonical 640x360 KTX2 frame", () => {
  const exports = instantiate();
  setDefaults(exports);
  const size = qipRenderSize(exports, 0);
  const bytes = output(exports, size);
  assert.equal(size, 224 + 640 * 360 * 4);
  assert.deepEqual([...bytes.subarray(0, 12)], [0xab, 0x4b, 0x54, 0x58, 0x20, 0x32, 0x30, 0xbb, 0x0d, 0x0a, 0x1a, 0x0a]);
  const header = new DataView(bytes.buffer, bytes.byteOffset, 104);
  assert.equal(header.getUint32(12, true), 43);
  assert.equal(header.getUint32(20, true), 640);
  assert.equal(header.getUint32(24, true), 360);
  assert.equal(Number(header.getBigUint64(80, true)), 224);
  assert.equal(bytes[224 + 3], 255);
});

test("renderless updates preserve output and schedule from speed", () => {
  const exports = instantiate();
  setDefaults(exports, 0);
  const size = qipRenderSize(exports, 0);
  const initialDigest = digest(output(exports, size));

  exports.begin_update_at(1n);
  setDefaults(exports, 0);
  assert.equal(exports.finish_update(), 1n);
  assert.equal(digest(output(exports, size)), initialDigest);

  exports.begin_update_at(2n);
  setDefaults(exports, 0.75);
  assert.equal(exports.finish_update(), 18n);
  assert.equal(digest(output(exports, size)), initialDigest);
});

test("uniforms are optional and non-increasing time is host protocol misuse", () => {
  const exports = instantiate();
  setDefaults(exports, 0);
  qipRenderSize(exports, 0);
  exports.begin_update_at(1n);
  setDefaults(exports, 0);
  assert.equal(exports.finish_update(), 1n);
  assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);

  const missing = instantiate();
  for (const key of ["density", "spotty"]) missing[`uniform_set_${key}`](0.3);
  assert.equal(qipRenderSize(missing, 0), missing.output_bytes_cap());
});

test("presentation is separate and deterministic after updates", () => {
  const exports = instantiate();
  setDefaults(exports);
  const size = qipRenderSize(exports, 0);
  const initialDigest = digest(output(exports, size));

  exports.begin_update_at(1n);
  setDefaults(exports);
  assert.equal(exports.finish_update(), 17n);
  assert.equal(digest(output(exports, size)), initialDigest);

  setDefaults(exports);
  assert.equal(qipRenderSize(exports, 0), size);
  const updatedDigest = digest(output(exports, size));
  assert.notEqual(updatedDigest, initialDigest);

  setDefaults(exports);
  assert.equal(qipRenderSize(exports, 0), size);
  assert.equal(digest(output(exports, size)), updatedDigest);
  assert.equal(qipRenderSize(exports, 0), size);
  assert.equal(digest(output(exports, size)), updatedDigest);
});
