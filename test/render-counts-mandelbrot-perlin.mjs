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
  assert.equal(String(contentType).split(";")[0].trim(), "image/ktx2");
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
  assert.equal(size, 224 + 960 * 640 * 4);
  const initialDigest = digest(output(mandelbrot, size));
  assert.equal(initialDigest, "8b655ecc8ddd397a3d83e1f59e9c8b7682bc92d19704770f3a21434f0e267a56");

  // The exposed strip of the home view is cheap enough to refine within one
  // update, so no wake is needed.
  mandelbrot.begin_update_at(1n);
  assert.equal(mandelbrot.key_event(0xff53, 1), 1);
  assert.equal(mandelbrot.finish_update(), 1n);
  assert.equal(digest(output(mandelbrot, size)), initialDigest);

  assert.equal(qipRenderSize(mandelbrot, 0), size);
  assert.notEqual(digest(output(mandelbrot, size)), initialDigest);
});

test("mandelbrot settles to the same frame whether a drag lands during or after a zoom", () => {
  // Runs wake updates from `now`, the last update time, until the component
  // asks for none; returns the last update time.
  const settle = (exports, now, wake) => {
    for (let i = 0; i < 1000; i++) {
      if (wake === now) return now;
      now = wake;
      exports.begin_update_at(now);
      wake = exports.finish_update();
    }
    throw new Error("mandelbrot never went idle");
  };
  const drag = (exports, now) => {
    exports.begin_update_at(now);
    exports.pointer_event(1, 500, 300);
    assert.equal(exports.pointer_event(1, 540, 330), 1);
    exports.pointer_event(0, 540, 330);
    return exports.finish_update();
  };
  const zoom = (exports) => {
    qipRenderSize(exports, 0);
    exports.begin_update_at(1n);
    assert.equal(exports.pointer_event(1, 300, 200), 0);
    assert.equal(exports.pointer_event(0, 300, 200), 1);
    // The zoom animates, so the update asks for the next frame.
    assert.equal(exports.finish_update(), 17n);
  };

  // Zoom, let it settle, then drag.
  const late = instantiate(mandelbrotWasm);
  zoom(late);
  let now = settle(late, 1n, 17n) + 1n;
  now = settle(late, now, drag(late, now));
  const size = qipRenderSize(late, 0);
  const lateDigest = digest(output(late, size));

  // Zoom, then drag in the middle of the animation.
  const early = instantiate(mandelbrotWasm);
  zoom(early);
  settle(early, 40n, drag(early, 40n));
  assert.equal(qipRenderSize(early, 0), size);
  assert.equal(digest(output(early, size)), lateDigest);

  // A settled component asks for no wake and renders the same bytes again.
  late.begin_update_at(now + 1n);
  assert.equal(late.finish_update(), now + 1n);
  assert.equal(qipRenderSize(late, 0), size);
  assert.equal(digest(output(late, size)), lateDigest);
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
