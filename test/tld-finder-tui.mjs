import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { renderSize, renderedOutputPointer } from "./lib/content-component-host.mjs";

const wasm = await readFile("tui/tld-finder.wasm");
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

test("TLD finder exposes an inputless TUI with the pinned delegated list", () => {
  const f = finder();
  assert.equal(f.exports.input_ptr, undefined);
  assert.equal(f.exports.output_utf8_cap(), 16 * 1024);
  assert.equal(f.exports.uniform_set_columns(80), 80);
  assert.equal(f.exports.uniform_set_lines(24), 24);
  assert.match(f.screen(), /TLD FINDER  1438 \/ 1438/);
  assert.match(f.screen(), /> \.aaa\s+generic/);
});

test("search covers domain, Unicode label, type, and manager", () => {
  const byDomain = finder();
  byDomain.screen();
  assert.match(byDomain.type(".dev"), /\.dev\s+generic\s+Charleston Road Registry/);
  assert.match(byDomain.screen(), /TLD FINDER  1 \/ 1438/);
  assert.match(byDomain.press(0xff08).text, /Find: \.de_/);
  assert.match(byDomain.press(0xff1b).text, /TLD FINDER  1438 \/ 1438/);

  const byUnicode = finder();
  byUnicode.screen();
  assert.match(byUnicode.type("中国"), /\.xn--fiqs8s\s+country-code/);

  const byType = finder();
  byType.screen();
  assert.match(byType.type("infrastructure"), /\.arpa\s+infrastructure/);

  const byManager = finder();
  byManager.screen();
  assert.match(byManager.type("Museum Domain Management"), /\.museum\s+sponsored/);
});

test("details show the Unicode form and delegation caveat", () => {
  const f = finder();
  f.screen();
  f.type("xn--fiqs8s");
  const details = f.press(0xff0d).text;
  assert.match(details, /TLD DETAILS/);
  assert.match(details, /\.中国/);
  assert.match(details, /ASCII \/ IDNA\s+\.xn--fiqs8s/);
  assert.match(details, /IANA snapshot\s+2026092400/);
  assert.match(details, /Delegated does not imply open registration/);
  assert.match(f.press(0xff1b).text, /Find: xn--fiqs8s_/);
});

test("paging, no-match and small screens remain bounded", () => {
  const f = finder();
  f.exports.uniform_set_columns(40);
  f.exports.uniform_set_lines(8);
  f.screen();
  assert.match(f.press(0xff54).text, /> \.aarp/);
  assert.match(f.press(0xff50).text, /> \.aaa/);
  assert.match(f.press(0xff56).text, />/);
  f.type("no-such-tld-ever");
  assert.match(f.screen(), /No matches/);
  assert.equal(f.press(0xff0d).accepted, 0);
  for (const frame of [f.screen(), f.press(0xff1b).text, f.press(0xff0d).text]) {
    assert.ok(frame.trimEnd().split("\n").length <= 8);
    assert.ok(frame.trimEnd().split("\n").every((line) => [...line].length <= 40));
  }
});
