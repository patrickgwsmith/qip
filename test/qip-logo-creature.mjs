import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { wasmMustComplyWithComponentContract } from "../npm/qipx/qipx.mjs";

const bytes = await readFile("gui/qip-logo-creature.wasm");
const header = await readFile("recipes/text/markdown/header.html", "utf8");

function creature(seed = 7, { intro = 1 } = {}) {
  const e = new WebAssembly.Instance(new WebAssembly.Module(bytes), {}).exports;
  e.uniform_set_seed(seed);
  e.uniform_set_intro(intro);
  const read = () => {
    const result = BigInt.asUintN(64, e.render(0));
    return new TextDecoder().decode(new Uint8Array(e.memory.buffer, Number(result >> 32n), Number(result & 0xffffffffn)));
  };
  let time = 0;
  const update = (fn = () => {}) => {
    e.begin_update_at(BigInt(++time));
    const changed = fn(e);
    const wake = Number(e.finish_update());
    return { changed, wake, time };
  };
  // Advance in 16 ms steps, as <qip-play> does while the component asks for frames.
  const run = (ms) => {
    const end = time + ms;
    while (time < end) {
      time += 15;
      update();
    }
  };
  read();
  update();
  return { e, read, update, run, now: () => time };
}

function rects(svg) {
  return [...svg.matchAll(/<rect x="([-\d.]+)" y="([-\d.]+)" width="(\d+)" height="(\d+)" rx="[\d.]+" fill="(#[0-9A-F]{6})" transform="translate\(([-\d.]+) ([-\d.]+)\) rotate\(([-\d.]+)\)"( opacity="0")?\/>/g)]
    .map(([, x, y, w, h, fill, tx, ty, a, hidden]) => ({ left: +tx + +x, top: +ty + +y, w: +w, h: +h, fill, a: +a, hidden: !!hidden }));
}

const eyes = (svg) => (svg.match(/<g class="eye"/g) ?? []).length;
const happyEyes = (svg) => (svg.match(/<g class="eye"[^>]*><ellipse [^>]*\/><path /g) ?? []).length;

test("component complies and starts as the header logo", () => {
  assert.doesNotThrow(() => wasmMustComplyWithComponentContract(bytes));
  const { read } = creature();
  const svg = read();
  assert.match(svg, /^<svg xmlns="http:\/\/www.w3.org\/2000\/svg" width="800" height="600" viewBox="0 0 800 600">/);
  assert.equal(eyes(svg), 0);
  const drawn = rects(svg);
  assert.equal(drawn.length, 12);
  assert.equal(new Set(drawn.map((r) => r.fill)).size, 1, "the resting logo is one color");
  assert.ok(drawn.every((r) => r.a === 0));

  // Same bars as the site header's logo, at 30 px per grid cell.
  const logo = [...header.matchAll(/<rect x="(\d+)" y="(\d+)" width="(\d+)" height="(\d+)" \/>/g)]
    .map(([, x, y, w, h]) => `${(+x - 7.5) * 30 + 395},${(+y - 8) * 30 + 300},${w * 30},${h * 30}`);
  const key = (r) => `${Math.round(r.left)},${Math.round(r.top)},${r.w},${r.h}`;
  assert.deepEqual(drawn.map(key).sort(), logo.sort());
});

test("intro assembles a creature once and returns to the logo without further wakes", () => {
  const { read, update, run, now } = creature();
  const logo = read();
  const { wake } = update();
  assert.ok(wake > now(), "asks to wake for the intro");
  run(2000);
  const shown = read();
  assert.equal(eyes(shown), 2, "the crab's two eyes are drawn");
  assert.ok(new Set(rects(shown).map((r) => r.fill)).size >= 2, "palette colors replace the logo orange");
  run(4000);
  assert.equal(read(), logo);
  const idle = update();
  assert.equal(idle.wake, idle.time, "settled logo requests no wake");
});

test("intro uniform 0 keeps the logo still, as the site header uses it", () => {
  const { read, update, run } = creature(7, { intro: 0 });
  const logo = read();
  const first = update();
  assert.equal(first.wake, first.time, "asks for no intro wake");
  run(4000);
  assert.equal(read(), logo);
  assert.match(header, /data-uniform-intro="0"/);
});

test("hover builds the next creature, follows the pointer, and leaving restores the logo", () => {
  const { read, update, run } = creature();
  const logo = read();
  assert.equal(update((e) => e.pointer_event(0, 400, 300)).changed, 1);
  run(2500);
  const first = read();
  assert.ok(eyes(first) > 0);
  assert.equal(update((e) => e.pointer_event(0, 400, 300)).changed, 0, "a still pointer is not a change");
  update((e) => e.pointer_event(0, 790, 300));
  run(600);
  assert.notEqual(read(), first, "pupils and lean follow the pointer");

  update((e) => e.pointer_event(0, -1, -1));
  run(3000);
  assert.equal(read(), logo);

  update((e) => e.pointer_event(0, 400, 300));
  run(2500);
  const second = read();
  assert.notDeepEqual(rects(second).map((r) => r.w), rects(first).map((r) => r.w), "a different creature draws its bars in a different order");
});

