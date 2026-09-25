import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { renderSize, renderedOutputPointer } from "./lib/content-component-host.mjs";

const wasm = await readFile("tui/time-zone-converter.wasm");
const decoder = new TextDecoder("utf-8", { fatal: true });

function converter() {
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
  function setUTC(value) {
    press(0xff09);
    type(value);
    return press(0xff0d).text;
  }
  return { exports, screen, press, type, setUTC };
}

test("converter exposes an inputless TUI and 418 IANA locations", () => {
  const { exports, screen } = converter();
  assert.equal(exports.input_ptr, undefined);
  assert.equal(exports.input_bytes_cap, undefined);
  assert.equal(exports.output_utf8_cap(), 16 * 1024);
  assert.match(screen(), /tzdb 2026d/);
  assert.match(screen(), /UTC: 2026-09-24 12:00/);
  assert.match(screen(), /418 \/ 418/);
  assert.match(screen(), /Australia\/Melbourne\s+2026-09-24 22:00\s+UTC\+10:00/);
  assert.match(screen(), /Asia\/Kolkata\s+2026-09-24 17:30\s+UTC\+05:30/);
  assert.match(screen(), /Pacific\/Auckland\s+2026-09-25 00:00\s+UTC\+12:00/);
});

test("typing filters zones while arrows move the UTC instant", () => {
  const f = converter();
  f.screen();
  assert.match(f.type("chatham"), /Pacific\/Chatham\s+2026-09-25 00:45\s+UTC\+12:45/);
  assert.match(f.press(0xff53).text, /UTC: 2026-09-24 13:00/);
  assert.match(f.screen(), /Pacific\/Chatham\s+2026-09-25 01:45/);
  assert.match(f.press(0xff52).text, /UTC: 2026-09-25 13:00/);
  assert.match(f.press(0xff1b).text, /418 \/ 418/);
  assert.equal(f.press(0xff55).accepted, 0);
  assert.equal(f.press(0xff56).accepted, 1);
});

test("New York skips and repeats local hours at DST transitions", () => {
  const f = converter();
  f.screen();
  f.type("new_york");
  assert.match(f.setUTC("2026-03-08 06:59"), /America\/New_York\s+2026-03-08 01:59\s+UTC-05:00/);
  assert.match(f.press(0xff53).text, /America\/New_York\s+2026-03-08 03:59\s+UTC-04:00/);
  assert.match(f.setUTC("2026-11-01 05:30"), /America\/New_York\s+2026-11-01 01:30\s+UTC-04:00/);
  assert.match(f.press(0xff53).text, /America\/New_York\s+2026-11-01 01:30\s+UTC-05:00/);
});

test("Melbourne advances across midnight at the spring DST boundary", () => {
  const f = converter();
  f.screen();
  f.type("melbourne");
  assert.match(f.setUTC("2026-10-03 15:59"), /Australia\/Melbourne\s+2026-10-04 01:59\s+UTC\+10:00/);
  assert.match(f.press(0xff53).text, /Australia\/Melbourne\s+2026-10-04 03:59\s+UTC\+11:00/);
});

test("Inuvik follows the pinned 2026d permanent UTC-06 rule", () => {
  const f = converter();
  f.screen();
  f.type("inuvik");
  assert.match(f.setUTC("2027-01-15 12:00"), /America\/Inuvik\s+2027-01-15 06:00\s+UTC-06:00/);
  assert.match(f.setUTC("2027-07-15 12:00"), /America\/Inuvik\s+2027-07-15 06:00\s+UTC-06:00/);
});

test("date entry validates leap days and the table's supported range", () => {
  const f = converter();
  f.screen();
  assert.match(f.setUTC("2026-02-29 12:00"), /Invalid UTC time/);
  assert.match(f.press(0xff1b).text, /UTC: 2026-09-24 12:00/);
  assert.match(f.setUTC("2028-02-29 12:00"), /UTC: 2028-02-29 12:00/);
  assert.match(f.setUTC("2038-01-01 00:00"), /Invalid UTC time/);
  f.press(0xff1b);
  assert.match(f.screen(), /UTC: 2028-02-29 12:00/);
});

test("narrow frames and lifecycle calls stay within the TUI contract", () => {
  const f = converter();
  assert.throws(() => f.exports.begin_update_at(1n), WebAssembly.RuntimeError);
  f.exports.uniform_set_columns(40);
  f.exports.uniform_set_lines(8);
  const frame = f.screen();
  assert.ok(frame.trimEnd().split("\n").length <= 8);
  assert.ok(frame.trimEnd().split("\n").every((line) => line.length <= 40));
  assert.throws(() => f.exports.finish_update(), WebAssembly.RuntimeError);
  f.exports.begin_update_at(1n);
  assert.throws(() => f.exports.render(0), WebAssembly.RuntimeError);
});
