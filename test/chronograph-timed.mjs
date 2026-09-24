import { renderSize, renderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const wasm = await readFile("gui/chronograph.wasm");

function instantiate() {
  return new WebAssembly.Instance(new WebAssembly.Module(wasm), {}).exports;
}

function output(exports, size) {
  return new Uint8Array(exports.memory.buffer, renderedOutputPointer(exports), size);
}

function digest(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

test("chronograph exposes a Timed canonical KTX2 component", () => {
  const exports = instantiate();
  assert.equal(exports.input_bytes_cap(), 0);
  assert.equal(typeof exports.begin_update_at, "function");
  assert.equal(typeof exports.finish_update, "function");
  assert.equal(typeof exports.uniform_set_current_seconds, "function");
  assert.equal(typeof exports.uniform_set_hdr, "function");
  assert.equal(exports.key_event, undefined);
  assert.equal(typeof exports.pointer_event, "function");

  const contentType = new TextDecoder().decode(new Uint8Array(
    exports.memory.buffer,
    exports.output_content_type_ptr(),
    exports.output_content_type_size(),
  ));
  assert.equal(contentType, "image/ktx2");

  assert.ok(Math.abs(exports.uniform_set_current_seconds(75.39) - 15.2) < 0.001);
  const size = renderSize(exports, 0);
  const bytes = output(exports, size);
  const header = new DataView(bytes.buffer, bytes.byteOffset, 104);
  assert.equal(size, 224 + 360 * 360 * 4);
  assert.equal(header.getUint32(12, true), 43);
  assert.equal(header.getUint32(20, true), 360);
  assert.equal(header.getUint32(24, true), 360);
  assert.equal(bytes[224 + 3], 0, "outer background should be transparent");
  assert.equal(bytes[224 + (180 * 360 + 180) * 4 + 3], 255, "dial should remain opaque");
});

test("HDR chronograph emits RGBA32F linear Display P3 and resets to SDR", () => {
  const exports = instantiate();
  exports.uniform_set_current_seconds(15.2);
  assert.equal(exports.uniform_set_hdr(1), 1);
  const hdrSize = renderSize(exports, 0);
  const bytes = output(exports, hdrSize);
  const header = new DataView(bytes.buffer, bytes.byteOffset, 224);
  assert.equal(hdrSize, 224 + 360 * 360 * 16);
  assert.equal(header.getUint32(12, true), 109);
  assert.equal(header.getUint32(16, true), 4);
  assert.equal(bytes[117], 12, "DFD should identify Display P3 primaries");
  assert.equal(bytes[118], 1, "DFD should identify a linear transfer function");

  const pixels = new Float32Array(bytes.buffer, bytes.byteOffset + 224, 360 * 360 * 4);
  assert.equal(pixels[3], 0, "outer background should remain transparent");
  assert.ok(pixels.some((value, index) => index % 4 !== 3 && value > 1));

  const sdrSize = renderSize(exports, 0);
  const sdr = output(exports, sdrSize);
  assert.equal(sdrSize, 224 + 360 * 360 * 4);
  assert.equal(new DataView(sdr.buffer, sdr.byteOffset, 20).getUint32(12, true), 43);
});

test("current_seconds changes the hand and updates publish only through render", () => {
  const exports = instantiate();
  exports.uniform_set_current_seconds(14);
  const size = renderSize(exports, 0);
  const fourteen = digest(output(exports, size));

  exports.begin_update_at(1n);
  exports.uniform_set_current_seconds(14.2);
  assert.equal(exports.finish_update(), 201n);
  assert.equal(digest(output(exports, size)), fourteen);

  assert.equal(renderSize(exports, 0), size);
  const nextStep = digest(output(exports, size));
  assert.notEqual(nextStep, fourteen);

  exports.uniform_set_current_seconds(14.2);
  assert.equal(renderSize(exports, 0), size);
  assert.equal(digest(output(exports, size)), nextStep);
});

test("one clock uniform seeds autonomous Timed updates", () => {
  const exports = instantiate();
  exports.uniform_set_current_seconds(14);
  const size = renderSize(exports, 0);
  const initial = digest(output(exports, size));

  exports.begin_update_at(1n);
  exports.uniform_set_current_seconds(14);
  assert.equal(exports.finish_update(), 201n);
  exports.uniform_set_current_seconds(14);
  assert.equal(renderSize(exports, 0), size);
  assert.equal(digest(output(exports, size)), initial);

  exports.begin_update_at(201n);
  exports.uniform_set_current_seconds(14);
  assert.equal(exports.finish_update(), 401n);
  exports.uniform_set_current_seconds(14);
  assert.equal(renderSize(exports, 0), size);
  assert.notEqual(digest(output(exports, size)), initial);
});

test("horizontal drag tilts the dial and release animates toward rest", () => {
  const exports = instantiate();
  exports.uniform_set_current_seconds(14);
  const size = renderSize(exports, 0);
  const faceOn = digest(output(exports, size));

  exports.begin_update_at(1n);
  assert.equal(exports.pointer_event(1, 180, 180), 1);
  assert.equal(exports.finish_update(), 201n);

  exports.begin_update_at(2n);
  assert.equal(exports.pointer_event(1, 260, 180), 1);
  assert.equal(exports.finish_update(), 202n);
  assert.equal(renderSize(exports, 0), size);
  const tilted = digest(output(exports, size));
  assert.notEqual(tilted, faceOn);

  exports.begin_update_at(3n);
  assert.equal(exports.pointer_event(0, 260, 180), 1);
  assert.equal(exports.finish_update(), 17n);
  exports.begin_update_at(17n);
  assert.equal(exports.finish_update(), 33n);
  assert.equal(renderSize(exports, 0), size);
  assert.notEqual(digest(output(exports, size)), tilted);
});

test("chronograph traps on Timed lifecycle misuse", () => {
  const exports = instantiate();
  assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
  assert.throws(() => exports.pointer_event(1, 180, 180), WebAssembly.RuntimeError);
  renderSize(exports, 0);
  assert.throws(() => exports.finish_update(), WebAssembly.RuntimeError);
  exports.begin_update_at(1n);
  assert.throws(() => renderSize(exports, 0), WebAssembly.RuntimeError);
  assert.equal(exports.finish_update(), 201n);
  assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
});
