import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { renderSize, renderedOutputPointer } from "./lib/content-component-host.mjs";

const wasm = await readFile("tui/browser-compat-finder.wasm");
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

test("finder exposes the inputless TUI contract and pinned BCD snapshot", () => {
  const f = finder();
  assert.equal(f.exports.input_ptr, undefined);
  assert.equal(f.exports.output_utf8_cap(), 64 * 1024);
  assert.equal(f.exports.uniform_set_columns(80), 80);
  assert.equal(f.exports.uniform_set_lines(24), 24);
  assert.match(f.screen(), /BROWSER COMPAT  BCD 8\.1\.2  13603 \/ 13603/);
  assert.match(f.screen(), /> api\.ANGLE_instanced_arrays/);
});

test("Web API search compares four browsers and retains historical conditions", () => {
  const f = finder();
  f.screen();
  assert.match(f.type("api.Navigator.gpu"), /api\.Navigator\.gpu/);
  const details = f.press(0xff0d).text;
  assert.match(details, /Chrome\s+144\+ \* history/);
  assert.match(details, /Firefox\s+141\+ \*/);
  assert.match(details, /Safari\s+26\+/);
  assert.match(details, /partial implementation/);
  assert.match(details, /removed in 144/);
  assert.match(f.press(0xff54).text, /Firefox statements:/);
  assert.match(f.screen(), /Supported on Windows only/);
  assert.match(f.press(0xff1b).text, /Find: api\.Navigator\.gpu_/);
});

test("CSS search shows alternate prefixed support", () => {
  const f = finder();
  f.screen();
  f.type("css.properties.backdrop-filter");
  f.press(0xff0d);
  f.press(0xff54);
  const safari = f.press(0xff54).text;
  assert.match(safari, /Safari\s+18\+ \* \+1 forms/);
  assert.match(safari, /prefix -webkit-/);
});

test("flags, unsupported browsers, scrolling, and narrow frames", () => {
  const f = finder();
  f.exports.uniform_set_columns(48);
  f.exports.uniform_set_lines(11);
  f.screen();
  f.type("api.AmbientLightSensor");
  let frame = f.press(0xff0d).text;
  assert.match(frame, /Chrome\s+56\+ \*/);
  assert.match(frame, /Firefox\s+No/);
  assert.match(frame, /#enable-experimental-web-platform-features/);
  frame = f.press(0xff56).text;
  assert.match(frame, /Enabled/);
  assert.ok(frame.trimEnd().split("\n").length <= 11);
  assert.ok(frame.trimEnd().split("\n").every((line) => [...line].length <= 48));
  assert.equal(f.press(0xff56).accepted, 0);
  assert.equal(f.press(0xff55).accepted, 1);
});

test("no match and lifecycle boundaries", () => {
  const f = finder();
  assert.throws(() => f.exports.begin_update_at(1n), WebAssembly.RuntimeError);
  f.screen();
  assert.throws(() => f.exports.finish_update(), WebAssembly.RuntimeError);
  assert.match(f.type("not-a-real-api-feature"), /No matches/);
  assert.equal(f.press(0xff0d).accepted, 0);
  f.exports.begin_update_at(1000n);
  assert.throws(() => f.exports.render(0), WebAssembly.RuntimeError);
});
