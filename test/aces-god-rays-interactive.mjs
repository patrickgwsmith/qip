import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const modules = Object.fromEntries(
  await Promise.all(
    ["aces-up", "god-rays"].map(async (name) => [name, await readFile(`gui/${name}.wasm`)]),
  ),
);

function instantiate(name) {
  return new WebAssembly.Instance(new WebAssembly.Module(modules[name]), {}).exports;
}

function output(exports, size) {
  return new Uint8Array(exports.memory.buffer, qipRenderedOutputPointer(exports), size);
}

function digest(exports, size) {
  return createHash("sha256").update(output(exports, size)).digest("hex");
}

function assertContentABI(exports, hasEvents, outputType = "image/ktx2") {
  for (const legacy of ["tick", "render_width_px", "render_height_px", "output_rgba8_srgb_bytes"]) {
    assert.equal(exports[legacy], undefined);
  }
  assert.equal(exports.input_bytes_cap(), 0);
  assert.equal(exports.begin_at, undefined);
  assert.equal(exports.commit, undefined);
  assert.equal(typeof exports.begin_update_at, "function");
  assert.equal(typeof exports.finish_update, "function");
  assert.equal(typeof exports.key_event, hasEvents ? "function" : "undefined");
  assert.equal(typeof exports.pointer_event, hasEvents ? "function" : "undefined");
  const type = new TextDecoder("utf-8", { fatal: true }).decode(
    new Uint8Array(exports.memory.buffer, exports.output_content_type_ptr(), exports.output_content_type_size()),
  );
  assert.equal(type.split(";")[0].trim(), outputType);
}

function setGodRaysUniforms(exports, speed = 0.75) {
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
  for (const [name, value] of Object.entries(values)) exports[`uniform_set_${name}`](value);
}

test("Aces Up advances an SVG deal without replacing published output", () => {
  const exports = instantiate("aces-up");
  assertContentABI(exports, true, "image/svg+xml");
  assert.equal(exports.key_event.length, 2);
  assert.equal(exports.pointer_event.length, 3);
  assert.equal(typeof exports.output_utf8_cap, "function");
  assert.equal(exports.output_bytes_cap, undefined);

  const size = qipRenderSize(exports, 0);
  assert.ok(size > 1000);
  assert.match(new TextDecoder().decode(output(exports, size)), /^<svg /);
  const firstCard = digest(exports, size);

  exports.begin_update_at(75n);
  assert.equal(exports.finish_update(), 150n);
  assert.equal(digest(exports, size), firstCard);

  const secondSize = qipRenderSize(exports, 0);
  assert.notEqual(digest(exports, secondSize), firstCard);
  exports.begin_update_at(150n);
  assert.equal(exports.finish_update(), 225n);
  exports.begin_update_at(225n);
  assert.equal(exports.finish_update(), 225n);
  const fourCards = new TextDecoder().decode(output(exports, qipRenderSize(exports, 0)));
  assert.match(fourCards, /FOUR PILES/);
  assert.match(fourCards, /48 left/);
});

test("Aces Up traps on update lifecycle misuse", () => {
  const exports = instantiate("aces-up");
  assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
  qipRenderSize(exports, 0);
  assert.throws(() => exports.finish_update(), WebAssembly.RuntimeError);
  exports.begin_update_at(1n);
  assert.throws(() => qipRenderSize(exports, 0), WebAssembly.RuntimeError);
  exports.finish_update();
  assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
});

test("Aces Up discards a lower top card and moves another into its empty pile", () => {
  const exports = instantiate("aces-up");
  const frame = () => new TextDecoder().decode(output(exports, qipRenderSize(exports, 0)));
  frame();
  for (const now of [75n, 150n, 225n]) {
    exports.begin_update_at(now);
    exports.finish_update();
  }
  const initial = frame();
  assert.match(initial, /<g transform="translate\(598 218\)">/);

  exports.begin_update_at(226n);
  exports.pointer_event(1, 650, 290); // Discard the outlined 6 of spades.
  assert.equal(exports.pointer_event(0, 650, 290), 1);
  exports.finish_update();
  const afterDiscard = frame();
  assert.match(afterDiscard, />1 discarded<\/text>/);
  assert.match(afterDiscard, /<g transform="translate\(824 418\)">/);
  assert.doesNotMatch(afterDiscard, /<g transform="translate\(598 218\)">/);

  exports.begin_update_at(227n);
  exports.pointer_event(1, 300, 290); // Move the 10 of spades from pile two.
  exports.pointer_event(1, 650, 290);
  assert.equal(exports.pointer_event(0, 650, 290), 1);
  exports.finish_update();
  const afterMove = frame();
  assert.match(afterMove, /<g transform="translate\(598 218\)">/);
  assert.doesNotMatch(afterMove, /<g transform="translate\(246 218\)">/);
  assert.match(afterMove, /Move a top card into the empty pile/);

  exports.begin_update_at(228n);
  assert.equal(exports.pointer_event(1, 875, 290), 1); // Deal onto all four piles, including the empty one.
  exports.pointer_event(0, 875, 290);
  assert.equal(exports.finish_update(), 303n);
  const afterDeal = frame();
  assert.match(afterDeal, /Dealing a row/);
  assert.match(afterDeal, /47 left/);
});

test("God Rays is an event-free Timed KTX2 component", () => {
  const exports = instantiate("god-rays");
  assertContentABI(exports, false);
  setGodRaysUniforms(exports);
  const size = qipRenderSize(exports, 0);
  assert.equal(size, 224 + 640 * 360 * 4);
  const initial = digest(exports, size);

  exports.begin_update_at(16n);
  setGodRaysUniforms(exports);
  assert.equal(exports.finish_update(), 32n);
  assert.equal(digest(exports, size), initial);
  setGodRaysUniforms(exports);
  assert.equal(qipRenderSize(exports, 0), size);
  assert.notEqual(digest(exports, size), initial);
});

test("God Rays uses defaults for omitted uniforms", () => {
  const exports = instantiate("god-rays");
  exports.uniform_set_density(0.3);
  exports.uniform_set_spotty(0.3);
  assert.equal(qipRenderSize(exports, 0), 224 + 640 * 360 * 4);

  const update = instantiate("god-rays");
  qipRenderSize(update, 0);
  update.begin_update_at(1n);
  update.uniform_set_density(0.3);
  assert.equal(update.finish_update(), 17n);
});
