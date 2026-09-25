import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { renderSize, renderedOutputPointer } from "./lib/content-component-host.mjs";

const wasm = await readFile("tui/iana-service-port-finder.wasm");
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

test("service finder exposes the named IANA registrations", () => {
  const f = finder();
  assert.equal(f.exports.input_ptr, undefined);
  assert.match(f.screen(), /SERVICE PORT FINDER  IANA 2026-09-11  11723 \/ 11723/);
  assert.match(f.screen(), /> 1\/tcp\s+tcpmux/);
});

test("numeric port search is exact and can combine with protocol", () => {
  const f = finder();
  f.screen();
  assert.match(f.type("80"), /> 80\/tcp\s+http/);
  assert.doesNotMatch(f.screen(), /8080\//);
  assert.match(f.type(" udp"), /80\/udp\s+http/);
  assert.doesNotMatch(f.screen(), /80\/tcp/);
  f.press(0xff1b);
  assert.match(f.type("6003 x11"), /6000-6063\/tcp\s+x11/);
});

test("details preserve long assignment notes with scrolling", () => {
  const f = finder();
  f.exports.uniform_set_columns(48);
  f.exports.uniform_set_lines(10);
  f.screen();
  f.type("www-http 80 tcp");
  const first = f.press(0xff0d).text;
  assert.match(first, /www-http  80\/tcp/);
  assert.match(first, /duplicate of the "http" service/);
  const next = f.press(0xff56).text;
  assert.notEqual(first, next);
  assert.ok(next.trimEnd().split("\n").length <= 10);
  assert.ok(next.trimEnd().split("\n").every((line) => [...line].length <= 48));
  assert.equal(f.press(0xff55).accepted, 1);
  assert.match(f.press(0xff1b).text, /Find: www-http 80 tcp_/);
});

test("no matches cannot open details", () => {
  const f = finder();
  f.screen();
  assert.match(f.type("not-a-real-service"), /No matches/);
  assert.equal(f.press(0xff0d).accepted, 0);
});
