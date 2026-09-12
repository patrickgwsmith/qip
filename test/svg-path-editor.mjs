import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const moduleBytes = await readFile("components/interactive/svg-path-editor.wasm");

function instance() {
  return new WebAssembly.Instance(new WebAssembly.Module(moduleBytes), {}).exports;
}

function type(exports, prefix) {
  const ptr = exports[`${prefix}_content_type_ptr`]();
  const size = exports[`${prefix}_content_type_size`]();
  return new TextDecoder("utf-8", { fatal: true }).decode(
    new Uint8Array(exports.memory.buffer, ptr, size),
  );
}

function decode(result) {
  const bits = BigInt.asUintN(64, result);
  return {
    failed: Boolean(bits >> 63n),
    ptr: Number((bits >> 32n) & 0x7fff_ffffn),
    size: Number(bits & 0xffff_ffffn),
  };
}

function initialize(exports, source = "") {
  const bytes = new TextEncoder().encode(source);
  assert.ok(bytes.length <= exports.input_utf8_cap());
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), bytes.length).set(bytes);
  return decode(exports.render(bytes.length));
}

function output(exports, rendered) {
  return new TextDecoder("utf-8", { fatal: true }).decode(
    new Uint8Array(exports.memory.buffer, rendered.ptr, rendered.size),
  );
}

test("SVG editor exposes exact UTF-8 Content metadata", () => {
  const exports = instance();
  assert.equal(type(exports, "input"), "image/svg+xml");
  assert.equal(type(exports, "output"), "image/svg+xml");
  assert.equal(exports.input_utf8_cap(), 1024 * 1024);
  assert.equal(exports.output_utf8_cap(), 4 * 1024 * 1024);
  assert.equal(exports.input_bytes_cap, undefined);
  assert.equal(exports.output_bytes_cap, undefined);
  assert.equal(exports.failure_modes_per_input_offset(), 3);
  assert.ok(exports.memory.buffer.byteLength <= 8 * 1024 * 1024);
});

