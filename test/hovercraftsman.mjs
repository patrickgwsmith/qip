import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const wasm = await readFile("gui/hovercraftsman.wasm");

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

function tap(game, at, key) {
  game.begin_update_at(at);
  game.key_event(key, 1);
  game.key_event(key, 0);
  return game.finish_update();
}

test("hovercraftsman declares KTX2 output and an 8 MiB memory cap", () => {
  const game = instantiate();
  assert.equal(game.key_event.length, 2);
  assert.equal(game.pointer_event.length, 3);
  assert.equal(game.input_bytes_cap(), 0);
  assert.ok(game.memory.buffer.byteLength <= 8 * 1024 * 1024);
  const contentType = new TextDecoder("utf-8", { fatal: true }).decode(
    new Uint8Array(game.memory.buffer, game.output_content_type_ptr(), game.output_content_type_size()),
  );
  assert.equal(contentType.split(";")[0].trim(), "image/ktx2");
});

test("hovercraftsman idles on the title, then runs fixed steps at the desk", () => {
  const game = instantiate();
  const size = qipRenderSize(game, 0);
  assert.equal(size, 224 + 640 * 480 * 4);
  const title = digestOutput(game, size);

  game.begin_update_at(1n);
  assert.equal(game.finish_update(), 1n);

  game.begin_update_at(2n);
  assert.equal(game.key_event(0x20, 1), 1);
  assert.equal(game.finish_update(), 18n);
  qipRenderSize(game, 0);
  assert.notEqual(digestOutput(game, size), title);

  let now = 18n;
  for (let i = 0; i < 10; i += 1) {
    game.begin_update_at(now);
    now += 16n;
    assert.equal(game.finish_update(), now);
  }
});

test("hovercraftsman's typing changes the CRT, and held keys do not", () => {
  const game = instantiate();
  const size = qipRenderSize(game, 0);
  tap(game, 1n, 0x20);
  // Typing replaces the mail with code, so the screen changes.
  tap(game, 2n, 0x6b);
  qipRenderSize(game, 0);
  const one = pixels(game, size);
  game.begin_update_at(3n);
  assert.equal(game.key_event(0x6b, 1), 1);
  assert.equal(game.key_event(0x6b, 1 | 2), 0);
  game.key_event(0x6b, 0);
  game.finish_update();
  qipRenderSize(game, 0);
  assert.notDeepEqual(pixels(game, size), one);
});

test("hovercraftsman pauses without wakes and resumes at the desk", () => {
  const game = instantiate();
  qipRenderSize(game, 0);
  tap(game, 1n, 0x20);
  game.begin_update_at(2n);
  assert.equal(game.key_event(0xff1b, 1), 1);
  assert.equal(game.finish_update(), 2n);
  assert.equal(game.begin_update_at(5000n), undefined);
  assert.equal(game.finish_update(), 5000n);
  qipRenderSize(game, 0);
  game.begin_update_at(5001n);
  assert.equal(game.key_event("p".codePointAt(0), 1), 1);
  assert.equal(game.finish_update(), 5017n);
});

test("hovercraftsman's BSPs draw the benchmark views as a depth buffer does", () => {
  const game = instantiate();
  const size = qipRenderSize(game, 0);
  for (let view = 0; view < 5; view += 1) {
    assert.equal(game.bench_set_view(view, 0), 1);
    qipRenderSize(game, 0);
    const bsp = pixels(game, size);
    assert.equal(game.bench_set_view(view, 4), 1);
    qipRenderSize(game, 0);
    const reference = pixels(game, size);
    let same = 0;
    for (let p = 0; p < bsp.length; p += 4) {
      if (Math.abs(bsp[p] - reference[p]) <= 8 && Math.abs(bsp[p + 1] - reference[p + 1]) <= 8 && Math.abs(bsp[p + 2] - reference[p + 2]) <= 8) same += 1;
    }
    assert.ok(same >= 0.995 * 640 * 480, `view ${view}: ${same} matching pixels`);
  }
  assert.equal(game.bench_set_view(-1, 0), 0);
  assert.ok(game.bench_stat(2) > 300 && game.bench_stat(3) > 300);
});

test("hovercraftsman turns the seated head by the change in pointer movement", () => {
  const game = instantiate();
  qipRenderSize(game, 0);
  tap(game, 1n, 0x20);
  game.begin_update_at(2n);
  game.uniform_set_pointer_total_movement_x(0);
  game.uniform_set_pointer_total_movement_y(0);
  game.finish_update();
  const ahead = digestOutput(game, qipRenderSize(game, 0));

  game.begin_update_at(3n);
  game.uniform_set_pointer_total_movement_x(300);
  game.finish_update();
  const turned = digestOutput(game, qipRenderSize(game, 0));
  assert.notEqual(turned, ahead);
});
