import assert from "node:assert/strict";
import { readFile, mkdtemp, rm, stat, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable, PassThrough } from "node:stream";
import { EventEmitter } from "node:events";
import test from "node:test";

import { loadWasm, main, multipart, parseArgs, runTUI, TextInputState, textInputMode, validateTerminalFrame, validateTUIBinary } from "../npm/qiptui/qiptui.mjs";

const calendar = await readFile("tui/calendar-gregorian.wasm");

test("qiptui accepts one component and terminal-safe input options", () => {
  assert.deepEqual(parseArgs(["-u", "columns=100", "qip.dev/tui/calendar-gregorian.wasm"]), {
    component: "qip.dev/tui/calendar-gregorian.wasm", host: "", input: undefined, forms: [], uniforms: ["columns=100"],
  });
  assert.deepEqual(parseArgs(["qip.dev", "-F", "component=<text/wc.wasm", "tui/qipdb.wasm"]), {
    component: "tui/qipdb.wasm", host: "qip.dev", input: undefined, forms: ["component=<text/wc.wasm"], uniforms: [],
  });
  assert.deepEqual(parseArgs(["qip.dev", "-F", "input=Hello", "-F", "component=@text/wc.wasm", "tui/qipdb.wasm"]), {
    component: "tui/qipdb.wasm", host: "qip.dev", input: undefined,
    forms: ["input=Hello", "component=@text/wc.wasm"], uniforms: [],
  });
  assert.equal(parseArgs(["local.wasm"]).component, "local.wasm");
  assert.equal(parseArgs(["-i", "-", "local.wasm"]).input, "-");
  assert.deepEqual(parseArgs(["-F", "data=<-", "local.wasm"]).forms, ["data=<-"]);
  assert.throws(() => parseArgs(["one.wasm", "two.wasm"]), /one TUI component/);
});

test("hosted path extension errors explain the requirement without assuming a file exists", async () => {
  await assert.rejects(
    main(["qip.dev", "-F", "input=Hello", "-F", "component=@text/wc.wasm", "tui/qipdb.wasm2"]),
    { message: "hosted component path qip.dev/tui/qipdb.wasm2 must end in .wasm; check the filename on qip.dev" },
  );
});

