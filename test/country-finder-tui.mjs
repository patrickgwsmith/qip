import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { renderSize, renderedOutputPointer } from "./lib/content-component-host.mjs";

const wasm = await readFile("tui/country-finder.wasm");
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

test("country finder exposes the inputless TUI contract and all 249 rows", () => {
  const { exports, screen } = finder();
  assert.equal(exports.input_ptr, undefined);
  assert.equal(exports.input_bytes_cap, undefined);
  assert.equal(exports.output_utf8_cap(), 16 * 1024);
  assert.equal(exports.uniform_set_columns(80), 80);
  assert.equal(exports.uniform_set_lines(24), 24);
  assert.match(screen(), /COUNTRY FINDER  249 \/ 249/);
  assert.match(screen(), /> AF  Afghanistan/);
});

test("typing filters names, ISO codes, currencies, and calling prefixes", () => {
  const finderByName = finder();
  finderByName.screen();
  assert.match(finderByName.type("australia"), /Australia\s+AUD\s+\+61/);
  assert.match(finderByName.screen(), /COUNTRY FINDER  1 \/ 249/);
  assert.match(finderByName.press(0xff08).text, /Find: australi_/);
  assert.match(finderByName.press(0xff1b).text, /COUNTRY FINDER  249 \/ 249/);

  const finderByCode = finder();
  finderByCode.screen();
  assert.match(finderByCode.type("usa"), /United States/);

  const finderByCurrency = finder();
  finderByCurrency.screen();
  assert.match(finderByCurrency.type("jpy"), /Japan\s+JPY\s+\+81/);

  const finderByDial = finder();
  finderByDial.screen();
  assert.match(finderByDial.type("+1-684"), /American Samoa/);

  const finderByAsciiAlias = finder();
  finderByAsciiAlias.screen();
  assert.match(finderByAsciiAlias.type("cote"), /Côte d’Ivoire/);

  const finderByUnicodeName = finder();
  finderByUnicodeName.screen();
  assert.match(finderByUnicodeName.type("Türkiye"), /Türkiye\s+TRY\s+\+90/);
  assert.match(finderByUnicodeName.press(0xff08).text, /Find: Türkiy_/);
});

test("selection, paging, and detail view preserve the filter", () => {
  const f = finder();
  f.screen();
  f.type("australia");
  assert.match(f.press(0xff0d).text, /COUNTRY DETAILS/);
  assert.match(f.screen(), /Australia  \(AU \/ AUS\)/);
  assert.match(f.screen(), /Calling prefix\s+\+61/);
  assert.match(f.press(0xff1b).text, /Find: australia_/);

  f.press(0xff1b);
  assert.match(f.press(0xff54).text, /> AX  Åland Islands/);
  assert.match(f.press(0xff56).text, />/);
  assert.match(f.press(0xff50).text, /> AF  Afghanistan/);
  assert.equal(f.press(0xff52).accepted, 0);
});

test("no-match, narrow, and short screens stay bounded", () => {
  const f = finder();
  f.exports.uniform_set_columns(40);
  f.exports.uniform_set_lines(8);
  f.screen();
  const noMatch = f.type("zzzzzz");
  assert.match(noMatch, /No matches/);
  assert.equal(f.press(0xff0d).accepted, 0);
  f.press(0xff1b);
  const list = f.screen();
  assert.ok(list.trimEnd().split("\n").length <= 8);
  assert.ok(list.trimEnd().split("\n").every((line) => [...line].length <= 40));
  const detail = f.press(0xff0d).text;
  assert.ok(detail.trimEnd().split("\n").length <= 8);
  assert.ok(detail.trimEnd().split("\n").every((line) => [...line].length <= 40));
});

test("lifecycle rejects calls in the wrong phase", () => {
  const { exports, screen } = finder();
  assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
  screen();
  assert.throws(() => exports.finish_update(), WebAssembly.RuntimeError);
  exports.begin_update_at(1n);
  assert.throws(() => exports.render(0), WebAssembly.RuntimeError);
});
