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
  assert.match(f.screen(), /Unicode name +Code points/);
  assert.match(f.screen(), /😀  grinning face +1F600/);
  assert.match(f.type("woman technologist"), /👩‍💻  woman technologist +1F469 200D 1F4BB/);
  assert.match(f.press(0xff0d).text, /Fully qualified RGI emoji/);
  assert.match(f.screen(), /1F469 200D 1F4BB/);
  assert.match(f.press(0xff1b).text, /Find: woman technologist_/);
  assert.match(f.press(0xff1b).text, /EMOJI FINDER  3972 \/ 3972/);
  assert.match(f.type("1F469 200D 1F4BB"), /woman technologist/);
});

test("Tab offers listed combinations and can extend a skin tone with a profession", () => {
  const f = finder();
  f.screen();
  assert.match(f.type("👩"), /👩  woman +1F469/);
  const combinations = f.press(0xff09).text;
  assert.match(combinations, /EMOJI COMBINATIONS/);
  assert.match(combinations, /Extend: 👩 woman/);
  assert.match(f.type("medium skin tone"), /👩🏽  woman: medium skin tone +1F469 1F3FD/);
  f.press(0xff54);
  assert.match(f.press(0xff09).text, /Extend: 👩🏽 woman: medium skin tone/);
  assert.match(f.type("laptop"), /👩🏽‍💻  woman technologist:.*1F469 1F3FD 200D 1F4BB/);
  assert.match(f.press(0xff0d).text, /1F469 1F3FD 200D 1F4BB/);
  assert.match(f.press(0xff1b).text, /EMOJI COMBINATIONS/);
  assert.match(f.press(0xff1b).text, /Find: 👩_/);
});

test("Emoji 18.0 entries come after older results, including in filtered searches", () => {
  const f = finder();
  f.screen();
  const matches = f.type("face");
  assert.match(matches, /^> 😂  face with tears of joy +1F602$/m);
  const last = f.press(0xff57).text;
  assert.match(last, /> 🫫  cracking face +1FAEB/);
  assert.match(f.press(0xff0d).text, /Added in Emoji\s+18\.0/);
});

test("Unicode name prefixes rank ahead of earlier substring matches", () => {
  const f = finder();
  f.screen();
  const partial = f.type("bea");
  assert.match(partial, /🐻  bear +1F43B/);
  assert.match(partial, /person: light skin tone, beard/);
  assert.ok(partial.indexOf("🐻  bear ") < partial.indexOf("person: light skin tone, beard"));
  const results = f.type("r");
  assert.match(results, /^> 🐻  bear +1F43B$/m);
  assert.match(results, /person: beard +1F9D4/);
  assert.match(f.press(0xff0d).text, /1F43B/);
});

test("leading spaces do not change the query or selected emoji", () => {
  const spaced = finder();
  const plain = finder();
  const initial = spaced.screen();
  plain.screen();
  assert.equal(spaced.type("   "), initial);
  assert.equal(spaced.type("bear"), plain.type("bear"));
  assert.match(spaced.press(0xff0d).text, /1F43B/);
});

test("the list starts at the top, then scrolls with the selected emoji centered", () => {
  const f = finder();
  f.exports.uniform_set_lines(12);
  const selectedLine = (screen) => screen.split("\n").findIndex((line) => line.startsWith("> "));
  const top = selectedLine(f.screen());
  assert.equal(top, 3);
  for (let i = 1; i <= 7; i += 1) {
    assert.equal(selectedLine(f.press(0xff54).text), top + Math.min(i, 4));
  }
  assert.equal(selectedLine(f.press(0xff57).text), top + 4);
  assert.equal(selectedLine(f.press(0xff50).text), top);
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