test("< sends file bytes as a field without a filename", async () => {
  const directory = await mkdtemp(join(tmpdir(), "qiptui-form-"));
  const path = join(directory, "input.txt");
  try {
    await writeFile(path, "hello\n");
    const body = await multipart([`data=<${path}`]);
    assert.match(body.toString(), /name="data"\r\n\r\nhello\n/);
    assert.doesNotMatch(body.toString(), /filename=|Content-Type: application\/octet-stream/);
    const piped = await multipart(["data=<-"], "", Readable.from([Buffer.from("piped\n")]));
    assert.match(piped.toString(), /name="data"\r\n\r\npiped\n/);
    assert.doesNotMatch(piped.toString(), /filename=/);
    const uploaded = await multipart(["data=@-"], "", Readable.from([Buffer.from("piped\n")]));
    assert.match(uploaded.toString(), /name="data"; filename="-"\r\nContent-Type: application\/octet-stream\r\n\r\npiped\n/);
    await assert.rejects(multipart(["a=<-", "b=<-"], "", Readable.from([Buffer.from("once")])), /only be used once/);
    await assert.rejects(multipart(["data=<-"], "", Readable.from([Buffer.from("too long")]), 3), /exceeds.*capacity/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("leading host supplies < Wasm bytes without saving or a filename", async () => {
  const originalFetch = globalThis.fetch;
  const requests = [];
  try {
    globalThis.fetch = async (url) => {
      requests.push(url);
      return new Response(calendar, { status: 200 });
    };
    const body = await multipart(["component=<tui/calendar-gregorian.wasm"], "qip.dev");
    assert.deepEqual(requests, ["https://qip.dev/tui/calendar-gregorian.wasm"]);
    assert.equal(body.includes(calendar), true);
    assert.doesNotMatch(body.toString("latin1"), /filename=/);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("leading host loads both the TUI and its < Wasm field", async () => {
  const originalFetch = globalThis.fetch;
  const requests = [];
  const qipdb = await readFile("tui/qipdb.wasm");
  try {
    globalThis.fetch = async (url) => {
      requests.push(url);
      return new Response(url.endsWith("/qipdb.wasm") ? qipdb : calendar, { status: 200 });
    };
    await assert.rejects(
      main(["qip.dev", "-F", "component=<tui/calendar-gregorian.wasm", "tui/qipdb.wasm"]),
      /requires terminal stdin and stdout/,
    );
    assert.deepEqual(requests, [
      "https://qip.dev/tui/qipdb.wasm",
      "https://qip.dev/tui/calendar-gregorian.wasm",
    ]);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("leading host loads both the TUI and its @ Wasm field", async () => {
  const originalFetch = globalThis.fetch;
  const requests = [];
  const qipdb = await readFile("tui/qipdb.wasm");
  const wc = await readFile("text/wc.wasm");
  try {
    globalThis.fetch = async (url) => {
      requests.push(url);
      return new Response(url.endsWith("/qipdb.wasm") ? qipdb : wc, { status: 200 });
    };
    await assert.rejects(
      main(["qip.dev", "-F", "input=Hello", "-F", "component=@text/wc.wasm", "tui/qipdb.wasm"]),
      /requires terminal stdin and stdout/,
    );
    assert.deepEqual(requests, [
      "https://qip.dev/tui/qipdb.wasm",
      "https://qip.dev/text/wc.wasm",
    ]);
    const body = await multipart(["component=@text/wc.wasm"], "qip.dev");
    assert.match(body.toString("latin1"), /name="component"; filename="wc\.wasm"/);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("host shorthand fetches on every run and does not create files", async () => {
  const directory = await mkdtemp(join(tmpdir(), "qiptui-test-"));
  const previous = process.cwd();
  const originalFetch = globalThis.fetch;
  const requests = [];
  try {
    process.chdir(directory);
    globalThis.fetch = async (url) => {
      requests.push(url);
      return new Response(calendar, { status: 200 });
    };
    const source = "qip.dev/tui/calendar-gregorian.wasm";
    assert.deepEqual(await loadWasm(source, (data) => new WebAssembly.Module(data)), calendar);
    assert.deepEqual(requests, ["https://qip.dev/tui/calendar-gregorian.wasm"]);
    await assert.rejects(stat("tui"), { code: "ENOENT" });
    await mkdir("tui");
    await writeFile("tui/calendar-gregorian.wasm", Buffer.from("local decoy"));
    assert.deepEqual(await loadWasm(source, (data) => new WebAssembly.Module(data)), calendar);
    assert.equal(requests.length, 2);
    assert.deepEqual(await readFile("tui/calendar-gregorian.wasm"), Buffer.from("local decoy"));
  } finally {
    globalThis.fetch = originalFetch;
    process.chdir(previous);
    await rm(directory, { recursive: true, force: true });
  }
});

test("absolute paths stay local with a host, and hosted 404s do not fall back", async () => {
  const directory = await mkdtemp(join(tmpdir(), "qiptui-source-"));
  const localPath = join(directory, "component.wasm");
  const originalFetch = globalThis.fetch;
  const previous = process.cwd();
  const requests = [];
  try {
    await writeFile(localPath, calendar);
    process.chdir(directory);
    globalThis.fetch = async (url) => {
      requests.push(url);
      return new Response(null, { status: 404 });
    };
    assert.deepEqual(await loadWasm(localPath, (data) => new WebAssembly.Module(data), "qip.dev"), calendar);
    const body = await multipart([`component=@${localPath}`], "qip.dev");
    assert.equal(body.includes(calendar), true);
    assert.deepEqual(requests, []);

    await mkdir("tui");
    await writeFile("tui/component.wasm", calendar);
    await assert.rejects(
      loadWasm("tui/component.wasm", (data) => new WebAssembly.Module(data), "qip.dev"),
      /https:\/\/qip\.dev\/tui\/component\.wasm returned HTTP 404/,
    );
    assert.deepEqual(requests, ["https://qip.dev/tui/component.wasm"]);
  } finally {
    globalThis.fetch = originalFetch;
    process.chdir(previous);
    await rm(directory, { recursive: true, force: true });
  }
});

test("invalid downloads leave no files and explicit local paths still work", async () => {
  const directory = await mkdtemp(join(tmpdir(), "qiptui-test-"));
  const previous = process.cwd();
  const originalFetch = globalThis.fetch;
  try {
    process.chdir(directory);
    globalThis.fetch = async () => new Response("invalid", { status: 200 });
    await assert.rejects(loadWasm("qip.dev/example.wasm", (data) => new WebAssembly.Module(data)));
    await assert.rejects(stat("example.wasm"), { code: "ENOENT" });
    await assert.rejects(loadWasm("qip.dev/../escape.wasm", () => {}), /invalid hosted component path/);
    await mkdir("tui");
    await writeFile("tui/local.wasm", calendar);
    assert.deepEqual(await loadWasm("./tui/local.wasm", (data) => new WebAssembly.Module(data)), calendar);
  } finally {
    globalThis.fetch = originalFetch;
    process.chdir(previous);
    await rm(directory, { recursive: true, force: true });
  }
});

test("terminal output still rejects control sequences", () => {
  assert.throws(() => validateTerminalFrame(Buffer.from("\x1b]52;c;YQ==\x07")), /terminal output/);
  assert.deepEqual(validateTerminalFrame(Buffer.from("hello\n\x1b[1mworld\x1b[0m")), Buffer.from("hello\n\x1b[1mworld\x1b[0m"));
});

test("-F reports declared input-type mismatches before opening the terminal", async () => {
  await assert.rejects(
    main(["-F", "input=hello", "./gui/svg-path-editor.wasm"]),
    /expects image\/svg\+xml, but -F supplies multipart\/form-data/,
  );
  await assert.rejects(
    main(["-F", "input=hello", "./tui/qipdb.wasm"]),
    /requires terminal stdin and stdout/,
  );
});

// Hand-assembled TUI-shaped modules that export everything qiptui requires but step
// outside the Strict Wasm Profile. Both come from wat2wasm; see docs/wasm-strict-profile.md.
const GROW_TUI = Buffer.from(
  "0061736d0100000001170560017f017e60017f017f60000060027f7f006000017f0306050001020304050401010102075306066d656d6f727902000672656e64657200000f626567696e5f7570646174655f617400010d66696e6973685f7570646174650002096b65795f6576656e7400030f6f75747075745f757466385f63617000040a1b050900410140001a42000b040041000b02000b02000b040041000b",
  "hex",
);
const START_TUI = Buffer.from(
  "0061736d0100000001170560000060017f017e60017f017f60027f7f006000017f030706000102000304050401010102075306066d656d6f727902000672656e64657200010f626567696e5f7570646174655f617400020d66696e6973685f7570646174650003096b65795f6576656e7400040f6f75747075745f757466385f63617000050801000a190602000b040042000b040041000b02000b02000b040041000b",
  "hex",
);

const DYNAMIC_GETTER_TUI = Buffer.from(
  "0061736d010000000117056000017f60017f017e60017f017f60000060027f7f00030706000102030400050401010102075306066d656d6f727902000672656e64657200010f626567696e5f7570646174655f617400020d66696e6973685f7570646174650003096b65795f6576656e7400040f6f75747075745f757466385f63617000050a1c06050041c0000b040042000b040041000b02000b02000b040010000b",
  "hex",
);

test("qiptui applies the Strict Wasm Profile checks that qipx applies", async () => {
  assert.throws(() => validateTUIBinary(DYNAMIC_GETTER_TUI), { message: "comply: static qip contract checks failed" });
  assert.throws(() => validateTUIBinary(GROW_TUI), {
    message: "TUI component uses memory.grow, which is outside the Strict Wasm Profile",
  });
  assert.throws(() => validateTUIBinary(START_TUI), {
    message: "TUI component declares a start function, which is outside the Strict Wasm Profile",
  });
  for (const name of ["epub-reader", "qipdb", "calendar-gregorian"]) {
    validateTUIBinary(await readFile(new URL(`../tui/${name}.wasm`, import.meta.url)), name);
  }
});

const emoji = await readFile("tui/emoji-finder.wasm");

test("text input mode requires an explicit UTF-8 text/plain transform and paired navigation exports", () => {
  const exports = new WebAssembly.Instance(new WebAssembly.Module(emoji)).exports;
  assert.equal(textInputMode(exports), true);
  assert.equal(textInputMode(new WebAssembly.Instance(new WebAssembly.Module(calendar)).exports), false);
  assert.throws(() => textInputMode({ ...exports, active_count: undefined }), /active_count/);
  assert.throws(() => textInputMode({ ...exports, input_bytes_cap() { return 1024; } }), /UTF-8 text\/plain/);
  assert.throws(() => textInputMode({ ...exports, key_event() {} }), /begin_update_at/);
});

test("text editor resets navigation only after edits and moves by grapheme clusters", () => {
  const state = new TextInputState(Buffer.from("👩🏽‍💻é"), 40);
  state.setActiveCount(3);
  state.handleKey({ keysym: 0xff54 });
  assert.equal(state.activeIndex, 1);
  state.handleKey({ keysym: 0xff51 });
  assert.equal(state.activeIndex, 1);
  state.handleKey({ keysym: 0xff08 });
  assert.equal(state.value, "é");
  assert.equal(state.activeIndex, 0);
  state.handleKey({ keysym: 0xff57 });
  state.handleKey({ keysym: 0xff08 });
  assert.equal(state.value, "");
  state.insertText("bear");
  state.setActiveCount(1);
  assert.equal(state.handleKey({ keysym: 0xff54 }), false);
  assert.equal(state.activeIndex, 0);
});

test("text editor rejects whole edits exceeding the UTF-8 capacity", () => {
  const state = new TextInputState(Buffer.from("é"), 4);
  state.insertText("é");
  state.handleKey({ keysym: 0x61 });
  assert.equal(state.value, "éé");
  assert.match(state.error, /4 UTF-8 bytes/);
  state.handleKey({ keysym: 0xff08 });
  assert.equal(state.value, "é");
  assert.equal(state.error, "");
  state.insertText("\x1b[31m");
  assert.equal(state.value, "é");
  assert.match(state.error, /printable line/);
  assert.throws(() => new TextInputState(Buffer.from("\x1b"), 4), /printable line/);
});

function terminal() {
  const stdin = new PassThrough();
  stdin.isTTY = true;
  stdin.isRaw = false;
  stdin.setRawMode = (raw) => { stdin.isRaw = raw; };
  const stdout = new EventEmitter();
  stdout.isTTY = true;
  stdout.columns = 80;
  stdout.rows = 24;
  const writes = [];
  stdout.write = (value) => { writes.push(Buffer.from(value).toString()); return true; };
  return { stdin, stdout, writes, frame: () => writes.join("").split("\x1b[H\x1b[J").at(-1) };
}

function startTerminal(wasm, initial = "") {
  const exports = new WebAssembly.Instance(new WebAssembly.Module(wasm)).exports;
  const t = terminal();
  const stage = { label: "test component", component: { exports }, inputless: !exports.input_ptr,
    inputCapacity: exports.input_utf8_cap?.() ?? 0, outputCapacity: exports.output_utf8_cap(), uniforms: [] };
  const done = runTUI({ stage, input: Buffer.from(initial), stdin: t.stdin, stdout: t.stdout,
    applyUniforms(_stage, dimensions) {
      exports.uniform_set_columns?.(dimensions.columns);
      exports.uniform_set_lines?.(dimensions.lines);
    } });
  return { ...t, exports, done, key: (bytes) => t.stdin.emit("data", Buffer.from(bytes)) };
}

test("qiptui edits full queries, navigates within bounds, and retains input on resize", async () => {
  const t = startTerminal(emoji, "woman technologist");
  try {
    assert.match(t.frame(), /^Find: woman technologist\r\nEMOJI FINDER/);
    assert.match(t.frame(), /ACTIVE EMOJI  👩‍💻  woman technologist/);
    t.key("\x1b[B");
    assert.match(t.frame(), /ACTIVE EMOJI  👩🏻‍💻/);
    for (let i = 0; i < 20; i++) t.key("\x1b[B");
    assert.match(t.frame(), /ACTIVE EMOJI  👩🏿‍💻/);
    t.key("\x1b[A");
    assert.match(t.frame(), /ACTIVE EMOJI  👩🏾‍💻/);
    t.stdout.emit("resize");
    assert.match(t.frame(), /^Find: woman technologist/);
    assert.match(t.frame(), /ACTIVE EMOJI  👩🏾‍💻/);
    t.key("\x7f");
    assert.match(t.frame(), /^Find: woman technologis\r\n/);
    assert.match(t.frame(), /ACTIVE EMOJI  👩‍💻/);
    t.key("\x15");
    assert.match(t.frame(), /^Find: \r\nEMOJI FINDER  3972 \/ 3972/);
    t.key("bear");
    assert.match(t.frame(), /ACTIVE EMOJI  🐻  bear/);
    const frame = t.frame();
    t.key("\r\x1b[Z");
    assert.equal(t.frame(), frame);
  } finally {
    t.key("\x03");
    await t.done;
  }
  assert.equal(t.stdin.isRaw, false);
  assert.match(t.writes.join(""), /\x1b\[\?2004l.*\x1b\[\?1049l/s);
});

test("qiptui handles split Unicode paste and rejects pasted terminal commands", async () => {
  const t = startTerminal(emoji);
  try {
    const paste = Buffer.from("\x1b[200~👩🏽‍💻\x1b[201~");
    t.key(paste.subarray(0, 10));
    t.key(paste.subarray(10, paste.length - 2));
    t.key(paste.subarray(paste.length - 2));
    assert.match(t.frame(), /^Find: 👩🏽‍💻/);
    t.key("\x7f");
    assert.match(t.frame(), /^Find: \r\n/);
    t.key("\x1b[200~\x03\x1b[B\x1b[201~");
    assert.match(t.frame(), /Use one printable line/);
    assert.equal(t.stdin.isRaw, true);
    t.key("bear");
    assert.match(t.frame(), /ACTIVE EMOJI  🐻/);
    t.key("\x15");
    t.key("ｒ－！");
    assert.match(t.frame(), /^Find: ｒ－！/);
  } finally {
    t.key("\x03");
    await t.done;
  }
});

test("qiptui still runs eventful components and restores the terminal", async () => {
  const t = startTerminal(calendar);
  try {
    const initial = t.frame();
    t.key("\x1b[B");
    assert.notEqual(t.frame(), initial);
    assert.doesNotMatch(t.frame(), /^Find:/);
  } finally {
    t.key("\x03");
    await t.done;
  }
  assert.equal(t.stdin.isRaw, false);
});

test("qiptui pages feature details and resets their offset on selection, edits, and resize", async () => {
  const t = startTerminal(await readFile("tui/caniuse-finder.wasm"), "css-grid");
  try {
    const initial = t.frame();
    for (const browser of ["Chrome", "Firefox", "Safari", "Edge"]) assert.match(initial, new RegExp(`${browser}:`));
    const count = t.exports.active_count();
    t.key("\x1b[6~");
    assert.notEqual(t.frame(), initial);
    assert.equal(t.exports.active_count(), count);
    assert.equal(t.frame().split("DETAILS")[0], initial.split("DETAILS")[0]);
    t.key("\x1b[5~");
    assert.equal(t.frame(), initial);
    t.key("\x1b[6~");
    t.stdout.emit("resize");
    assert.equal(t.frame(), initial);
    t.key("\x1b[6~");
    t.key("\x1b[B");
    assert.match(t.frame(), /Chrome:/);
    t.key("\x1b[6~");
    t.key("z");
    assert.match(t.frame(), /No matches/);
  } finally {
    t.key("\x03");
    await t.done;
  }
});