test("press pins the creature past pointer leave, and a second press dismisses it", () => {
  const { read, update, run } = creature();
  const logo = read();
  update((e) => { e.pointer_event(0, 400, 300); return e.pointer_event(1, 400, 300); });
  update((e) => e.pointer_event(0, 400, 300));
  update((e) => e.pointer_event(0, -1, -1));
  run(3000);
  assert.ok(eyes(read()) > 0, "still assembled after leaving");

  update((e) => { e.pointer_event(0, 400, 300); e.pointer_event(1, 400, 300); return e.pointer_event(0, 400, 300); });
  run(3000);
  assert.equal(read(), logo, "dismissed while the pointer is still over it");

  assert.equal(update((e) => e.key_event(0x20, 1)).changed, 1);
  run(2500);
  assert.ok(new Set(rects(read()).map((r) => r.fill)).size >= 2, "Space pins the next shape from the keyboard");
});

test("the same seed replays the same frames", () => {
  const frames = (seed) => {
    const { read, update, run } = creature(seed);
    update((e) => e.pointer_event(0, 500, 200));
    run(300);
    const mid = read();
    run(2000);
    return [mid, read()];
  };
  assert.deepEqual(frames(42), frames(42));
  assert.notDeepEqual(frames(42), frames(43));
});

test("a creature smiles with ^ ^ eyes after it lands, then opens them again", () => {
  const { read, update, run } = creature(7, { intro: 0 });
  update((e) => e.key_event(0x6e, 1));
  run(400);
  assert.equal(happyEyes(read()), 0, "eyes are open while the bars land");
  run(900);
  const smiling = read();
  assert.equal(eyes(smiling), 2);
  assert.equal(happyEyes(smiling), 2, "both eyes become arcs with a blush");
  run(1500);
  assert.equal(happyEyes(read()), 0);
  assert.equal(eyes(read()), 2);
});

