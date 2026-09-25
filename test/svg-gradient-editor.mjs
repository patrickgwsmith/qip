import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { wasmMustComplyWithComponentContract } from "../npm/qipx/qipx.mjs";

const bytes = await readFile("gui/svg-gradient-editor.wasm");

function editor() {
  const e = new WebAssembly.Instance(new WebAssembly.Module(bytes), {}).exports;
  const read = () => {
    const result = BigInt.asUintN(64, e.render(0));
    const ptr = Number(result >> 32n);
    const size = Number(result & 0xffffffffn);
    return new TextDecoder().decode(new Uint8Array(e.memory.buffer, ptr, size));
  };
  const event = (fn) => {
    e.begin_update_at(BigInt(++event.time));
    fn(e);
    e.finish_update();
    return read();
  };
  event.time = 0;
  return { e, read, event };
}

function gradientStops(svg) {
  return [...svg.matchAll(/<stop offset="\d+\.\d{4}" stop-color="#[0-9A-F]{6}"/g)];
}

test("SVG gradient editor exposes static component metadata", () => {
  assert.doesNotThrow(() => wasmMustComplyWithComponentContract(bytes));
  const { e, read } = editor();
  assert.equal(e.input_utf8_cap(), 0);
  const svg = read();
  assert.match(svg, /<linearGradient id="qip-gradient"/);
  assert.equal(gradientStops(svg).length, 3);
  assert.equal((svg.match(/data-qip-gradient-overlay="true"/g) ?? []).length, 1);
  assert.match(svg, /data-qip-gradient-control="channel-hue" data-qip-gradient-channel="channel-hue"/);
  assert.match(svg, /data-qip-gradient-control="channel-saturation" data-qip-gradient-channel="channel-saturation"/);
  assert.match(svg, /data-qip-gradient-control="stop" data-qip-gradient-stop-index="1"/);
});

test("mode, stops, channels, and clean output respond to events", () => {
  const { e, read, event } = editor();
  read();
  let svg = event((x) => { x.key_event(82, 1); });
  assert.match(svg, /<radialGradient id="qip-gradient"/);
  svg = event((x) => { x.pointer_event(1, 350, 240); x.pointer_event(0, 350, 240); });
  assert.equal(gradientStops(svg).length, 4);
  const inserted = gradientStops(svg)[1][0];
  svg = event((x) => { x.pointer_event(1, 535, 460); x.pointer_event(1, 704, 460); x.pointer_event(0, 704, 460); });
  const recolored = gradientStops(svg)[1][0];
  assert.notEqual(recolored, inserted);
  assert.match(recolored, /stop-color="#[0-9A-F]{6}"/);
  svg = event((x) => { x.key_event(0xffff, 1); });
  assert.equal(gradientStops(svg).length, 3);
  svg = event((x) => { x.key_event(80, 1); });
  assert.doesNotMatch(svg, /data-qip-gradient-control|data-qip-gradient-overlay/);
  assert.match(svg, /<radialGradient/);
  e.uniform_set_editing(1);
  assert.match(read(), /data-qip-gradient-overlay/);
});

test("HSL controls produce a primary color and preserve hue through gray", () => {
  const { read, event } = editor();
  read();
  const set = (y, x) => event((e) => {
    e.pointer_event(1, x, y);
    e.pointer_event(0, x, y);
  });
  set(460, 535); // 0° hue
  set(488, 704); // 100% saturation
  let svg = set(516, 619); // 50% lightness
  assert.match(svg, /<stop offset="0.5000" stop-color="#FF0000"/);
  svg = set(488, 535); // 0% saturation
  assert.match(svg, /<stop offset="0.5000" stop-color="#808080"/);
  set(460, 591); // Approximately 120° hue while gray
  svg = set(488, 704);
  assert.match(svg, /<stop offset="0.5000" stop-color="#04FF00"/);
});

test("hover, release, and unchanged drags do not request a frame", () => {
  const { e, read } = editor();
  const initial = read();
  e.begin_update_at(1n);
  assert.equal(e.pointer_event(0, 300, 200), 0);
  assert.equal(e.pointer_event(0, 310, 205), 0);
  assert.equal(e.pointer_event(1, 155, 260), 1);
  assert.equal(e.pointer_event(1, 155, 260), 0);
  assert.equal(e.pointer_event(1, 175, 270), 1);
  assert.equal(e.pointer_event(1, 175, 270), 0);
  assert.equal(e.pointer_event(0, 175, 270), 0);
  assert.equal(e.pointer_event(0, 400, 200), 0);
  e.finish_update();
  assert.notEqual(read(), initial);
});
