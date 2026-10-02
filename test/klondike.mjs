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
  const hovering = frame();
  assert.match(hovering, /<g transform="translate\(46 280\)">/); // Queen pokes up in place.
  assert.doesNotMatch(hovering, /<g transform="translate\(46 292\)">/);
  assert.ok(hovering.indexOf("translate(46 280)") < hovering.indexOf("translate(46 322)"), "jack still covers the queen");

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

test("clicking an ace animates it to its foundation", async () => {
  const { instance } = await WebAssembly.instantiate(bytes);
  const game = instance.exports;
  const frame = () => {
    const packed = game.render(0);
    return new TextDecoder().decode(new Uint8Array(game.memory.buffer, Number(packed >> 32n), Number(packed & 0xffffffffn)));
  };
  const wasteAce = /<g transform="translate\(186 82\)">(?:(?!<\/g>).)*>A<\/text><svg [^>]*data-suit="(\w+)"/;
  frame();
  let time = 0;
  let suit;
  for (let n = 0; n < 24 && !suit; n++) {
    game.begin_update_at(BigInt(++time));
    game.key_event(32, 1);
    game.finish_update();
    suit = frame().match(wasteAce)?.[1];
  }
  assert.ok(suit, "the default deal turns up an ace from the stock");
  const slotX = 46 + (["spades", "hearts", "diamonds", "clubs"].indexOf(suit) + 3) * 140;

  game.begin_update_at(BigInt(++time));
  game.pointer_event(1, 200, 110);
  assert.equal(game.pointer_event(0, 200, 110), 1);
  const start = time;
  assert.equal(game.finish_update(), BigInt(start + 16));
  const takeoff = frame();
  assert.match(takeoff, /<g transform="translate\(186 82\)">(?:(?!<\/g>).)*>A<\/text>/); // Still at the waste.

  game.begin_update_at(BigInt(start + 120));
  assert.equal(game.finish_update(), BigInt(start + 136));
  const midway = frame().match(/<g transform="translate\((\d+) 82\)">(?:(?!<\/g>).)*>A<\/text>/g).at(-1);
  const midX = Number(midway.match(/translate\((\d+)/)[1]);
  assert.ok(midX > 186 && midX < slotX, `midway x ${midX}`);

  game.begin_update_at(BigInt(start + 240));
  assert.equal(game.finish_update(), BigInt(start + 240)); // Landed; no further wake.
  assert.match(frame(), new RegExp(`<g transform="translate\\(${slotX} 82\\)">(?:(?!</g>).)*>A</text>`));
});