test("every other shape is a three-letter term, formats with a leading period, a phosphor TUI with a blinking cursor and a neon underlined GUI, centred on the logo", () => {
  const { read, update, run } = creature(7, { intro: 0 });
  const words = [];
  for (let n = 0; n < 12; n++) {
    update((e) => e.key_event(0x6e, 1));
    run(1600);
    const svg = read();
    if (eyes(svg) > 0) continue;
    const bars = rects(svg);
    assert.equal(bars.length, 12, "every logo bar is still drawn");
    assert.ok(!svg.includes("<ellipse"), "words cast no shadow");
    // Horizontal extents of each bar as rotated. A diagonal's corners land
    // within a pixel of its letter's cell edge, so V can end a word.
    const turn = (r) => Math.min(r.a % 180, 180 - (r.a % 180));
    const spans = bars.map((r) => {
      const t = (r.a * Math.PI) / 180, cx = r.left + r.w / 2;
      const half = Math.abs((r.w / 2) * Math.cos(t)) + Math.abs((r.h / 2) * Math.sin(t));
      return [cx - half, cx + half];
    });
    const left = Math.min(...spans.map(([l]) => l));
    const right = Math.max(...spans.map(([, r]) => r));
    assert.ok(Math.abs((left + right) / 2 - 395) < 1, "centred on the logo");
    const baseline = 300 + 2.5 * 30; // letters are 5 cells tall, centred on the logo

    const six = bars.find((r) => r.h === 180);
    const caret = six && turn(six) < 0.5 ? six : undefined;
    const underline = six && Math.abs(turn(six) - 90) < 0.5 ? six : undefined;
    const dot = bars.find((r) => r.w === 30 && r.h === 30);
    assert.equal([caret, underline, dot].filter(Boolean).length, 1, "a word has one cursor, underline or period");
    const mark = caret ?? underline ?? dot;
    assert.equal(svg.includes('filter="url(#neon)"'), !!underline, "only the neon word glows");
    assert.equal(svg.includes('filter="url(#phosphor)"'), !!caret, "only the terminal word has a phosphor bloom");
    if (underline) {
      // The 6-cell bar and a 3-cell bar lie end to end below the letters as
      // one rule exactly as wide as the word.
      const [ruleLeft, sixRight] = spans[bars.indexOf(underline)];
      const sixMid = underline.top + underline.h / 2;
      const restIndex = bars.findIndex((r, i) => r.w * r.h === 90 * 30 && Math.abs(spans[i][1] - spans[i][0] - 90) < 1 &&
        Math.abs(spans[i][0] - sixRight) < 1 && Math.abs(r.top + r.h / 2 - sixMid) < 1);
      assert.ok(restIndex >= 0, "a 3-cell bar continues the underline");
      const rest = bars[restIndex];
      assert.ok(Math.abs(ruleLeft - left) < 1 && Math.abs(spans[restIndex][1] - right) < 1, "the underline spans the word");
      assert.equal(underline.fill, rest.fill, "the underline is one tube");
      // Like a neon sign, the tubes switch to new hues every so often.
      const fills = new Set(bars.map((r) => r.fill).join());
      for (let i = 0; i < 8; i++) {
        run(1100);
        const frame = rects(read());
        assert.ok(!frame.some((r) => r.hidden), "the underline does not blink");
        fills.add(frame.map((r) => r.fill).join());
      }
      assert.ok(fills.size >= 3, "the neon colors change over time");
      words.push("underline");
    } else if (caret) {
      // The 6-cell bar stands upright after the letters as the cursor, and blinks.
      // Letters and cursor share one phosphor, like a monochrome terminal.
      assert.equal(new Set(bars.map((r) => r.fill)).size, 1, "the terminal word is one phosphor color");
      assert.notEqual(mark.fill, "#F5DFC8", "the cursor glows in the phosphor, not ink");
      assert.ok(Math.abs(caret.left + caret.w - right) < 1, "cursor ends the word");
      const seen = new Set();
      for (let i = 0; i < 8; i++) {
        run(150);
        seen.add(rects(read()).find((r) => r.h === 180).hidden);
      }
      assert.deepEqual([...seen].sort(), [false, true]);
      words.push("cursor");
    } else {
      assert.equal(mark.fill, "#F5DFC8", "the period is in ink");
      // The 6-cell bar shrinks to a one-cell period on the baseline before the letters.
      assert.ok(Math.abs(dot.left - left) < 1, "period starts the word");
      assert.ok(Math.abs(dot.top + dot.h - baseline) < 1, "period sits on the baseline");
      for (let i = 0; i < 8; i++) {
        run(150);
        assert.ok(!rects(read()).some((r) => r.hidden), "the period does not blink");
      }
      words.push("period");
    }
    if (!caret) assert.equal(new Set(bars.map((r) => r.fill)).size, 4, "three letter colors plus the mark");
    if (underline) {
      // Centred on the logo vertically too, the underline included.
      // Vertical extents as rotated, like spans above.
      const rows = bars.map((r) => {
        const t = (r.a * Math.PI) / 180, cy = r.top + r.h / 2;
        const half = Math.abs((r.w / 2) * Math.sin(t)) + Math.abs((r.h / 2) * Math.cos(t));
        return [cy - half, cy + half];
      });
      const top = Math.min(...rows.map(([t]) => t)), bottom = Math.max(...rows.map(([, b]) => b));
      assert.ok(Math.abs(bottom - (underline.top + underline.h / 2 + 15)) < 1, "the underline is the lowest stroke");
      // The letters breathe by up to 0.12 cells while the underline holds still.
      assert.ok(Math.abs((top + bottom) / 2 - 300) < 4, "letters and underline centre on the logo");
    }
  }
  assert.deepEqual(words, ["period", "period", "period", "period", "cursor", "underline"], ".SVG, .CSV, .PNG, .ZIG, TUI|, then a neon underlined GUI");
});

test("six characters take turns with the terms, each inside the frame", () => {
  const { read, update, run } = creature(7, { intro: 0 });
  const layouts = [];
  for (let n = 0; n < 12; n++) {
    update((e) => e.key_event(0x6e, 1));
    run(1600);
    const svg = read();
    const isCharacter = eyes(svg) > 0;
    assert.equal(isCharacter, n % 2 === 0, "characters and terms alternate");
    if (!isCharacter) continue;
    const bars = rects(svg);
    assert.equal(bars.length, 12, "every logo bar is drawn");
    for (const r of bars) {
      const t = (r.a * Math.PI) / 180, cx = r.left + r.w / 2, cy = r.top + r.h / 2;
      const hx = Math.abs((r.w / 2) * Math.cos(t)) + Math.abs((r.h / 2) * Math.sin(t));
      const hy = Math.abs((r.w / 2) * Math.sin(t)) + Math.abs((r.h / 2) * Math.cos(t));
      assert.ok(cx - hx > 0 && cx + hx < 800 && cy - hy > 0 && cy + hy < 600, "bars stay inside the viewBox");
    }
    layouts.push(bars.map((r) => `${Math.round(r.left / 30)},${Math.round(r.top / 30)},${Math.round(r.a / 15)}`).sort().join(" "));
  }
  assert.equal(new Set(layouts).size, 6, "crab, bird, giraffe, starfish, snail and flamingo all differ");
});
