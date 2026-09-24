import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const renderCountsWasm = await readFile("gui/render-counts.wasm");
const mandelbrotWasm = await readFile("gui/mandelbrot.wasm");
const perlinNoiseWasm = await readFile("gui/perlin-noise.wasm");

function instantiate(bytes) {
  return new WebAssembly.Instance(new WebAssembly.Module(bytes), {}).exports;
}

function output(exports, size) {
  return new Uint8Array(exports.memory.buffer, qipRenderedOutputPointer(exports), size);
}

function digest(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function assertTransactionalInteractiveABI(exports) {
  for (const legacy of ["tick", "render_width_px", "render_height_px", "output_rgba8_srgb_bytes"]) {
    assert.equal(exports[legacy], undefined);
  }
  assert.equal(exports.key_event.length, 2);
  assert.equal(exports.pointer_event.length, 3);
  assert.equal(exports.input_bytes_cap(), 0);
  const contentType = new TextDecoder("utf-8", { fatal: true }).decode(
    new Uint8Array(
      exports.memory.buffer,
      exports.output_content_type_ptr(),
      exports.output_content_type_size(),
    ),
  );
  assert.equal(contentType, "image/ktx2");
}

function assertUpdateInteractiveABI(exports) {
  assertTransactionalInteractiveABI(exports);
  for (const legacy of ["begin_at", "commit"]) assert.equal(exports[legacy], undefined);
  assert.equal(typeof exports.begin_update_at, "function");
  assert.equal(typeof exports.finish_update, "function");
}

test("render counts exposes update ordering and keeps render as the only publisher", () => {
  const counts = instantiate(renderCountsWasm);
  assertUpdateInteractiveABI(counts);

  const size = qipRenderSize(counts, 0);
  assert.equal(size, 224 + 320 * 220 * 4);
  const initialDigest = digest(output(counts, size));

  counts.begin_update_at(16n);
  assert.equal(counts.key_event("A".codePointAt(0), 1), 1);
  assert.equal(counts.pointer_event(0, 40, 50), 1);
  assert.equal(digest(output(counts, size)), initialDigest);
  assert.equal(counts.finish_update(), 32n);
  assert.equal(digest(output(counts, size)), initialDigest);

  assert.equal(qipRenderSize(counts, 0), size);
  const eventDigest = digest(output(counts, size));
  assert.notEqual(eventDigest, initialDigest);

  counts.begin_update_at(48n);
  assert.equal(counts.key_event("b".codePointAt(0), 1), 1);
  assert.equal(counts.finish_update(), 64n);
  assert.equal(digest(output(counts, size)), eventDigest);
});

test("mandelbrot retains a viewport update until a separate render", () => {
  const mandelbrot = instantiate(mandelbrotWasm);
  assertUpdateInteractiveABI(mandelbrot);

  const size = qipRenderSize(mandelbrot, 0);
  assert.equal(size, 224 + 480 * 320 * 4);
  const initialDigest = digest(output(mandelbrot, size));
  assert.equal(initialDigest, "36dfde725f248b7e7c0d2c5e8c5e50acac8300c8bf0ce5c65611d105cc64c014");

  mandelbrot.begin_update_at(1n);
  assert.equal(mandelbrot.key_event(0xff53, 1), 1);
  assert.equal(mandelbrot.finish_update(), 1n);
  assert.equal(digest(output(mandelbrot, size)), initialDigest);

  assert.equal(qipRenderSize(mandelbrot, 0), size);
  assert.notEqual(digest(output(mandelbrot, size)), initialDigest);
});

test("perlin noise batches held-key time and bounds long catch-up", () => {
  const perlin = instantiate(perlinNoiseWasm);
  assertUpdateInteractiveABI(perlin);

  const size = qipRenderSize(perlin, 0);
  assert.equal(size, 224 + 480 * 320 * 4);
  const initialDigest = digest(output(perlin, size));
  assert.equal(initialDigest, "8b5bcb0553f8809c51c62626c85aac4ff4ab22d5509d9ee58d2218e8fe31c8ee");

  perlin.begin_update_at(1n);
  assert.equal(perlin.key_event(0xff53, 1), 1);
  assert.equal(perlin.finish_update(), 17n);
  assert.equal(digest(output(perlin, size)), initialDigest);

  perlin.begin_update_at(17n);
  assert.equal(perlin.finish_update(), 33n);
  assert.equal(digest(output(perlin, size)), initialDigest);

  assert.equal(qipRenderSize(perlin, 0), size);
  assert.notEqual(digest(output(perlin, size)), initialDigest);

  const longJump = instantiate(perlinNoiseWasm);
  qipRenderSize(longJump, 0);
  longJump.begin_update_at(1n);
  assert.equal(longJump.key_event(0xff53, 1), 1);
  assert.equal(longJump.finish_update(), 17n);
  longJump.begin_update_at(0x7fff_ffff_ffff_ffffn);
  assert.equal(longJump.finish_update(), 0x7fff_ffff_ffff_ffffn);
});

test("new update components trap on lifecycle misuse", () => {
  for (const bytes of [renderCountsWasm, mandelbrotWasm, perlinNoiseWasm]) {
    const exports = instantiate(bytes);
    assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
    qipRenderSize(exports, 0);
    assert.throws(() => exports.finish_update(), WebAssembly.RuntimeError);
    exports.begin_update_at(1n);
    assert.throws(() => qipRenderSize(exports, 0), WebAssembly.RuntimeError);
    exports.finish_update();
    assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
  }
});
