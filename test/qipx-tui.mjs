import assert from "node:assert/strict";
import { emitKeypressEvents } from "node:readline";
import { PassThrough } from "node:stream";
import test from "node:test";

import {
  TerminalKeyDecoder,
  decodeTerminalBytes,
  validateTerminalFrame,
} from "../npm/qipx/qipx-tui.mjs";

const SHIFT = 1 << 2;
const CONTROL = 1 << 3;
const ALT = 1 << 4;

const cases = [
  ["lowercase", [0x61], 0x61, 0],
  ["uppercase", [0x41], 0x41, SHIFT],
  ["question mark", [0x3f], 0x3f, 0],
  ["tab", [0x09], 0xff09, 0],
  ["backspace control-H", [0x08], 0xff08, 0],
  ["backspace DEL", [0x7f], 0xff08, 0],
  ["return CR", [0x0d], 0xff0d, 0],
  ["left", [0x1b, 0x5b, 0x44], 0xff51, 0],
  ["control-left", [0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x44], 0xff51, CONTROL],
  ["F5", [0x1b, 0x5b, 0x31, 0x35, 0x7e], 0xffc2, 0],
  ["F10", [0x1b, 0x5b, 0x32, 0x31, 0x7e], 0xffc7, 0],
  ["Shift-F11", [0x1b, 0x5b, 0x32, 0x33, 0x3b, 0x32, 0x7e], 0xffc8, SHIFT],
  ["Alt-[", [0x1b, 0x5b], 0x5b, ALT],
];

test("terminal decoder maps legacy terminal input to X11 keysyms", () => {
  for (const [label, bytes, keysym, flags] of cases) {
    assert.deepEqual(decodeTerminalBytes(Uint8Array.from(bytes)), [{ keysym, flags }], label);
  }
});

test("terminal decoder retains split escape and UTF-8 sequences", () => {
  const events = [];
  const decoder = new TerminalKeyDecoder((event) => events.push(event));
  assert.equal(decoder.push(Uint8Array.from([0x1b, 0x5b])), true);
  assert.equal(decoder.push(Uint8Array.from([0x44, 0xc3])), true);
  assert.deepEqual(events, [{ keysym: 0xff51, flags: 0 }]);
  assert.equal(decoder.push(Uint8Array.from([0xa9])), false);
  assert.deepEqual(events, [
    { keysym: 0xff51, flags: 0 },
    { keysym: 0xe9, flags: 0 },
  ]);
});

test("terminal frame validator permits text, UTF-8, LF, and the SGR allowlist", () => {
  const safe = new TextEncoder().encode("plain é\n\x1b[1;96mbold cyan\x1b[0m");
  assert.equal(validateTerminalFrame(safe), safe);
});

test("terminal frame validator rejects cursor, OSC, C0, C1, and extended colors", () => {
  for (const unsafe of [
    "\x1b[Hcursor",
    "\x1b]52;c;YQ==\x07",
    "tab\there",
    "back\bspace",
    "return\r",
    "\u0085",
    "\x1b[38;5;196mindexed",
    "\x1b[38;2;1;2;3mrgb",
  ]) {
    assert.throws(() => validateTerminalFrame(new TextEncoder().encode(unsafe)), /terminal output/, JSON.stringify(unsafe));
  }
});

async function readlineOracle(input) {
  const stream = new PassThrough();
  const events = [];
  emitKeypressEvents(stream);
  stream.on("keypress", (_text, key) => events.push(key));
  stream.end(Buffer.from(input));
  await new Promise((resolve) => setImmediate(resolve));
  return events;
}

test("decoder agrees with readline keypress parsing where readline is unambiguous", async () => {
  const oracleCases = [
    [[0x61], "a", false, false, false],
    [[0x41], "a", false, false, true],
    [[0x09], "tab", false, false, false],
    [[0x08], "backspace", false, false, false],
    [[0x7f], "backspace", false, false, false],
    [[0x1b, 0x5b, 0x44], "left", false, false, false],
    [[0x1b, 0x5b, 0x32, 0x33, 0x3b, 0x32, 0x7e], "f11", false, false, true],
  ];
  for (const [bytes, name, ctrl, meta, shift] of oracleCases) {
    const oracle = await readlineOracle(bytes);
    assert.equal(oracle.length, 1);
    assert.deepEqual(
      { name: oracle[0].name, ctrl: oracle[0].ctrl, meta: oracle[0].meta, shift: oracle[0].shift },
      { name, ctrl, meta, shift },
    );
  }

  // readline waits indefinitely for ESC [, while QIP resolves it as Alt-[
  // after the decoder's short ambiguity timeout.
  assert.deepEqual(await readlineOracle([0x1b, 0x5b]), []);
  assert.deepEqual(decodeTerminalBytes(Uint8Array.from([0x1b, 0x5b])), [{ keysym: 0x5b, flags: ALT }]);
});
