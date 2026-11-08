import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { readFile } from "node:fs/promises";
import { inflateSync } from "node:zlib";
import test from "node:test";

import { applyUniforms, parseUniforms, readUniformParamTypes } from "../npm/qiptui/qiptui.mjs";
import {
  kittyImage, layoutImage, parseArgs, parseKTX2RGBA8, pointerState, runGUI,
  TerminalInputSplitter, requireKTX2Output, validateGUIBinary,
} from "../npm/qipgui/qipgui.mjs";

test("the splitter separates mouse reports and terminal replies from keys", () => {
  const splitter = new TerminalInputSplitter();
  const first = splitter.push(Buffer.from("a\x1b[<0;120;45Mb\x1b[4;800;1200t\x1b_Gi=31;OK\x1b\\\x1b[?62;4c\x1b[<0;12"));
  assert.equal(first.keys.toString(), "ab");
  assert.deepEqual(first.reports, [
    { type: "mouse", button: 0, x: 120, y: 45, release: false },
    { type: "window", width: 1200, height: 800 },
    { type: "graphics", ok: true },
    { type: "da1" },
  ]);
  const second = splitter.push(Buffer.from(";3m\x1b[A\x1b"));
  assert.deepEqual(second.reports, [{ type: "mouse", button: 0, x: 12, y: 3, release: true }]);
  assert.equal(second.keys.toString("latin1"), "\x1b[A\x1b");
});

test("SGR buttons map to QIP button masks", () => {
  assert.equal(pointerState(0, { button: 0, release: false }), 1);
  assert.equal(pointerState(1, { button: 2, release: false }), 5);
  assert.equal(pointerState(5, { button: 32 + 0, release: false }), 5);
  assert.equal(pointerState(5, { button: 0, release: true }), 4);
  assert.equal(pointerState(0, { button: 64, release: false }), null);
});

test("layout keeps 1:1 pixels unless the image is larger than the window", () => {
  const window = { width: 1000, height: 600 };
  const cell = { width: 10, height: 20 };
  assert.deepEqual(layoutImage({ width: 400, height: 300, size: "auto", window, cell, columns: 100 }), { columns: 0, displayWidth: 400 });
  assert.deepEqual(layoutImage({ width: 1600, height: 1200, size: "auto", window, cell, columns: 100 }), { columns: 80, displayWidth: 800 });
  assert.deepEqual(layoutImage({ width: 400, height: 300, size: "fill", window, cell, columns: 100 }), { columns: 80, displayWidth: 800 });
  assert.deepEqual(layoutImage({ width: 1600, height: 1200, size: "auto", window: null, columns: 100 }), { columns: 0, displayWidth: 1600 });
});

test("Kitty frames chunk base64 RGBA and zlib payloads", () => {
  const pixels = new Uint8Array(64 * 64 * 4).map((_, index) => index & 0xff);
  const direct = kittyImage({ id: 1, width: 64, height: 64, pixels });
  const chunks = [...direct.matchAll(/\x1b_G([^;]*);([^\x1b]*)\x1b\\/g)];
  assert.match(chunks[0][1], /^a=T,f=32,s=64,v=64,i=1,p=1,q=2,C=1,m=1$/);
  assert.equal(chunks.at(-1)[1], "m=0");
  assert.ok(chunks.every((chunk) => chunk[2].length <= 4096));
  assert.deepEqual(Buffer.from(chunks.map((chunk) => chunk[2]).join(""), "base64"), Buffer.from(pixels));
  const zlib = kittyImage({ id: 2, width: 64, height: 64, pixels, transport: "zlib", columns: 20 });
  const [, control, payload] = /\x1b_G([^;]*);([^\x1b]*)/.exec(zlib);
  assert.match(control, /c=20,o=z/);
  assert.ok(zlib.length < direct.length);
  assert.ok(payload.length > 0 && inflateSync(Buffer.from([...zlib.matchAll(/;([^\x1b]*)\x1b\\/g)].map((m) => m[1]).join(""), "base64")).equals(Buffer.from(pixels)));
});

