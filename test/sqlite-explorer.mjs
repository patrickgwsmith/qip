import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";
import { decodeRenderResult } from "./lib/content-component-host.mjs";

const wasm = new WebAssembly.Module(readFileSync("gui/sqlite-explorer.wasm"));
const fixture = (name) => readFileSync(`application/vnd.sqlite3/fixtures/${name}.sqlite`);

const KEY_DOWN = 1;
const XK_TAB = 0xff09;
const XK_DOWN = 0xff54;
const XK_RIGHT = 0xff53;
const XK_PAGE_DOWN = 0xff56;
const SCALE = 2;

function instantiate() {
  return new WebAssembly.Instance(wasm).exports;
}

function bytes(exports, pointer, size) {
  return new Uint8Array(exports.memory.buffer, pointer, size);
}

function contentType(exports, prefix) {
  return new TextDecoder().decode(bytes(
    exports,
    exports[`${prefix}_content_type_ptr`](),
    exports[`${prefix}_content_type_size`](),
  ));
}

function load(exports, data) {
  bytes(exports, exports.input_ptr(), data.length).set(data);
  return decodeRenderResult(exports.render(data.length));
}

function frameHash(exports) {
  const result = decodeRenderResult(exports.render(0));
  assert.equal(result.failed, false);
  return createHash("sha256").update(bytes(exports, result.outputPointer, result.value)).digest("hex");
}

// Runs one update containing `send`, and returns what the event returned.
let clock = 0n;
function update(exports, send) {
  clock += 1n;
  exports.begin_update_at(clock);
  const accepted = send();
  assert.equal(exports.finish_update(), clock);
  return accepted;
}

const key = (exports, keysym) => update(exports, () => exports.key_event(keysym, KEY_DOWN));
const click = (exports, x, y) => update(exports, () => {
  const accepted = exports.pointer_event(1, x * SCALE, y * SCALE);
  exports.pointer_event(0, x * SCALE, y * SCALE);
  return accepted;
});

test("SQLite Explorer declares SQLite input and a 1280x800 KTX2 frame", () => {
  const exports = instantiate();
  assert.equal(contentType(exports, "input"), "application/vnd.sqlite3");
  assert.equal(contentType(exports, "output").split(";")[0], "image/ktx2");

  const result = load(exports, fixture("titanic"));
  assert.equal(result.failed, false);
  assert.equal(result.value, exports.output_bytes_cap());
  const header = new DataView(exports.memory.buffer, result.outputPointer, 32);
  assert.equal(header.getUint32(20, true), 1280);
  assert.equal(header.getUint32(24, true), 800);
});

test("SQLite Explorer rejects unreadable files at the offending header field and recovers", () => {
  const exports = instantiate();
  assert.deepEqual(
    [load(exports, Buffer.from("not a database")), load(exports, fixture("wal-mode")), load(exports, fixture("utf16"))]
      .map(({ failed, value }) => [failed, value]),
    [[true, 0], [true, 18], [true, 56]],
  );
  assert.equal(load(exports, fixture("countries")).failed, false);
});

test("SQLite Explorer shows an empty state without input and ignores keys", () => {
  const exports = instantiate();
  assert.equal(load(exports, new Uint8Array()).failed, false);
  assert.equal(key(exports, XK_DOWN), 0);
});

test("SQLite Explorer navigates tables, rows, and the schema view", () => {
  const exports = instantiate();
  assert.equal(load(exports, fixture("titanic")).failed, false);
  const first = frameHash(exports);

  // The sidebar has focus first: Down selects the second table.
  assert.equal(key(exports, XK_DOWN), 1);
  const second = frameHash(exports);
  assert.notEqual(second, first);

  // Clicking the first table in the sidebar goes back to it.
  assert.equal(click(exports, 60, 66), 1);
  assert.equal(frameHash(exports), first);
  assert.equal(click(exports, 60, 66), 0, "clicking the selected table changes nothing");

  // Tab moves into the grid, where keys move the selected cell.
  assert.equal(key(exports, XK_TAB), 1);
  const gridFocused = frameHash(exports);
  assert.equal(key(exports, XK_RIGHT), 1);
  assert.equal(key(exports, XK_PAGE_DOWN), 1);
  assert.notEqual(frameHash(exports), gridFocused);

  assert.equal(key(exports, "s".codePointAt(0)), 1);
  const schema = frameHash(exports);
  assert.equal(key(exports, "s".codePointAt(0)), 1);
  assert.notEqual(frameHash(exports), schema);

  // `]` steps through tables from anywhere and stops at the last one.
  let steps = 0;
  while (key(exports, "]".codePointAt(0)) === 1) steps += 1;
  assert.equal(steps, 7);
});

test("SQLite Explorer lists WITHOUT ROWID tables without reading their rows", () => {
  const exports = instantiate();
  assert.equal(load(exports, fixture("kv-without-rowid")).failed, false);
  assert.equal(key(exports, XK_TAB), 1);
  assert.equal(key(exports, XK_DOWN), 0);
});

test("SQLite Explorer traps events outside an update", () => {
  const exports = instantiate();
  load(exports, fixture("countries"));
  assert.throws(() => exports.key_event(XK_DOWN, KEY_DOWN), WebAssembly.RuntimeError);
  assert.throws(() => exports.pointer_event(1, 0, 0), WebAssembly.RuntimeError);
});
