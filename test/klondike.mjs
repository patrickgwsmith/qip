import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const bytes = readFileSync(new URL("../gui/klondike.wasm", import.meta.url));

test("host seed reproduces an initial deal without changing an active deal", async () => {
  const seededGame = async (seed) => {
    const { instance } = await WebAssembly.instantiate(bytes);
    const game = instance.exports;
    assert.equal(game.uniform_set_seed(seed), seed);
    const frame = () => {
      const packed = game.render(0);
      return new TextDecoder().decode(new Uint8Array(game.memory.buffer, Number(packed >> 32n), Number(packed & 0xffffffffn)));
    };
    return { game, frame };
  };
  const first = await seededGame(12345);
  const same = await seededGame(12345);
  const other = await seededGame(67890);
  const deal = first.frame();
  assert.equal(deal, same.frame());
  assert.notEqual(deal, other.frame());
  assert.equal(first.game.uniform_set_seed(67890), 67890);
  assert.equal(first.frame(), deal);
});

test("Klondike renders SVG and completes a draw-one stock pass", async () => {
  const { instance } = await WebAssembly.instantiate(bytes);
  const game = instance.exports;
  const decoder = new TextDecoder("utf-8", { fatal: true });
  const frame = () => {
    const packed = game.render(0);
    const len = Number(packed & 0xffffffffn);
    const ptr = Number((packed >> 32n) & 0x7fffffffn);
    return decoder.decode(new Uint8Array(game.memory.buffer, ptr, len));
  };
  let time = 0;
  const update = (action) => {
    game.begin_update_at(BigInt(++time));
    const result = action();
    assert.equal(game.finish_update(), BigInt(time));
    return result;
  };

  const first = frame();
  assert.match(first, /^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg"/);
  assert.match(first, /<text x="780" y="246"[^>]*>0 moves<\/text>/);
  assert.match(first, /<g transform="translate\(46 82\)">/); // Stock card.

  for (let n = 0; n < 24; n++) assert.equal(update(() => game.key_event(32, 1)), 1);
  const emptyStock = frame();
  assert.doesNotMatch(emptyStock, /<g transform="translate\(46 82\)">/);
  assert.match(emptyStock, /<g transform="translate\(186 82\)">/); // Waste card.

  assert.equal(update(() => game.key_event(32, 1)), 1); // Recycle waste.
  const recycled = frame();
  assert.match(recycled, /<g transform="translate\(46 82\)">/);
  assert.doesNotMatch(recycled, /<g transform="translate\(186 82\)">/);

  update(() => game.pointer_event(1, 60, 310));
  assert.equal(update(() => game.pointer_event(1, 700, 650)), 1);
  assert.match(frame(), /<g transform="translate\(686 632\)">/);
  assert.equal(update(() => game.pointer_event(0, 700, 650)), 1);
  assert.doesNotMatch(frame(), /<g transform="translate\(686 632\)">/);

  assert.equal(update(() => game.key_event(78, 1)), 1); // N starts a new deal.
  assert.match(frame(), />0 moves<\/text>/);
});

test("a legal tableau drag moves the card and reveals the next one", async () => {
  const { instance } = await WebAssembly.instantiate(bytes);
  const game = instance.exports;
  const frame = () => {
    const packed = game.render(0);
    const len = Number(packed & 0xffffffffn);
    const ptr = Number((packed >> 32n) & 0x7fffffffn);
    return new TextDecoder().decode(new Uint8Array(game.memory.buffer, ptr, len));
  };
  const initial = frame();
  assert.match(initial, /<g transform="translate\(326 352\)">/); // Jack of clubs.

  game.begin_update_at(1n);
  game.pointer_event(1, 340, 370);
  game.pointer_event(1, 72, 320);
  assert.equal(game.pointer_event(0, 72, 320), 1);
  game.finish_update();

  const moved = frame();
  assert.match(moved, /<g transform="translate\(46 322\)">/); // Jack on red queen.
  assert.doesNotMatch(moved, /<g transform="translate\(326 352\)">/);
  assert.match(moved, /<g transform="translate\(326 322\)">/); // Newly revealed card.
  assert.match(moved, />1 move<\/text>/);

  game.begin_update_at(2n);
  assert.equal(game.pointer_event(0, 60, 306), 1); // Hover the covered queen.
  game.finish_update();
  assert.match(frame(), /<g transform="translate\(54 284\)">/);

  game.begin_update_at(3n);
  assert.equal(game.pointer_event(0, 60, 306), 0); // Same card needs no redraw.
  game.finish_update();

  game.begin_update_at(4n);
  assert.equal(game.pointer_event(0, -1, -1), 1); // Pointer leaves the board.
  game.finish_update();
  assert.equal(frame(), moved); // Hover did not change the deal.
});

test("dragging waste reveals the previous drawn card", async () => {
  const { instance } = await WebAssembly.instantiate(bytes);
  const game = instance.exports;
  const frame = () => {
    const packed = game.render(0);
    return new TextDecoder().decode(new Uint8Array(game.memory.buffer, Number(packed >> 32n), Number(packed & 0xffffffffn)));
  };
  const wasteCard = (svg) => svg.match(/<g transform="translate\(186 82\)">.*?<\/g>/)?.[0];
  frame();
  game.begin_update_at(1n);
  game.key_event(32, 1);
  game.finish_update();
  const previous = wasteCard(frame());
  assert.ok(previous);

  game.begin_update_at(2n);
  game.key_event(32, 1);
  game.finish_update();
  assert.notEqual(wasteCard(frame()), previous);

  game.begin_update_at(3n);
  game.pointer_event(1, 200, 110);
  assert.equal(game.pointer_event(1, 300, 250), 1);
  game.finish_update();
  const dragging = frame();
  assert.equal(wasteCard(dragging), previous);
  assert.match(dragging, /<g transform="translate\(286 222\)">/);
});
