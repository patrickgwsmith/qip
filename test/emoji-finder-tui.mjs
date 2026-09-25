import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { renderSize, renderedOutputPointer } from "./lib/content-component-host.mjs";

const wasm = await readFile("tui/emoji-finder.wasm");
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

test("finder lists the pinned Unicode emoji and searches names and code points", () => {
  const f = finder();
  assert.equal(f.exports.input_ptr, undefined);
  assert.equal(f.exports.output_utf8_cap(), 32 * 1024);
  assert.match(f.screen(), /EMOJI FINDER  3972 \/ 3972/);
  assert.match(f.type("woman technologist"), /👩‍💻  woman technologist/);
  assert.match(f.press(0xff0d).text, /Fully qualified RGI emoji/);
  assert.match(f.screen(), /1F469 200D 1F4BB/);
  assert.match(f.press(0xff1b).text, /Find: woman technologist_/);
  assert.match(f.press(0xff1b).text, /EMOJI FINDER  3972 \/ 3972/);
  assert.match(f.type("1F469 200D 1F4BB"), /woman technologist/);
});

test("Tab offers listed combinations and can extend a skin tone with a profession", () => {
  const f = finder();
  f.screen();
  assert.match(f.type("👩"), /👩  woman/);
  const combinations = f.press(0xff09).text;
  assert.match(combinations, /EMOJI COMBINATIONS/);
  assert.match(combinations, /Extend: 👩 woman/);
  assert.match(f.type("medium skin tone"), /👩🏽  woman: medium skin tone/);
  f.press(0xff54);
  assert.match(f.press(0xff09).text, /Extend: 👩🏽 woman: medium skin tone/);
  assert.match(f.type("laptop"), /👩🏽‍💻  woman technologist: medium skin tone/);
  assert.match(f.press(0xff0d).text, /1F469 1F3FD 200D 1F4BB/);
  assert.match(f.press(0xff1b).text, /EMOJI COMBINATIONS/);
  assert.match(f.press(0xff1b).text, /Find: 👩_/);
});

test("unsupported combinations are absent and narrow screens remain bounded", () => {
  const f = finder();
  f.exports.uniform_set_columns(40);
  f.exports.uniform_set_lines(8);
  f.screen();
  f.type("👩");
  f.press(0xff09);
  assert.match(f.type("tractor"), /No listed combination/);
  assert.equal(f.press(0xff0d).accepted, 0);
  const frame = f.screen();
  assert.ok(frame.trimEnd().split("\n").length <= 8);
  assert.ok(frame.trimEnd().split("\n").every((line) => [...line].length <= 40));
});
