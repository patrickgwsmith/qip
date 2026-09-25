import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { renderSize, renderedOutputPointer } from "./lib/content-component-host.mjs";

const wasm = await readFile("tui/iana-media-type-finder.wasm");
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

test("media finder exposes the pinned inputless TUI", () => {
  const f = finder();
  assert.equal(f.exports.input_ptr, undefined);
  assert.equal(f.exports.output_utf8_cap(), 64 * 1024);
  assert.match(f.screen(), /MEDIA TYPE FINDER  IANA 2026-09-22  2361 \/ 2361/);
});

test("media type and RFC search, details, and obsolete labels", () => {
  const f = finder();
  f.screen();
  assert.match(f.type("application/json"), /> application\/json\n/);
  assert.match(f.press(0xff0d).text, /References\s+RFC 8259/);
  assert.match(f.press(0xff1b).text, /Find: application\/json_/);
  f.press(0xff1b);
  assert.match(f.type("application/javascript"), /OBSOLETED in favor of text\/javascript/);
  assert.match(f.press(0xff0d).text, /IANA label\s+\(OBSOLETED in favor of text\/javascript\)/);
});

test("search by reference, no-match, and bounded narrow frames", () => {
  const f = finder();
  f.exports.uniform_set_columns(40);
  f.exports.uniform_set_lines(8);
  f.screen();
  assert.match(f.type("RFC 8259"), /application\/json/);
  f.press(0xff1b);
  assert.match(f.type("not-a-real-media-type"), /No matches/);
  assert.equal(f.press(0xff0d).accepted, 0);
  for (const frame of [f.screen(), f.press(0xff1b).text, f.press(0xff0d).text]) {
    assert.ok(frame.trimEnd().split("\n").length <= 8);
    assert.ok(frame.trimEnd().split("\n").every((line) => [...line].length <= 40));
  }
});
