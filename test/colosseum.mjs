import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const wasm = await readFile("gui/colosseum.wasm");

function instantiate() {
  return new WebAssembly.Instance(new WebAssembly.Module(wasm), {}).exports;
}

function digestOutput(exports, size) {
  return createHash("sha256")
    .update(new Uint8Array(exports.memory.buffer, qipRenderedOutputPointer(exports), size))
    .digest("hex");
}

function pixels(exports, size) {
  return new Uint8Array(exports.memory.buffer, qipRenderedOutputPointer(exports) + 224, size - 224).slice();
}

test("colosseum declares KTX2 output and a 16 MiB memory cap", () => {
  const game = instantiate();
  assert.equal(game.key_event.length, 2);
  assert.equal(game.pointer_event.length, 3);
  assert.equal(game.input_bytes_cap(), 0);
  assert.ok(game.memory.buffer.byteLength <= 16 * 1024 * 1024);
  const contentType = new TextDecoder("utf-8", { fatal: true }).decode(
    new Uint8Array(game.memory.buffer, game.output_content_type_ptr(), game.output_content_type_size()),
  );
  assert.equal(contentType.split(";")[0].trim(), "image/ktx2");
});

test("colosseum idles on the title, then walks in fixed steps", () => {
  const game = instantiate();
  const size = qipRenderSize(game, 0);
  assert.equal(size, 224 + 640 * 480 * 4);
  const title = digestOutput(game, size);

  game.begin_update_at(1n);
  assert.equal(game.finish_update(), 1n);

  game.begin_update_at(2n);
  assert.equal(game.key_event(0x20, 1), 1);
  assert.equal(game.finish_update(), 18n);
  assert.equal(digestOutput(game, size), title);

  game.begin_update_at(18n);
  assert.equal(game.key_event(0x20, 0), 0);
  assert.equal(game.key_event(0xff52, 1), 1);
  assert.equal(game.finish_update(), 34n);

  let now = 34n;
  for (let i = 0; i < 30; i += 1) {
    game.begin_update_at(now);
    now += 16n;
    assert.equal(game.finish_update(), now);
  }
  assert.equal(qipRenderSize(game, 0), size);
  assert.notEqual(digestOutput(game, size), title);
});

test("colosseum pauses without wakes and B swaps to the polygon BSP", () => {
  const game = instantiate();
  const size = qipRenderSize(game, 0);
  game.begin_update_at(1n);
  game.key_event(0x20, 1);
  game.finish_update();
  qipRenderSize(game, 0);
  const sectors = digestOutput(game, size);

  game.begin_update_at(2n);
  assert.equal(game.key_event("p".codePointAt(0), 1), 1);
  assert.equal(game.key_event("b".codePointAt(0), 1), 1);
  assert.equal(game.finish_update(), 2n);
  qipRenderSize(game, 0);
  // The HUD names the renderer, so the frames differ.
  assert.notEqual(digestOutput(game, size), sectors);
  assert.ok(game.bench_stat(2) > 0);

  game.begin_update_at(5000n);
  assert.equal(game.key_event("p".codePointAt(0), 1), 1);
  assert.equal(game.finish_update(), 5016n);
});

test("colosseum's two renderers draw the benchmark views alike", () => {
  const game = instantiate();
  const size = qipRenderSize(game, 0);
  for (let view = 0; view < 6; view += 1) {
    assert.equal(game.bench_set_view(view, 0), 1);
    qipRenderSize(game, 0);
    const sectors = pixels(game, size);
    assert.equal(game.bench_set_view(view, 1), 1);
    qipRenderSize(game, 0);
    const bsp = pixels(game, size);
    let same = 0;
    for (let p = 0; p < sectors.length; p += 4) {
      if (Math.abs(sectors[p] - bsp[p]) <= 8 && Math.abs(sectors[p + 1] - bsp[p + 1]) <= 8 && Math.abs(sectors[p + 2] - bsp[p + 2]) <= 8) same += 1;
    }
    assert.ok(same >= 0.99 * 640 * 480, `view ${view}: ${same} matching pixels`);
  }
  assert.equal(game.bench_set_view(-1, 0), 0);
});

test("colosseum turns by the change in pointer total movement", () => {
  const game = instantiate();
  qipRenderSize(game, 0);
  game.begin_update_at(1n);
  game.uniform_set_pointer_total_movement_x(0);
  game.uniform_set_pointer_total_movement_y(0);
  assert.equal(game.pointer_event(1, 100, 100), 1);
  game.finish_update();
  const ahead = digestOutput(game, qipRenderSize(game, 0));

  game.begin_update_at(2n);
  game.uniform_set_pointer_total_movement_x(120);
  game.uniform_set_pointer_total_movement_y(-40);
  game.finish_update();
  const turned = digestOutput(game, qipRenderSize(game, 0));
  assert.notEqual(turned, ahead);

  game.begin_update_at(3n);
  game.uniform_set_pointer_total_movement_x(120);
  game.uniform_set_pointer_total_movement_y(-40);
  game.finish_update();
  assert.equal(digestOutput(game, qipRenderSize(game, 0)), turned);
});