test("arguments", () => {
  assert.deepEqual(parseArgs(["--stats", "--transport", "zlib", "gui/snake.wasm"]), {
    component: "gui/snake.wasm", input: undefined, uniforms: [], size: "auto", transport: "zlib", stats: true,
  });
  assert.throws(() => parseArgs(["--size", "huge", "x.wasm"]), /--size/);
});

class FakeTTY extends EventEmitter {
  constructor() {
    super();
    this.isTTY = true;
    this.isRaw = false;
    this.columns = 100;
    this.rows = 30;
    this.chunks = [];
  }
  setRawMode(value) { this.isRaw = value; }
  resume() {}
  pause() {}
  write(value, callback) {
    this.chunks.push(String(value));
    // Answer the startup probe like kitty: graphics OK, then window, cell and DA1 replies.
    if (String(value).includes("a=q")) {
      queueMicrotask(() => this.input?.emit("data", Buffer.from("\x1b_Gi=31;OK\x1b\\\x1b[4;600;1000t\x1b[6;20;10t\x1b[?62;c")));
    }
    callback?.();
    return true;
  }
}

test("SVG components are rejected with a clear message", async () => {
  const data = await readFile("gui/klondike.wasm");
  validateGUIBinary(data, "gui/klondike.wasm");
  const { exports } = new WebAssembly.Instance(new WebAssembly.Module(data));
  assert.throws(() => requireKTX2Output(exports, "gui/klondike.wasm"), {
    message: "gui/klondike.wasm renders SVG, but qipgui only displays KTX2 RGBA8 images",
  });
});

async function stageFor(path) {
  const data = await readFile(path);
  validateGUIBinary(data, path);
  const exports = new WebAssembly.Instance(new WebAssembly.Module(data)).exports;
  const stage = {
    label: path,
    component: { exports, uniformParamTypes: readUniformParamTypes(data, path) },
    inputless: exports.input_ptr === undefined,
    inputCapacity: exports.input_bytes_cap?.() ?? 0,
    outputCapacity: exports.output_bytes_cap(),
    uniforms: [],
  };
  stage.uniformArguments = parseUniforms(stage);
  return stage;
}

for (const path of ["gui/calculator.wasm", "gui/snake.wasm", "gui/paint.wasm"]) {
  test(`${path} presents Kitty frames and accepts pointer and key input`, async () => {
    const stage = await stageFor(path);
    const stdin = new FakeTTY();
    const stdout = new FakeTTY();
    stdout.input = stdin;
    const running = runGUI({ stage, input: new Uint8Array(), stdin, stdout });
    await new Promise((resolve) => setTimeout(resolve, 50));
    const framesBefore = stdout.chunks.filter((chunk) => chunk.includes("a=T")).length;
    assert.ok(framesBefore >= 1, "renders an initial frame");
    stdin.emit("data", Buffer.from("\x1b[<0;40;40M\x1b[<0;40;40m"));
    stdin.emit("data", Buffer.from("1"));
    await new Promise((resolve) => setTimeout(resolve, 50));
    process.emit("SIGINT");
    await running;
    process.exitCode = 0;
    const output = stdout.chunks.join("");
    assert.match(output, /\x1b_Ga=T,f=32,s=\d+,v=\d+,i=1,p=1,q=2,C=1/);
    assert.match(output, /\x1b\[\?1016h/);
    assert.ok(output.endsWith("\x1b[?1049l"), "restores the screen");
  });
}

test("non-KTX2 output is rejected", () => {
  assert.throws(() => parseKTX2RGBA8(new Uint8Array(200)), /not KTX2/);
});

test("applyUniforms from qiptui tolerates GUI components without size uniforms", async () => {
  const stage = await stageFor("gui/calculator.wasm");
  applyUniforms(stage, { columns: 80, lines: 24 });
});
