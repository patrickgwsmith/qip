import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { validateTerminalFrame, validateTUIBinary } from "../npm/qiptui/qiptui.mjs";

const viewerPath = fileURLToPath(new URL("../tui/comply-cases.wasm", import.meta.url));
const oracle = (name) => readFile(fileURLToPath(new URL(`../compliance/${name}`, import.meta.url)));
const viewerBytes = await readFile(viewerPath);
const decoder = new TextDecoder("utf-8", { fatal: true });
const XK_DOWN = 0xff54;
const XK_END = 0xff57;
const FLAG_SHIFT = 1 << 2;

function plain(text) {
  return text.replace(/\x1b\[[0-9;]*m/g, "");
}

class Viewer {
  static async open(input, { columns = 100, lines = 30, seed } = {}) {
    const { instance } = await WebAssembly.instantiate(viewerBytes, {});
    const viewer = new Viewer(instance.exports);
    viewer.exports.uniform_set_columns(columns);
    viewer.exports.uniform_set_lines(lines);
    if (seed !== undefined) viewer.exports.uniform_set_seed(seed);
    new Uint8Array(viewer.exports.memory.buffer, viewer.exports.input_ptr(), input.length).set(input);
    viewer.render(input.length);
    viewer.settle();
    return viewer;
  }

  constructor(exports) {
    this.exports = exports;
    this.now = 0n;
    this.columns = 0;
  }

  update(events = []) {
    this.now += 1n;
    this.exports.begin_update_at(this.now);
    let accepted = false;
    for (const [keysym, flags = 0] of events) accepted = this.exports.key_event(keysym, flags | 1) === 1 || accepted;
    const wake = this.exports.finish_update();
    assert.ok(wake === this.now || wake === this.now + 1n);
    return accepted;
  }

  settle() {
    let updates = 0;
    do {
      this.update();
      updates += 1;
      assert.ok(updates < 10_000, "oracle did not finish");
    } while (this.exports.loading() === 1);
  }

  key(keysym, flags = 0) {
    return this.update([[typeof keysym === "string" ? keysym.codePointAt(0) : keysym, flags]]);
  }

  render(size = 0) {
    const result = BigInt.asUintN(64, this.exports.render(size));
    assert.equal(result >> 63n, 0n);
    const bytes = new Uint8Array(
      this.exports.memory.buffer,
      Number((result >> 32n) & 0x7fff_ffffn),
      Number(result & 0xffff_ffffn),
    );
    validateTerminalFrame(bytes);
    return decoder.decode(bytes);
  }

  text() {
    return plain(this.render());
  }
}

test("comply case viewer passes the qiptui binary checks", () => {
  validateTUIBinary(viewerBytes, "comply-cases");
});

test("lists each case with its input and expected output", async () => {
  const viewer = await Viewer.open(await oracle("html-escape.comply.wasm"), { columns: 80, lines: 30 });
  const text = viewer.text();
  const rows = text.split("\n");
  assert.equal(rows.length, 30);
  for (const row of rows) assert.ok([...row].length <= 80, `${[...row].length}-column row: ${row}`);
  assert.match(rows[0], /^Compliance cases  12 cases  ● done$/);
  assert.match(text, /0002  exact   &\s+&amp;/);
  assert.match(text, /0011  exact   a␀b␊␉c/);
  assert.match(text, /Case 0 · must_render_exactly/);
  assert.equal(viewer.exports.case_total(), 12);

  assert.equal(viewer.key(XK_END), true);
  assert.match(viewer.text(), /Case 11 · must_render_exactly\nInput · 6 B · UTF-8\n  a␀b↵\n  ␉c\nExpected output · 6 B/);
  assert.equal(viewer.key("x"), true);
  assert.match(viewer.text(), /Input · 6 B · UTF-8, hex\n  000000  61 00 62 0a 09 63 .* a·b··c/);
});

test("shows bytes that are not UTF-8 as hex", async () => {
  const viewer = await Viewer.open(await oracle("bmp-b8g8r8a8-icc-to-srgb.comply.wasm"), { columns: 80, lines: 20 });
  const text = viewer.text();
  assert.match(text, /0000  exact   42 4d 3a 00/);
  assert.match(text, /Input · 58 B · not UTF-8, hex\n  000000  42 4d 3a 00 00 00 00 00 00 00 36 00 00 00 28 00  BM:·······6···\(·/);
});

test("shows trap and reject expectations", async () => {
  const viewer = await Viewer.open(await oracle("cve.comply.wasm"));
  viewer.key(XK_END);
  const text = viewer.text();
  assert.match(text, /0755  reject  CVECVE-2026-1234\s+\(must reject\)/);
  assert.match(text, /Case 755 · must_reject/);
  assert.match(text, /Expected the implementation rejects the input\./);
});

test("skips must_render_into cases, which have no fixed expected output", async () => {
  const viewer = await Viewer.open(await oracle("unicode-17-uppercase.comply.wasm"));
  assert.match(viewer.text().split("\n")[0], /77 cases  default seed  20 must_render_into skipped  ● done/);

  const intoOnly = await Viewer.open(await oracle("html5-entities.comply.wasm"));
  const text = intoOnly.text();
  assert.match(text, /0 cases  2,143 must_render_into skipped  ● done/);
  assert.match(text, /Every case uses must_render_into/);
});

test("passes the seed to the oracle and reruns with the next seed", async () => {
  const input = await oracle("currency-format-usd-en-us.comply.wasm");
  const first = await Viewer.open(input, { seed: 7 });
  const again = await Viewer.open(input, { seed: 7 });
  const other = await Viewer.open(input, { seed: 8 });
  assert.match(first.text().split("\n")[0], /seed 7  ● done/);
  first.key(XK_END);
  again.key(XK_END);
  other.key(XK_END);
  const detail = (viewer) => viewer.text().split("\n").slice(-12).join("\n");
  assert.equal(detail(first), detail(again));
  assert.notEqual(detail(first), detail(other));

  assert.equal(first.key("+"), true);
  first.settle();
  first.key(XK_END);
  assert.match(first.text().split("\n")[0], /seed 8  ● done/);
  assert.equal(detail(first), detail(other));
});

test("shows the uniforms that an oracle applies before a case", async () => {
  const viewer = await Viewer.open(await oracle("currency-format-en-us.comply.wasm"), { lines: 40 });
  viewer.key(XK_END);
  assert.match(viewer.text(), /Uniforms: currency=\d+/);
});

test("scrolls long case details", async () => {
  const viewer = await Viewer.open(await oracle("base64-encode.comply.wasm"), { columns: 60, lines: 12 });
  const before = viewer.text();
  assert.match(before, /lines 1–\d+ of \d+/);
  assert.equal(viewer.key(XK_DOWN, FLAG_SHIFT), true);
  assert.match(viewer.text(), /lines 2–/);
  assert.equal(viewer.key("K"), true);
  assert.equal(viewer.text(), before);
});

test("reports a module that is not a Compliance oracle", async () => {
  const viewer = await Viewer.open(new TextEncoder().encode("not wasm"));
  assert.match(viewer.text(), /● failed[\s\S]*Error: Could not load the oracle: InvalidWasm/);

  const component = await readFile(fileURLToPath(new URL("../text/hello.wasm", import.meta.url)));
  const notOracle = await Viewer.open(component);
  assert.match(notOracle.text(), /Error: The module does not export comply\(\) -> i32\./);
});

test("reports a seed that the oracle cannot use", async () => {
  const viewer = await Viewer.open(await oracle("html-escape.comply.wasm"), { seed: 3 });
  assert.match(viewer.text().split("\n")[0], /12 cases  seed 3 ignored: no uniform_set_seed  ● done/);
});