test("empty input creates a valid stable scene with one overlay", () => {
  const exports = instance();
  const first = initialize(exports);
  assert.equal(first.failed, false);
  const svg = output(exports, first);
  assert.match(svg, /^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg" width="800" height="600" viewBox="0 0 800 600">/);
  assert.equal(svg.match(/data-qip-editor-overlay="true"/g)?.length, 1);
  const repeated = decode(exports.render(0));
  assert.equal(output(exports, repeated), svg);
});

test("malformed initialization rejects recoverably and can be retried", () => {
  const exports = instance();
  assert.equal(initialize(exports, "<svg><g></svg>").failed, true);
  const accepted = initialize(exports, "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>");
  assert.equal(accepted.failed, false);
});

test("source spans and unsupported paths survive while old overlays are removed", () => {
  const exports = instance();
  const source = '<svg xmlns="http://www.w3.org/2000/svg" data-owner="app"><!-- exact --><style>.x{fill:red}</style><path id="arc" d="M 1 2 A 4 4 0 0 0 9 9"/><g data-qip-editor-overlay="true"><path d="M0 0L1 1"/></g></svg>';
  const rendered = initialize(exports, source);
  const svg = output(exports, rendered);
  assert.match(svg, /data-owner="app"/);
  assert.match(svg, /<!-- exact --><style>\.x\{fill:red\}<\/style><path id="arc" d="M 1 2 A 4 4 0 0 0 9 9"\/>/);
  assert.equal(svg.match(/data-qip-editor-overlay="true"/g)?.length, 1);
});

test("events retain state without publishing until render", () => {
  const exports = instance();
  const initial = initialize(exports);
  const before = output(exports, initial);
  exports.begin_update_at(1n);
  assert.equal(exports.key_event("P".codePointAt(0), 1), 1);
  assert.equal(exports.pointer_event(1, 200, 200), 1);
  assert.equal(exports.pointer_event(0, 200, 200), 1);
  assert.equal(exports.pointer_event(1, 350, 260), 1);
  assert.equal(exports.pointer_event(0, 350, 260), 1);
  assert.equal(exports.key_event(0xff0d, 1), 1);
  assert.equal(exports.finish_update(), 1n);
  assert.equal(output(exports, initial), before);
  const after = output(exports, decode(exports.render(0)));
  assert.match(after, /<path d="M200 200 L350 260" fill="none" stroke="#111827"/);
});

test("pen drags publish the active anchor and mirrored handles in the overlay", () => {
  const exports = instance();
  initialize(exports);
  exports.begin_update_at(1n);
  exports.key_event("P".codePointAt(0), 1);
  exports.pointer_event(1, 200, 200);
  exports.pointer_event(1, 240, 220);
  exports.pointer_event(0, 240, 220);
  exports.finish_update();
  const svg = output(exports, decode(exports.render(0)));
  assert.match(svg, /data-qip-editor-mode="pen"/);
  assert.match(svg, /<path class="qip-line" d="M200\.00 200\.00L160\.00 180\.00"/);
  assert.match(svg, /<path class="qip-line" d="M200\.00 200\.00L240\.00 220\.00"/);
  assert.equal((svg.match(/<circle class="qip-hit"/g) || []).length, 2);
  assert.equal((svg.match(/<circle class="qip-hit-selected"/g) || []).length, 1);
});

test("Space moves the current pen point without collapsing its handles", () => {
  const exports = instance();
  initialize(exports);
  exports.begin_update_at(1n);
  exports.key_event("P".codePointAt(0), 1);
  exports.pointer_event(1, 50, 100);
  exports.pointer_event(0, 50, 100);
  exports.pointer_event(1, 100, 100);
  exports.pointer_event(1, 130, 100);
  exports.key_event(0x20, 1);
  exports.pointer_event(1, 150, 100);
  exports.key_event(0x20, 0);
  exports.pointer_event(1, 170, 100);
  exports.pointer_event(0, 170, 100);
  exports.finish_update();
  const svg = output(exports, decode(exports.render(0)));
  assert.match(svg, /d="M50 100 C50 100 70 100 120 100"/);
  assert.match(svg, /M120\.00 100\.00L70\.00 100\.00/);
  assert.match(svg, /M120\.00 100\.00L170\.00 100\.00/);
});

test("Shift-click selects multiple anchors for a shared nudge", () => {
  const exports = instance();
  initialize(exports, '<svg xmlns="http://www.w3.org/2000/svg"><path d="M100 100 L200 100 L300 100"/></svg>');
  exports.begin_update_at(1n);
  exports.pointer_event(1, 100, 100);
  exports.pointer_event(0, 100, 100);
  exports.key_event(0xffe1, 5);
  exports.pointer_event(1, 200, 100);
  exports.pointer_event(0, 200, 100);
  exports.key_event(0xffe1, 0);
  exports.key_event(0xff53, 1);
  exports.finish_update();
  const svg = output(exports, decode(exports.render(0)));
  assert.match(svg, /d="M101 100 L201 100 L300 100"/);
});

test("dragging one selected anchor moves the central multi-anchor selection", () => {
  const exports = instance();
  initialize(exports, '<svg xmlns="http://www.w3.org/2000/svg"><path d="M100 100 L200 100 L300 100"/></svg>');
  exports.begin_update_at(1n);
  exports.pointer_event(1, 100, 100);
  exports.pointer_event(0, 100, 100);
  exports.key_event(0xffe1, 5);
  exports.pointer_event(1, 200, 100);
  exports.pointer_event(0, 200, 100);
  exports.key_event(0xffe1, 0);
  exports.pointer_event(1, 200, 100);
  exports.pointer_event(1, 210, 110);
  exports.pointer_event(0, 210, 110);
  exports.finish_update();
  const svg = output(exports, decode(exports.render(0)));
  assert.match(svg, /data-qip-editor-mode="selection"/);
  assert.match(svg, /d="M110 110 L210 110 L300 100"/);
  assert.equal((svg.match(/<circle class="qip-hit-selected"/g) || []).length, 2);
});

test("a pen-dragged close is cubic and its incoming handle remains editable", () => {
  const exports = instance();
  initialize(exports);
  exports.begin_update_at(1n);
  exports.key_event("P".codePointAt(0), 1);
  for (const [x, y] of [[100, 100], [200, 100], [200, 200]]) {
    exports.pointer_event(1, x, y);
    exports.pointer_event(0, x, y);
  }
  exports.pointer_event(1, 100, 100);
  exports.pointer_event(1, 80, 100);
  exports.pointer_event(0, 80, 100);
  exports.finish_update();
  let svg = output(exports, decode(exports.render(0)));
  assert.match(svg, /d="M100 100 L200 100 L200 200 C200 200 120 100 100 100 Z"/);
  assert.match(svg, /data-qip-editor-mode="selection"/);
  assert.match(svg, /data-qip-edited-path="0"/);

  exports.begin_update_at(2n);
  exports.pointer_event(1, 120, 100);
  exports.pointer_event(1, 140, 100);
  exports.pointer_event(0, 140, 100);
  exports.finish_update();
  svg = output(exports, decode(exports.render(0)));
  assert.match(svg, /d="M100 100 L200 100 L200 200 C200 200 140 100 100 100 Z"/);
});

test("nested transforms use inverse document coordinates and singular transforms stay uneditable", () => {
  const exports = instance();
  const source = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 300"><g transform="translate(50 0) scale(2)"><path id="editable" d="M10 10 L20 10"/><path id="singular" transform="scale(0)" d="M30 30 L40 30"/></g></svg>';
  initialize(exports, source);
  exports.begin_update_at(1n);
  exports.pointer_event(1, 140, 40);
  exports.pointer_event(0, 140, 40);
  exports.key_event(0xff53, 1);
  exports.finish_update();
  const svg = output(exports, decode(exports.render(0)));
  assert.match(svg, /transform="translate\(50 0\) scale\(2\)"/);
  assert.match(svg, /id="editable" d="M10\.25 10 L20 10"/);
  assert.match(svg, /id="singular" transform="scale\(0\)" d="M30 30 L40 30"/);
});

test("lifecycle misuse traps", () => {
  const exports = instance();
  assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
  initialize(exports);
  assert.throws(() => exports.finish_update(), WebAssembly.RuntimeError);
  exports.begin_update_at(1n);
  assert.throws(() => exports.render(0), WebAssembly.RuntimeError);
  exports.finish_update();
  assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
  assert.throws(() => exports.render(1), WebAssembly.RuntimeError);
});
