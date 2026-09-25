import assert from "node:assert/strict";
import { readFile, mkdtemp, rm, stat, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import test from "node:test";

import { loadWasm, main, multipart, parseArgs, validateTerminalFrame } from "../npm/qiptui/qiptui.mjs";

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
