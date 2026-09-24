import { renderSize, renderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const width = 512;
const height = 342;
const pixelCount = width * height;
const wasm = await readFile("gui/macintosh-1bit.wasm");

function instantiate() {
  return new WebAssembly.Instance(new WebAssembly.Module(wasm), {}).exports;
}

function output(exports, size) {
  return new Uint8Array(exports.memory.buffer, renderedOutputPointer(exports), size);
}

function digest(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

test("Macintosh desktop exposes an Interactive KTX2 component", () => {
  const exports = instantiate();
  assert.equal(exports.input_bytes_cap(), 0);
  assert.equal(typeof exports.begin_update_at, "function");
  assert.equal(typeof exports.finish_update, "function");
  assert.equal(typeof exports.pointer_event, "function");
  assert.equal(typeof exports.key_event, "function");

  const contentType = new TextDecoder().decode(new Uint8Array(
    exports.memory.buffer,
    exports.output_content_type_ptr(),
    exports.output_content_type_size(),
  ));
  assert.equal(contentType, "image/ktx2");

  const size = renderSize(exports, 0);
  const bytes = output(exports, size);
  const header = new DataView(bytes.buffer, bytes.byteOffset, 224);
  assert.equal(size, 224 + pixelCount * 4);
  assert.equal(header.getUint32(12, true), 43);
  assert.equal(header.getUint32(20, true), width);
  assert.equal(header.getUint32(24, true), height);
});

test("SDR output contains only opaque black and white pixels", () => {
  const exports = instantiate();
  const size = renderSize(exports, 0);
  const bytes = output(exports, size);
  let black = 0;
  let white = 0;
  for (let offset = 224; offset < size; offset += 4) {
    const value = bytes[offset];
    assert.ok(value === 0 || value === 255);
    assert.equal(bytes[offset + 1], value);
    assert.equal(bytes[offset + 2], value);
    assert.equal(bytes[offset + 3], 255);
    if (value === 0) black += 1;
    else white += 1;
  }
  assert.ok(black > 1_000);
  assert.ok(white > 100_000);
});

test("pointer events move the software cursor and drag the window", () => {
  const exports = instantiate();
  const size = renderSize(exports, 0);
  const initial = digest(output(exports, size));

  exports.begin_update_at(1n);
  assert.equal(exports.pointer_event(0, 100, 100), 1);
  assert.equal(exports.finish_update(), 1n);
  assert.equal(renderSize(exports, 0), size);
  assert.notEqual(digest(output(exports, size)), initial);

  exports.begin_update_at(2n);
  assert.equal(exports.pointer_event(1, 100, 59), 1);
  assert.equal(exports.finish_update(), 2n);
  exports.begin_update_at(3n);
  assert.equal(exports.pointer_event(1, 150, 89), 1);
  assert.equal(exports.finish_update(), 3n);
  assert.equal(renderSize(exports, 0), size);
  const dragged = digest(output(exports, size));

  exports.begin_update_at(4n);
  assert.equal(exports.pointer_event(0, 150, 89), 0);
  assert.equal(exports.finish_update(), 4n);
  assert.equal(renderSize(exports, 0), size);
  assert.notEqual(dragged, initial);
});

test("Interactive lifecycle misuse traps", () => {
  const exports = instantiate();
  assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
  assert.throws(() => exports.pointer_event(0, 10, 10), WebAssembly.RuntimeError);
  renderSize(exports, 0);
  assert.throws(() => exports.finish_update(), WebAssembly.RuntimeError);
  exports.begin_update_at(1n);
  assert.throws(() => renderSize(exports, 0), WebAssembly.RuntimeError);
  assert.equal(exports.finish_update(), 1n);
});
