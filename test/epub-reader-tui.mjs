import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { validateTerminalFrame } from "../npm/qiptui/qiptui.mjs";

const module = await WebAssembly.compile(await readFile("tui/epub-reader.wasm"));
const book = await readFile("test/fixtures/tui/epub-reader.epub");
const plain = (frame) => frame.replace(/\x1b\[[0-9;]*m/g, "");

function reader(bytes = book) {
  const exports = new WebAssembly.Instance(module).exports;
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), bytes.length).set(bytes);
  let time = 0;
  const frame = (size = 0) => {
    const packed = exports.render(size);
    const length = Number(packed & 0xffffffffn);
    const pointer = Number((packed >> 32n) & 0x7fffffffn);
    const data = validateTerminalFrame(new Uint8Array(exports.memory.buffer, pointer, length));
    return new TextDecoder().decode(data);
  };
  const key = (keysym) => {
    exports.begin_update_at(BigInt(++time));
    exports.key_event(keysym, 1);
    exports.key_event(keysym, 0);
    exports.finish_update();
    return frame();
  };
  return { exports, frame, key };
}

test("EPUB reader follows the spine, scrolls, and reflows with terminal size", () => {
  const tui = reader();
  tui.exports.uniform_set_columns(80);
  tui.exports.uniform_set_lines(8);
  const wide = tui.frame(book.length);
  assert.match(wide, /EPUB  Small Book/);
  assert.match(wide, /Chapter One/);
  assert.match(wide, /Hello & world/);
  assert.match(wide, /wrap\.\n \n Page 2:/);
  assert.doesNotMatch(wide, /HIDDEN|Ignore me|Chapter Two/);
  assert.equal(wide.split("\n").length, 8);

  tui.exports.uniform_set_columns(30);
  const narrow = tui.frame();
  assert.match(narrow, /Hello & world\./);
  assert.doesNotMatch(narrow, /longer line with words and more words/);

  const next = tui.key(0xff53);
  assert.match(next, /Chapter Two/);
  assert.match(next, /Second chapter text/);
  assert.match(next, /2\/2/);
  const previous = tui.key(0xff51);
  assert.match(previous, /Chapter One/);
  assert.match(previous, /1\/2/);
  assert.match(tui.key(0xff57), /quoted passage/);
  assert.match(tui.key(0xff50), /Chapter One/);
});

test("EPUB reader spaces paragraphs and centers declared text", () => {
  const tui = reader();
  tui.exports.uniform_set_columns(50);
  tui.exports.uniform_set_lines(20);
  tui.frame(book.length);
  const screen = plain(tui.key(0xff53)).split("\n");
  const find = (value) => screen.findIndex((line) => line.includes(value));
  const indent = (value) => /^ */.exec(screen[find(value)])[0].length;

  assert.equal(find("CSS centered words") - find("Second chapter text."), 2);
  assert.ok(indent("Chapter Two") > indent("Second chapter text.") + 5);
  assert.ok(indent("CSS centered words") > indent("Second chapter text.") + 5);
  assert.ok(indent("Inline centered words") > indent("Second chapter text.") + 5);
  assert.ok(indent("Legacy centered") > indent("Second chapter text.") + 5);
  assert.ok(indent("Embedded centered") > indent("Second chapter text.") + 5);
  assert.equal(indent("Left override"), indent("Second chapter text."));

  tui.exports.uniform_set_columns(30);
  const narrow = plain(tui.frame()).split("\n");
  const centeredLine = narrow.find((line) => line.includes("Chapter Two"));
  assert.ok(/^ {4,}Chapter Two/.test(centeredLine));
});

test("EPUB reader bolds headings and strong text without changing wrapping", () => {
  const tui = reader();
  tui.exports.uniform_set_columns(44);
  tui.exports.uniform_set_lines(30);
  tui.frame(book.length);
  const frame = tui.key(0xff53);
  assert.match(frame, /\x1b\[1mChapter Two\x1b\[22m\n/);
  assert.match(frame, /\x1b\[1mstrong text\x1b\[22m/);
  assert.match(frame, /\x1b\[1mbold text\x1b\[22m/);
  assert.match(frame, /\x1b\[1mLarge CSS title\x1b\[22m/);
  assert.match(frame, /\x1b\[1mCSS bold \x1b\[22mplain inner\x1b\[1m bold again\x1b\[22m/);
  assert.match(frame, /emphasis/);
  assert.doesNotMatch(frame, /\x1b\[1memphasis/);
  assert.match(plain(frame), /\n +│ A quoted passage/);
  assert.match(plain(frame), /\n +│ terminal width/);
});

test("invalid EPUB input shows a safe error frame", () => {
  const tui = reader(Buffer.from("not an epub"));
  assert.match(tui.frame(11), /Could not read this EPUB/);
});
