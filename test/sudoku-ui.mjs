import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const WIDTH = 762;
const HEIGHT = 522;
const BOARD_X = 18;
const BOARD_Y = 18;
const CELL_PX = 54;
const NUMBER_PAD_X = 544;
const NUMBER_PAD_Y = 137;
const CLEAR_X = 608;
const CLEAR_Y = 329;
const NEW_X = 592;
const NEW_Y = 448;

async function makeGame() {
  const bytes = await readFile("gui/sudoku.wasm");
  return (await WebAssembly.instantiate(bytes, {})).instance.exports;
}

function render(game) {
  const length = qipRenderSize(game, 0);
  assert.equal(length, 224 + WIDTH * HEIGHT * 4);
  const copy = new Uint8Array(new Uint8Array(game.memory.buffer, qipRenderedOutputPointer(game), length));
  return copy.subarray(224);
}

function press(game, x, y) {
  const accepted = game.pointer_event(1, x, y);
  game.pointer_event(0, x, y);
  return accepted;
}

function countColor(frame, x0, y0, width, height, color) {
  let count = 0;
  for (let y = y0; y < y0 + height; y++) {
    for (let x = x0; x < x0 + width; x++) {
      const offset = (y * WIDTH + x) * 4;
      if (
        frame[offset] === color[0] &&
        frame[offset + 1] === color[1] &&
        frame[offset + 2] === color[2] &&
        frame[offset + 3] === color[3]
      ) {
        count++;
      }
    }
  }
  return count;
}

function findCell(frame, color, minimumPixels) {
  for (let index = 0; index < 81; index++) {
    const x = BOARD_X + (index % 9) * CELL_PX;
    const y = BOARD_Y + Math.floor(index / 9) * CELL_PX;
    if (countColor(frame, x + 2, y + 2, 50, 50, color) >= minimumPixels) {
      return index;
    }
  }
  return -1;
}

function hash(frame) {
  let value = 2166136261;
  for (const byte of frame) {
    value = Math.imul(value ^ byte, 16777619);
  }
  return value >>> 0;
}

test("sudoku supports its primary pointer workflow", async () => {
  const game = await makeGame();
  for (const legacy of ["tick", "render_width_px", "render_height_px", "output_rgba8_srgb_bytes"]) {
    assert.equal(game[legacy], undefined);
  }
  assert.equal(game.key_event.length, 2);
  assert.equal(game.pointer_event.length, 3);
  assert.equal(game.begin_at, undefined);
  assert.equal(game.commit, undefined);

  const initial = render(game);
  const selected = findCell(initial, [242, 201, 76, 255], 2000);
  const given = findCell(initial, [255, 255, 255, 255], 1);
  assert.notEqual(selected, -1);
  assert.notEqual(given, -1);

  const givenX = BOARD_X + (given % 9) * CELL_PX + 27;
  const givenY = BOARD_Y + Math.floor(given / 9) * CELL_PX + 27;
  game.begin_update_at(1n);
  assert.equal(press(game, givenX, givenY), 0);
  assert.equal(game.finish_update(), 1n);
  assert.equal(hash(new Uint8Array(game.memory.buffer, qipRenderedOutputPointer(game) + 224, WIDTH * HEIGHT * 4)), hash(initial));

  game.begin_update_at(2n);
  assert.equal(press(game, NUMBER_PAD_X + 92, NUMBER_PAD_Y + 92), 1);
  assert.equal(game.finish_update(), 2n);
  const selectedX = BOARD_X + (selected % 9) * CELL_PX;
  const selectedY = BOARD_Y + Math.floor(selected / 9) * CELL_PX;
  const numbered = render(game);
  assert.ok(countColor(numbered, selectedX, selectedY, CELL_PX, CELL_PX, [15, 15, 14, 255]) > 0);

  game.begin_update_at(3n);
  assert.equal(press(game, CLEAR_X + 28, CLEAR_Y + 28), 1);
  assert.equal(game.finish_update(), 3n);
  const cleared = render(game);
  assert.equal(countColor(cleared, selectedX + 2, selectedY + 2, 50, 50, [15, 15, 14, 255]), 0);

  const beforeNew = cleared;
  game.begin_update_at(4n);
  assert.equal(press(game, NEW_X + 44, NEW_Y + 28), 1);
  assert.equal(game.finish_update(), 4n);
  const newPuzzle = render(game);
  assert.notEqual(hash(newPuzzle), hash(beforeNew));
});

test("sudoku candidate targets are row-major and ignore identical pointer moves", async () => {
  const game = await makeGame();
  const initial = render(game);
  const selected = findCell(initial, [242, 201, 76, 255], 2000);
  const cellX = BOARD_X + (selected % 9) * CELL_PX;
  const cellY = BOARD_Y + Math.floor(selected / 9) * CELL_PX;

  let lastX = 0;
  let lastY = 0;
  let now = 0n;
  for (let digit = 1; digit <= 9; digit++) {
    const slot = digit - 1;
    const column = slot % 3;
    const row = Math.floor(slot / 3);
    lastX = cellX + column * 18 + 9;
    lastY = cellY + row * 18 + 9;

    now += 1n;
    game.begin_update_at(now);
    assert.equal(game.pointer_event(0, lastX, lastY), 1);
    assert.equal(game.finish_update(), now);
    const preview = render(game);
    assert.ok(
      countColor(preview, cellX + column * 18, cellY + row * 18, 18, 18, [210, 173, 67, 255]) > 200,
      `candidate ${digit} did not preview in its row-major slot`,
    );

    now += 1n;
    game.begin_update_at(now);
    assert.equal(game.pointer_event(0, lastX + 1, lastY + 1), 0);
    assert.equal(game.finish_update(), now);
    assert.equal(hash(new Uint8Array(game.memory.buffer, qipRenderedOutputPointer(game) + 224, WIDTH * HEIGHT * 4)), hash(preview));
  }

  now += 1n;
  game.begin_update_at(now);
  assert.equal(game.pointer_event(4, lastX, lastY), 0);
  assert.equal(press(game, lastX, lastY), 1);
  assert.equal(game.finish_update(), now);
  const candidate = render(game);
  assert.ok(countColor(candidate, cellX + 40, cellY + 38, 10, 14, [15, 15, 14, 255]) > 0);
});
