import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { renderSize, renderedOutputPointer } from "./lib/content-component-host.mjs";

const wasm = await readFile("tui/caniuse-finder.wasm");
const decoder = new TextDecoder("utf-8", { fatal: true });

function finder() {
  const exports = new WebAssembly.Instance(new WebAssembly.Module(wasm)).exports;
  let now = 0n;
  function screen() {
    const size = renderSize(exports, 0);
    return decoder.decode(new Uint8Array(exports.memory.buffer, renderedOutputPointer(exports), size));
  }
  function press(key) {
    exports.begin_update_at(++now);
    const accepted = exports.key_event(key, 1);
    assert.equal(exports.key_event(key, 0), 0);
    assert.equal(exports.finish_update(), now);
    return { accepted, text: screen() };
  }
  function type(value) {
    for (const character of value) press(character.codePointAt(0));
    return screen();
  }
  return { exports, screen, press, type };
}

test("Can I Use finder exposes the pinned offline dataset", () => {
  const f = finder();
  assert.equal(f.exports.input_ptr, undefined);
  assert.equal(f.exports.output_utf8_cap(), 64 * 1024);
  assert.match(f.screen(), /CAN I USE  caniuse\.com \(CC BY 4\.0\)  2026-09-24  554 \/ 554/);
});

test("an exact slug selects its feature ahead of related titles", () => {
  const f = finder();
  f.screen();
  assert.match(f.type("css-grid"), /^> CSS Grid Layout \(level 1\) \[css-grid\]$/m);
  assert.match(f.press(0xff0d).text, /caniuse\.com\/css-grid/);
  assert.match(f.press(0xff1b).text, /Find: css-grid_/);
});

test("support history and source notes explain a browser's status", () => {
  const f = finder();
  f.screen();
  assert.match(f.type("webp"), /^> WebP image format \[webp\]$/m);
  let frame = f.press(0xff0d).text;
  assert.match(frame, /Chrome\s+154 Full/);
  assert.match(frame, /Firefox\s+156 Full/);
  assert.match(frame, /Version history: 4–5: No; 6–8: No \(polyfill available\)/);
  frame = f.press(0xff54).text;
  frame = f.press(0xff54).text;
  assert.match(frame, /Safari details:/);
  assert.match(frame, /14–15\.6: Partial \(#3\)/);
  assert.match(frame, /requires macOS 11 Big Sur/);
});

test("disabled support is not presented as native support", () => {
  const f = finder();
  f.screen();
  f.type("css-grid-lanes");
  const frame = f.press(0xff0d).text;
  assert.match(frame, /Chrome\s+154 Disabled by default \(#1\)/);
  assert.match(frame, /Safari\s+27 Full/);
});

test("narrow frames stay bounded and no-match search cannot open details", () => {
  const f = finder();
  f.exports.uniform_set_columns(48);
  f.exports.uniform_set_lines(12);
  f.screen();
  assert.match(f.type("no-such-feature-987"), /No matches/);
  assert.equal(f.press(0xff0d).accepted, 0);
  f.press(0xff1b);
  f.type("webp");
  const frame = f.press(0xff0d).text;
  assert.ok(frame.trimEnd().split("\n").length <= 12);
  assert.ok(frame.trimEnd().split("\n").every((line) => [...line].length <= 48));
  const scrolled = f.press(0xff56);
  assert.equal(scrolled.accepted, 1);
  assert.notEqual(scrolled.text, frame);
});
