import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { ContentComponentHost } from "./lib/content-component-host.mjs";

const debuggerPath = fileURLToPath(new URL("../components/interactive/qipdb.wasm", import.meta.url));
const targetPath = fileURLToPath(new URL("../components/text/hello.wasm", import.meta.url));
const wcPath = fileURLToPath(new URL("../components/text/wc.wasm", import.meta.url));
const infiniteLoopPath = fileURLToPath(new URL("../components/text/infinite-loop.wasm", import.meta.url));
const commonmarkPath = fileURLToPath(new URL("../components/text/markdown/commonmark.0.31.2.wasm", import.meta.url));
const qrPath = fileURLToPath(new URL("../components/text/uri-list/url-to-qr-svg.wasm", import.meta.url));
const qipToZigPath = fileURLToPath(new URL("../components/application/wasm/qip-component-to-zig.wasm", import.meta.url));
const bulkMemoryPath = fileURLToPath(new URL("./fixtures/wasm-debugger-bulk-memory.wasm", import.meta.url));
const callIndirectPath = fileURLToPath(new URL("./fixtures/wasm-debugger-call-indirect.wasm", import.meta.url));
const stripAnsiPath = fileURLToPath(new URL("../components/text/strip-ansi-sgr.wasm", import.meta.url));
const ansiHTMLPath = fileURLToPath(new URL("../components/text/ansi-sgr-to-html.wasm", import.meta.url));
const decoder = new TextDecoder("utf-8", { fatal: true });
const boundary = "uuid-00000000-0000-0000-0000-000000000000";
const [stripAnsiBytes, ansiHTMLBytes] = await Promise.all([
  readFile(stripAnsiPath),
  readFile(ansiHTMLPath),
]);
const stripAnsiHost = new ContentComponentHost(stripAnsiBytes, { label: "strip ANSI" });
const ansiHTMLHost = new ContentComponentHost(ansiHTMLBytes, { label: "ANSI to HTML" });

function multipart(parts) {
  const chunks = [];
  for (const [name, body] of parts) {
    chunks.push(
      Buffer.from(
        `--${boundary}\r\n` +
        `Content-Disposition: form-data; name="${name}"; filename="${name}"\r\n` +
        `Content-Type: application/octet-stream\r\n\r\n`,
      ),
      Buffer.from(body),
      Buffer.from("\r\n"),
    );
  }
  chunks.push(Buffer.from(`--${boundary}--\r\n`));
  return Buffer.concat(chunks);
}

function renderedANSI(instance, inputSize) {
  const result = BigInt.asUintN(64, instance.exports.render(inputSize));
  assert.equal(result >> 63n, 0n);
  const size = Number(result & 0xffff_ffffn);
  const pointer = Number((result >> 32n) & 0x7fff_ffffn);
  return decoder.decode(new Uint8Array(instance.exports.memory.buffer, pointer, size));
}

function runTextComponent(host, input) {
  const result = host.run(input);
  assert.equal(result.status, "accepted");
  return decoder.decode(result.output);
}

function stripANSI(input) {
  return runTextComponent(stripAnsiHost, input);
}

function renderedText(instance, inputSize) {
  return stripANSI(renderedANSI(instance, inputSize));
}

function sendKey(instance, time, keysym, flags = 1) {
  instance.exports.begin_update_at(time);
  assert.equal(instance.exports.key_event(keysym, flags), 1);
  assert.equal(instance.exports.finish_update(), time);
}

function sendKeyWithBudget(instance, time, keysym, budget, flags = 1) {
  instance.exports.begin_update_at(time);
  assert.equal(instance.exports.uniform_set_instruction_budget(budget), budget);
  assert.equal(instance.exports.key_event(keysym, flags), 1);
  assert.equal(instance.exports.finish_update(), time);
}

function assertTerminalWidth(text) {
  for (const line of text.split("\n")) assert.ok(line.length <= 80, `${line.length}-column line: ${line}`);
}

function executionRowCount(text) {
  return text.split("\n").filter((line) => (
    /^[=>rnf↑↓ ]{3}f\d+ 0x[0-9a-f]+/.test(line) || /^(?:=> | {3})host (?:wrote|passed)/.test(line)
  )).length;
}

test("interactive Wasm debugger fits its terminal viewport", async () => {
  const [debuggerBytes, targetBytes] = await Promise.all([
    readFile(debuggerPath),
    readFile(targetPath),
  ]);
  const { instance } = await WebAssembly.instantiate(debuggerBytes, {});
  assert.equal(instance.exports.uniform_set_columns(32), 32);
  assert.equal(instance.exports.uniform_set_lines(5), 5);
  const debuggerInput = multipart([["component", targetBytes]]);
  const inputPointer = instance.exports.input_ptr();
  new Uint8Array(instance.exports.memory.buffer, inputPointer, debuggerInput.length).set(debuggerInput);

  const output = renderedText(instance, debuggerInput.length);
  const lines = output.split("\n");
  assert.equal(lines.length, 5);
  assert.ok(lines.every((line) => line.length <= 32));
  assert.match(output, /^qipdb  ●  i expand/);
  assert.match(output, /^MEMORY/m);
  assert.ok(!output.endsWith("\n"));
});

test("question mark toggles the keyboard cheatsheet", async () => {
  const [debuggerBytes, targetBytes] = await Promise.all([
    readFile(debuggerPath),
    readFile(targetPath),
  ]);
  const { instance } = await WebAssembly.instantiate(debuggerBytes, {});
  const debuggerInput = multipart([["component", targetBytes]]);
  const inputPointer = instance.exports.input_ptr();
  new Uint8Array(instance.exports.memory.buffer, inputPointer, debuggerInput.length).set(debuggerInput);

  assert.doesNotMatch(renderedText(instance, debuggerInput.length), /^HELP/m);
  assert.match(renderedText(instance, 0), /\? help/);
  sendKey(instance, 2n, 0x3f);
  const helpANSI = renderedANSI(instance, 0);
  const help = stripANSI(helpANSI);
  assertTerminalWidth(help);
  assert.match(help, /^HELP  \? close/m);
  assert.match(help, /STATUS  ● at instruction  ● budget exhausted  ● completed  ● failed\/trapped/);
  assert.match(help, /COLOR LEGEND\n    i32\.add ordinary  local\/global storage  \.get\/\.load read/);
  assert.match(help, /\.set\/\.store write  if\/select control  loop\/call loops and calls/);
  assert.match(help, /0x00000000 value/);
  assert.match(helpANSI, /\x1b\[93mi32\.add\x1b\[0m/);
  assert.match(helpANSI, /\x1b\[34mlocal\/global\x1b\[0m/);
  assert.match(helpANSI, /\x1b\[95m\.get\/\.load\x1b\[0m/);
  assert.match(helpANSI, /\x1b\[92m\.set\/\.store\x1b\[0m/);
  assert.match(helpANSI, /\x1b\[36mif\/select\x1b\[0m/);
  assert.match(helpANSI, /\x1b\[96mloop\/call\x1b\[0m/);
  assert.match(helpANSI, /\x1b\[94m0x00000000\x1b\[0m/);
  assert.match(help, /↓ \/ S \/ F11.*step into.*N \/ F10.*step over/);
  assert.match(help, /↑ \/ Alt-\[.*step back.*F \/ Shift-F11.*finish function/);
  assert.match(help, /Space \/ C \/ F5.*continue.*R.*restart/);
  assert.match(help, /R.*restart.*I.*counters/);
  assert.match(help, /X I \/ X O.*input\/output.*X R \/ X W.*last read\/write/);
  assert.match(help, /X ↑ \/ X ↓.*page memory.*Backspace \/ Enter \/ Esc.*edit\/accept\/cancel/);
  sendKey(instance, 3n, 0x3f);
  assert.doesNotMatch(renderedText(instance, 0), /^HELP/m);

  sendKey(instance, 4n, 0x69); // i: expand counters.
  const counters = renderedText(instance, 0);
  assertTerminalWidth(counters);
  assert.match(counters, /qipdb  ●  i collapse  \? help\n  WASM     274 B\n  QIP      UTF-8 → UTF-8  input-capacity=65536 B  output-capacity=65536 B\n  EXPORTS  functions=4  tables=0  memories=1  globals=0  tags=0\n  RUNTIME  executed=0  branches-taken=0  calls=0  returns=0/);
  assert.match(counters, /CODE     instructions=61  functions=5  globals=4/);
  assert.match(counters, /CONTROL  loops=1  branch-sites=2  conditional-sites=2/);
  assert.match(counters, /CALLS    direct=1  call_indirect=0  return_call_indirect=0  call_ref=0/);
  assert.match(counters, /TABLES   tables=0  fixed=0  initial-slots=0  maximum-slots=0/);
  assert.match(counters, /SIMD     instructions=0  v128-types=0/);
  assert.match(counters, /MEMORY   load-sites=1  store-sites=3  copies=0  fills=0/);
  assert.match(counters, /TRAPS    potential-sites=4  explicit=0  memory=4  table=0\n           division=0  remainder=0  float-to-int=0  call-ref=0/);
  assert.match(counters, /FUNCTIONS reachable=2\/5  → direct  ⇢ possible indirect\n    f4 render  calls=1  → f3\n    f3  calls=0\n      loop 0x0000d4  iterations=0/);
  sendKey(instance, 5n, 0x49); // I: collapse counters.
  assert.doesNotMatch(renderedText(instance, 0), /CODE     instructions=/);
});

test("table-using repository components match native Wasm SHA-256 output", async () => {
  const [debuggerBytes, commonmarkBytes, qrBytes, qipToZigBytes, helloBytes] = await Promise.all([
    readFile(debuggerPath),
    readFile(commonmarkPath),
    readFile(qrPath),
    readFile(qipToZigPath),
    readFile(targetPath),
  ]);
  const cases = [
    { name: "CommonMark", bytes: commonmarkBytes, input: Buffer.from("# Hello\n\nA **small** table-call test.\n") },
    { name: "QR SVG", bytes: qrBytes, input: Buffer.from("https://qip.dev/") },
    { name: "QIP to Zig", bytes: qipToZigBytes, input: helloBytes },
  ];

  for (const target of cases) {
    const nativeTarget = (await WebAssembly.instantiate(target.bytes, {})).instance;
    new Uint8Array(
      nativeTarget.exports.memory.buffer,
      nativeTarget.exports.input_ptr(),
      target.input.length,
    ).set(target.input);
    const nativeResult = BigInt.asUintN(64, nativeTarget.exports.render(target.input.length));
    const nativeSize = Number(nativeResult & 0xffff_ffffn);
    const nativePointer = Number((nativeResult >> 32n) & 0x7fff_ffffn);
    const expectedDigest = createHash("sha256").update(new Uint8Array(
      nativeTarget.exports.memory.buffer,
      nativePointer,
      nativeSize,
    )).digest("hex");

    const { instance } = await WebAssembly.instantiate(debuggerBytes, {});
    const debuggerInput = multipart([
      ["component", target.bytes],
      ["input", target.input],
    ]);
    const inputPointer = instance.exports.input_ptr();
    new Uint8Array(instance.exports.memory.buffer, inputPointer, debuggerInput.length).set(debuggerInput);
    const initial = renderedText(instance, debuggerInput.length);
    assert.doesNotMatch(initial, /INPUT  rejected/, target.name);

    let completed = initial;
    for (let command = 0; command < 10 && !completed.includes("INSTRUCTIONS  r restart"); command++) {
      sendKeyWithBudget(instance, BigInt(command + 2), 0x63, 1_000_000); // c
      completed = renderedText(instance, 0);
    }
    assert.match(completed, /INSTRUCTIONS  r restart/, target.name);
    assert.match(completed, new RegExp(`sha256=${expectedDigest}`), target.name);

    if (target.name === "CommonMark") {
      sendKey(instance, 12n, 0x69); // i
      const counters = renderedText(instance, 0);
      assert.match(counters, /CODE     instructions=22092/);
      assert.match(counters, /CALLS    direct=\d+  call_indirect=2  return_call_indirect=0  call_ref=0/);
      assert.match(counters, /TABLES   tables=1  fixed=1  initial-slots=5  maximum-slots=5/);
    }
  }
});

test("steps through a typed table dispatch and retains it across restart", async () => {
  const [debuggerBytes, targetBytes] = await Promise.all([
    readFile(debuggerPath),
    readFile(callIndirectPath),
  ]);
  const nativeTarget = (await WebAssembly.instantiate(targetBytes, {})).instance;
  const nativeResult = BigInt.asUintN(64, nativeTarget.exports.render(1));
  const nativeSize = Number(nativeResult & 0xffff_ffffn);
  const nativePointer = Number((nativeResult >> 32n) & 0x7fff_ffffn);
  const expectedDigest = createHash("sha256").update(new Uint8Array(
    nativeTarget.exports.memory.buffer,
    nativePointer,
    nativeSize,
  )).digest("hex");

  const { instance } = await WebAssembly.instantiate(debuggerBytes, {});
  const debuggerInput = multipart([
    ["component", targetBytes],
    ["input", Buffer.from([0])],
  ]);
  const inputPointer = instance.exports.input_ptr();
  new Uint8Array(instance.exports.memory.buffer, inputPointer, debuggerInput.length).set(debuggerInput);
  renderedText(instance, debuggerInput.length);

  for (let time = 2n; time <= 5n; time++) sendKey(instance, time, 0x73);
  const callScreen = renderedText(instance, 0);
  assertTerminalWidth(callScreen);
  assert.match(callScreen, /^=> f\d+ .* call_indirect \(type 0\)/m);
  assert.match(callScreen, /;; \(param i32\)[^\n]*\n[^\n]*;; \(param i32\)[^\n]*\n[^\n]*;; \(result i32\)/);
  assert.match(callScreen, /^↓ {4}f\d+ .* local\.get 0/m);
  assert.match(callScreen, /stack\[3\] i32 0x00000001/);

  sendKey(instance, 6n, 0x63); // c
  const completed = renderedText(instance, 0);
  assert.match(completed, /INSTRUCTIONS  r restart/);
  assert.match(completed, /OUTPUT succeeded size=4 ptr=0x00000020/);
  assert.match(completed, new RegExp(`sha256=${expectedDigest}`));
  sendKey(instance, 7n, 0x69); // i
  const info = renderedText(instance, 0);
  assert.match(info, /RUNTIME[^\n]*indirect=1/);
  assert.match(info, /FUNCTIONS reachable=2\/5  → direct  ⇢ possible indirect\n    f4 render  calls=1  ⇢ f2\n    f2  calls=1/);

  sendKey(instance, 8n, 0x72); // r
  sendKey(instance, 9n, 0x63); // c
  assert.match(renderedText(instance, 0), new RegExp(`sha256=${expectedDigest}`));

  for (const [size, trap] of [
    [0, "uninitialized table element"],
    [2, "indirect call type mismatch"],
    [3, "out-of-bounds table access"],
  ]) {
    const trapped = (await WebAssembly.instantiate(debuggerBytes, {})).instance;
    const trappedInput = multipart([
      ["component", targetBytes],
      ["input", Buffer.alloc(size)],
    ]);
    new Uint8Array(trapped.exports.memory.buffer, trapped.exports.input_ptr(), trappedInput.length).set(trappedInput);
    renderedText(trapped, trappedInput.length);
    sendKey(trapped, 2n, 0x63);
    const trappedANSI = renderedANSI(trapped, 0);
    assert.match(trappedANSI, /^\x1b\[1mqipdb\x1b\[0m  \x1b\[91m●\x1b\[0m/);
    assert.match(stripANSI(trappedANSI), new RegExp(`trap ${trap}`));
  }
});

test("local transfers connect their source and destination stack slots", async () => {
  const [debuggerBytes, targetBytes] = await Promise.all([
    readFile(debuggerPath),
    readFile(targetPath),
  ]);
  const { instance } = await WebAssembly.instantiate(debuggerBytes, {});
  const debuggerInput = multipart([["component", targetBytes]]);
  const inputPointer = instance.exports.input_ptr();
  new Uint8Array(instance.exports.memory.buffer, inputPointer, debuggerInput.length).set(debuggerInput);
  renderedText(instance, debuggerInput.length);

  for (let time = 2n; time <= 5n; time++) sendKey(instance, time, 0x73);
  const getScreen = renderedText(instance, 0);
  assertTerminalWidth(getScreen);
  assert.match(getScreen, /^=> f\d+ .* local\.get 0/m);
  assert.match(getScreen, /┌─  param\[0\] 0x0000000000000000\n[^\n]*│   locals none/);
  assert.match(getScreen, /│   stack\[0\][^\n]*\n[^\n]*└─▶ next stack\[1\] i32 0x00000000/);

  let setScreen = "";
  for (let time = 6n; time < 80n; time++) {
    const screen = renderedText(instance, 0);
    if (/^=> f\d+ .* local\.set 2/m.test(screen)) {
      setScreen = screen;
      break;
    }
    sendKey(instance, time, 0x73);
  }
  assert.notEqual(setScreen, "", "expected to reach hello.wasm local.set 2");
  assertTerminalWidth(setScreen);
  assert.match(setScreen, /local\[1\] 0x0000000000000000\n[^\n]*┌─▶ next local\[1\] i32 0x0000000c/);
  assert.match(setScreen, /│ #1 f\d+ render/);
  assert.match(setScreen, /└─  stack\[1\] i32 0x0000000c/);
  assert.match(setScreen, /^  f finish/m);
});

test("interactive Wasm debugger steps and restarts a target component", async () => {
  const [debuggerBytes, targetBytes] = await Promise.all([
    readFile(debuggerPath),
    readFile(targetPath),
  ]);
  const { instance } = await WebAssembly.instantiate(debuggerBytes, {});
  const debuggerInput = multipart([["component", targetBytes]]);
  const inputPointer = instance.exports.input_ptr();
  new Uint8Array(instance.exports.memory.buffer, inputPointer, debuggerInput.length).set(debuggerInput);

  const initialANSI = renderedANSI(instance, debuggerInput.length);
  assert.match(initialANSI, /^\x1b\[1mqipdb\x1b\[0m  \x1b\[96m●\x1b\[0m/);
  assert.match(initialANSI, /\x1b\[1mWASM\x1b\[0m  \x1b\[2m274 B\x1b\[0m/);
  assert.doesNotMatch(initialANSI, /executed=0|calls=\x1b\[96m0|iterations=\x1b\[96m0/);
  assert.match(initialANSI, /^\x1b\[1mMEMORY\x1b\[0m/m);
  assert.match(initialANSI, /reads=\x1b\[95m0\x1b\[0m writes=\x1b\[92m0\x1b\[0m/);
  assert.match(initialANSI, /\x1b\[1;97m=>\x1b\[0m/);
  assert.match(initialANSI, /\x1b\[1;97m=>\x1b\[0m \x1b\[4mhost wrote/);
  assert.match(initialANSI, /host wrote \x1b\[94m0\x1b\[0m\x1b\[4m B input at \x1b\[94m0x00010000\x1b\[0m/);
  assert.doesNotMatch(initialANSI, /\x1b\[1;97mr\x1b\[0m/);
  assert.match(initialANSI, /\x1b\[1;97m↓\x1b\[0m/);
  assert.doesNotMatch(initialANSI, /\x1b\[1;97mn\x1b\[0m/);
  assert.match(initialANSI, /\x1b\[1;97mx\x1b\[0m examine/);
  assert.match(initialANSI, /\x1b\[1;97mSpace\x1b\[0m run/);
  assert.match(initialANSI, /\x1b\[94m00010000\x1b\[0m/);
  assert.match(initialANSI, /\x1b\[2m00 00 00 00/);
  assert.match(initialANSI, /\x1b\[2m0x[0-9a-f]{6}\x1b\[0m/);
  assert.match(initialANSI, /\x1b\[34mglobal\x1b\[95m\.get\x1b\[0m 2\x1b\[0m/);
  assert.match(initialANSI, /\x1b\[34mlocal\x1b\[95m\.get\x1b\[0m 0\x1b\[0m/);
  assert.doesNotMatch(initialANSI, /next stack\[0\]/);
  const initialHTML = runTextComponent(ansiHTMLHost, initialANSI);
  assert.match(initialHTML, /<b>MEMORY<\/b>/);
  assert.match(initialHTML, /<b><span style="color:#ffffff;">=&gt;<\/span><\/b>/);
  assert.match(initialHTML, /<u>host wrote /);
  assert.match(initialHTML, /<span style="color:#3b8eea;">00010000<\/span>/);
  assert.match(initialHTML, /<span style="opacity:\.65;">0x[0-9a-f]{6}<\/span>/);
  const initial = stripANSI(initialANSI);
  assert.doesNotMatch(initial, /\x1b\[/);
  assert.match(initial, /^qipdb[^\n]*WASM  274 B  QIP content component  UTF-8 → UTF-8\nMEMORY/m);
  assert.equal(instance.exports.target_input_ptr(), 0x10000);
  assertTerminalWidth(initial);
  assert.match(initial, /^qipdb  ●  i expand  \? help/);
  assert.match(initial, /^MEMORY  /m);
  assert.match(initial, /^INSTRUCTIONS  Space run +STACKS\/LOCALS/m);
  assert.doesNotMatch(initial, /INSTRUCTIONS  ready/);
  assert.match(initial, /WASM  274 B  QIP content component  UTF-8 → UTF-8$/m);
  assert.match(initial, /^=> host wrote 0 B input at 0x00010000[^\n]*\n↓ {2}f\d+/m);
  assert.match(initial, /WASM  274 B/);
  assert.doesNotMatch(initial, /input=0 B/);
  assert.match(initial, /^INSTRUCTIONS  Space run/m);
  assert.doesNotMatch(initial, /^  f finish/m);
  assert.doesNotMatch(initial, /r restart/);
  assert.doesNotMatch(initial, /n\/F10 next  s\/F11 step/);
  assert.match(initial, /STACKS\/LOCALS\n/);
  assert.match(initial, /global\[0\] 0x[0-9a-f]{16}/);
  assert.match(initial, /global\[2\] 0x0000000000020000/);
  assert.doesNotMatch(initial, /stack pointer/);
  assert.match(initial, /#0 f4 render/);
  assert.match(initial, /param\[0\] 0x0000000000000000/);
  assert.match(initial, /#0 f4 render[\s\S]*stack empty/);
  assert.match(initial, /qipdb  ●  i expand  \? help  WASM  274 B  QIP content component/);
  assert.doesNotMatch(initial, /loop f\d+ 0x[0-9a-f]+ iterations=/);
  assert.match(initial, /MEMORY  192 KiB  pages=3  reads=0 writes=0  x examine\n  00010000  /);

  instance.exports.begin_update_at(1n);
  assert.equal(instance.exports.key_event(0xff51, 1), 0); // Left Arrow is not an execution command.
  assert.equal(instance.exports.key_event(0xff53, 1), 0); // Right Arrow is not an execution command.
  assert.equal(instance.exports.finish_update(), 1n);

  // Down Arrow is the visible step-in control; s remains a debugger-style alias.
  sendKey(instance, 2n, 0xff54);
  const extendPreview = renderedText(instance, 0);
  assert.doesNotMatch(renderedANSI(instance, 0), /\x1b\[1;97mr\x1b\[0m/);
  assert.match(extendPreview, /stack\[0\] i32 0x00020000/);
  assert.match(extendPreview, /┌─ {2}stack\[0\][^\n]*\n[^\n]*├─ {2}i64\.extend_i32_u\n[^\n]*└─▶ next stack\[0\] i64 0x0000000000020000/);
  for (let time = 3n; time <= 4n; time++) sendKey(instance, time, 0x73); // s
  const beforeShift = renderedText(instance, 0);
  const beforeShiftANSI = renderedANSI(instance, 0);
  assert.doesNotMatch(beforeShift, /WASM  274 B/);
  assert.doesNotMatch(beforeShift, /^WASM  /m);
  assert.match(beforeShift, /^=> f4 .* i64\.shl/m);
  assert.match(beforeShift, /stack\[1\] i64 0x0000000000000020/);
  assert.match(beforeShift, /stack\[0\] i64 0x0000000000020000/);
  assert.match(beforeShift, /stack\[0\] i64 0x0000000000020000[^\n]*\n[^\n]*stack\[1\] i64 0x0000000000000020/);
  assert.match(beforeShiftANSI, /\x1b\[93m├─ {2}\x1b\[0m\x1b\[93mstack\[1\] i64 0x0000000000000020\x1b\[0m/);
  assert.match(beforeShiftANSI, /\x1b\[93m┌─ {2}\x1b\[0m\x1b\[93mstack\[0\] i64 0x0000000000020000\x1b\[0m/);
  assert.match(beforeShift, /┌─ {2}stack\[0\][^\n]*\n[^\n]*├─ {2}stack\[1\][^\n]*\n[^\n]*├─ {2}i64\.shl[^\n]*\n[^\n]*└─▶ next stack\[0\] i64 0x0002000000000000/);
  assert.doesNotMatch(beforeShift, /;; 0x[0-9a-f]+ <</);
  assert.doesNotMatch(beforeShift, /value\[/);
  for (let time = 5n; time <= 6n; time++) sendKey(instance, time, 0x73); // s
  assert.match(renderedANSI(instance, 0), / {4}\x1b\[96mstack\[1\] i32 0x00000000\x1b\[0m/);
  assert.match(renderedText(instance, 0), /^=> f4 .* call f3[^\n]*\n {4};; \(param i32\) \(result i32\)[^\n]*\n↓ {4}f3 .*\n {4}…[^\n]*\nn {2}f4 .*i64\.extend_i32_u/m);
  assert.match(renderedText(instance, 0), /qipdb  ●  i expand  \? help  executed=5/);
  sendKey(instance, 7n, 0x6e); // n: step over the call.
  assert.match(renderedText(instance, 0), /^qipdb[^\n]*calls=1[\s\S]*^=> f\d+ 0x[0-9a-f]+ i64\.extend_i32_u/m);

  sendKey(instance, 8n, 0x72); // r: restart.
  assert.match(renderedText(instance, 0), /qipdb  ●  i expand  \? help  WASM  274 B/);
  assert.match(renderedText(instance, 0), /WASM  274 B  QIP content component  UTF-8 → UTF-8$/m);
  sendKey(instance, 9n, 0x6e); // n: step over an ordinary instruction.
  assert.match(renderedText(instance, 0), /qipdb  ●  i expand  \? help  executed=1/);
  sendKey(instance, 10n, 0x72); // r
  sendKey(instance, 11n, 0x66); // f: finish the current frame.
  const normallyFinishedANSI = renderedANSI(instance, 0);
  const normallyFinished = stripANSI(normallyFinishedANSI);
  assertTerminalWidth(normallyFinished);
  assert.match(normallyFinishedANSI, /\x1b\[92m48 65 6c 6c 6f/);
  assert.doesNotMatch(normallyFinished, /last write|\^\^/);
  assert.match(normallyFinished, /r restart/);
  assert.doesNotMatch(normallyFinished, /Space run|f finish/);
  assert.match(normallyFinishedANSI, /\x1b\[1;4;92m6f\x1b\[0m \x1b\[1;4;92m72\x1b\[0m \x1b\[1;4;92m6c\x1b\[0m \x1b\[1;4;92m64\x1b\[0m /);
  assert.match(normallyFinishedANSI, /\x1b\[1;4;92morld\x1b\[0m/);
  assert.match(normallyFinished, /^  00020000  .*Hello, World/m);
  sendKey(instance, 12n, 0x72); // r
  sendKey(instance, 13n, 0x63); // c
  assert.match(renderedText(instance, 0), /INSTRUCTIONS  r restart/);

  // Visual Studio-style function keys remain aliases.
  sendKey(instance, 14n, 0x72); // r
  sendKey(instance, 15n, 0xffc8); // F11: step into.
  sendKey(instance, 16n, 0xffc7); // F10: step over.
  assert.match(renderedText(instance, 0), /qipdb  ●  i expand  \? help  executed=2/);
  sendKey(instance, 17n, 0xffc8, 1 | (1 << 2)); // Shift-F11: step out.
  assert.match(renderedText(instance, 0), /INSTRUCTIONS  r restart/);

  const nativeTarget = (await WebAssembly.instantiate(targetBytes, {})).instance;
  const expectedResult = BigInt.asUintN(64, nativeTarget.exports.render(0));
  const expectedSize = Number(expectedResult & 0xffff_ffffn);
  const expectedPointerForDigest = Number((expectedResult >> 32n) & 0x7fff_ffffn);
  const expectedDigest = createHash("sha256").update(new Uint8Array(
    nativeTarget.exports.memory.buffer,
    expectedPointerForDigest,
    expectedSize,
  )).digest("hex");
  sendKey(instance, 18n, 0x72); // r
  sendKey(instance, 19n, 0xffc2); // F5: continue.
  const completed = renderedText(instance, 0);
  assert.match(completed, /INSTRUCTIONS  r restart/);
  assert.match(completed, /OUTPUT succeeded size=12 ptr=0x00020000 packed=/);
  assert.match(completed, new RegExp("packed=0x" + expectedResult.toString(16).padStart(16, "0")));
  assert.match(completed, new RegExp(`sha256=${expectedDigest}`));

  sendKey(instance, 20n, 0x78); // x: enter a memory address.
  assert.match(renderedText(instance, 0), /x address 0x00000000 \(0\/8\)  i input  o output  w last-write\n  ↑\/↓ page  0-9\/a-f hex  Backspace edit  Enter accept  Esc cancel/);
  sendKey(instance, 21n, 0x69); // i: input_ptr.
  assert.match(renderedText(instance, 0), /^  00010000  /m);
  sendKey(instance, 22n, 0x78); // x
  sendKey(instance, 23n, 0x6f); // o: completed output pointer.
  const expectedPointer = Number((expectedResult >> 32n) & 0x7fff_ffffn);
  assert.match(renderedText(instance, 0), new RegExp(`^  ${expectedPointer.toString(16).padStart(8, "0")}  `, "m"));

  sendKey(instance, 24n, 0x78); // x: enter a hexadecimal address.
  for (const [time, digit] of [[25n, "2"], [26n, "0"], [27n, "0"], [28n, "0"], [29n, "8"]]) {
    sendKey(instance, time, digit.codePointAt(0));
  }
  sendKey(instance, 30n, 0xff0d); // Enter.
  assert.match(renderedText(instance, 0), /^  00020008  /m);
  sendKey(instance, 31n, 0x78); // x: memory examine mode.
  sendKey(instance, 32n, 0xff54); // Down Arrow: next 128-byte page.
  assert.match(renderedText(instance, 0), /^  00020088  /m);
  sendKey(instance, 33n, 0xff52); // Up Arrow: previous page.
  assert.match(renderedText(instance, 0), /^  00020008  /m);
  sendKey(instance, 34n, 0xff1b); // Escape: leave memory examine mode.

  sendKey(instance, 35n, 0x72); // r
  for (let time = 36n; time <= 40n; time++) sendKey(instance, time, 0x73); // s to call.
  sendKey(instance, 41n, 0x73); // s into the callee.
  const insideCallee = renderedText(instance, 0);
  assert.match(insideCallee, /^=> f3 .*\n↓ {2}f3/m);
  assert.match(insideCallee, /^f {2}f4 /m);
  assert.ok(insideCallee.indexOf("\n↓  f3 ") < insideCallee.indexOf("\nf  f4 "));

  instance.exports.begin_update_at(42n);
  assert.equal(instance.exports.key_event(0x6f, 1), 0); // o is not an alias for n.
  assert.equal(instance.exports.key_event(0x69, 1), 1); // i expands counters; it does not step.
  assert.equal(instance.exports.key_event(0x20, 1), 1); // Space continues to the end.
  assert.equal(instance.exports.finish_update(), 42n);
  assert.match(renderedText(instance, 0), /INSTRUCTIONS  r restart/);
});

test("steps memory.copy and memory.fill with memory provenance", async () => {
  const [debuggerBytes, targetBytes] = await Promise.all([
    readFile(debuggerPath),
    readFile(bulkMemoryPath),
  ]);
  const { instance } = await WebAssembly.instantiate(debuggerBytes, {});
  const debuggerInput = multipart([["component", targetBytes]]);
  const inputPointer = instance.exports.input_ptr();
  new Uint8Array(instance.exports.memory.buffer, inputPointer, debuggerInput.length).set(debuggerInput);
  renderedText(instance, debuggerInput.length);
  instance.exports.begin_update_at(1n);
  instance.exports.finish_update();
  const beforeFirstConstant = renderedText(instance, 0);
  assert.match(beforeFirstConstant, /^=> host passed no component input/m);
  assert.match(beforeFirstConstant, /^↓ {2}f\d+ .* i32\.const 18/m);
  assert.doesNotMatch(beforeFirstConstant, /──▶ next stack/);

  sendKey(instance, 2n, 0x73);
  sendKey(instance, 3n, 0x73);
  sendKey(instance, 4n, 0x73);
  const beforeCopyANSI = renderedANSI(instance, 0);
  const beforeCopy = stripANSI(beforeCopyANSI);
  assertTerminalWidth(beforeCopy);
  assert.match(beforeCopyANSI, /\x1b\[93mmemory\x1b\[92m\.copy\x1b\[0m/);
  assert.match(beforeCopy, /^=> f\d+ .* memory\.copy/m);
  assert.match(beforeCopy, /stack\[2\] i32 0x00000006/);
  assert.match(beforeCopy, /stack\[1\] i32 0x00000010/);
  assert.match(beforeCopy, /stack\[0\] i32 0x00000012/);
  assert.match(beforeCopy, /memory\.copy[\s\S]*──▶ dst 00000012\+6[\s\S]*src 00000010/);

  sendKey(instance, 5n, 0x73);
  sendKey(instance, 6n, 0x73);
  sendKey(instance, 7n, 0x73);
  sendKey(instance, 8n, 0x73);
  const beforeFill = renderedText(instance, 0);
  assert.match(beforeFill, /^=> f\d+ .* memory\.fill/m);
  assert.match(beforeFill, /memory\.fill[\s\S]*──▶ dst 00000020\+4[\s\S]*byte 34/);

  sendKey(instance, 9n, 0x73);
  sendKey(instance, 10n, 0x63);
  const completedANSI = renderedANSI(instance, 0);
  const completed = stripANSI(completedANSI);
  assert.match(completedANSI, /^\x1b\[1mqipdb\x1b\[0m  \x1b\[92m●\x1b\[0m/);
  assertTerminalWidth(completed);
  assert.match(completed, /OUTPUT succeeded size=4 ptr=0x00000020/);
  assert.match(completed, /MEMORY  64 KiB  pages=1  reads=1 writes=2/);
  assert.match(completedANSI, /reads=\x1b\[95m1\x1b\[0m writes=\x1b\[92m2\x1b\[0m/);
  assert.match(completed, /^  00000020  /m);
  assert.match(completedANSI, /\x1b\[1;4;92m34\x1b\[0m \x1b\[1;4;92m34\x1b\[0m \x1b\[1;4;92m34\x1b\[0m \x1b\[1;4;92m34\x1b\[0m /);

  sendKey(instance, 11n, 0x78);
  sendKey(instance, 12n, 0x72);
  const copiedMemory = renderedText(instance, 0);
  assert.match(copiedMemory, /^  00000010  /m);
  assert.match(copiedMemory, /00000010  61 62 61 62 63 64 65 66/);

  sendKey(instance, 13n, 0x78);
  sendKey(instance, 14n, 0x77);
  assert.match(renderedText(instance, 0), /^  00000020  /m);

  sendKey(instance, 15n, 0x72);
  const restarted = renderedText(instance, 0);
  assert.match(restarted, /MEMORY  64 KiB  pages=1  reads=0 writes=0/);
  assert.match(restarted, /00000010  61 62 63 64 65 66 00 00/);
});

test("step backward replays an uninterrupted step-into history", async () => {
  const [debuggerBytes, targetBytes] = await Promise.all([
    readFile(debuggerPath),
    readFile(targetPath),
  ]);
  const { instance } = await WebAssembly.instantiate(debuggerBytes, {});
  const debuggerInput = multipart([["component", targetBytes]]);
  const inputPointer = instance.exports.input_ptr();
  new Uint8Array(instance.exports.memory.buffer, inputPointer, debuggerInput.length).set(debuggerInput);
  renderedText(instance, debuggerInput.length);
  instance.exports.begin_update_at(1n);
  instance.exports.finish_update();

  sendKey(instance, 2n, 0xff54); // Down Arrow
  sendKey(instance, 3n, 0xff54); // Down Arrow
  const afterTwoStepsANSI = renderedANSI(instance, 0);
  assert.match(afterTwoStepsANSI, /\x1b\[1;97m↑\x1b\[0m/);
  assert.match(afterTwoStepsANSI, /\x1b\[1;97mr\x1b\[0m/);
  const afterTwoSteps = stripANSI(afterTwoStepsANSI);
  assert.match(afterTwoSteps, /^↑ {2}f\d+ .+\n=> f\d+/m);
  assert.doesNotMatch(afterTwoSteps, /Alt-\[ back/);
  sendKey(instance, 4n, 0xff54); // Down Arrow
  sendKey(instance, 5n, 0xff52); // Up Arrow: step backward.
  assert.equal(renderedText(instance, 0), afterTwoSteps);

  sendKey(instance, 6n, 0x6e); // n disables the s-only replay history.
  const afterNext = renderedText(instance, 0);
  assert.doesNotMatch(afterNext, /^↑/m);
  sendKey(instance, 7n, 0x5b, 1 | (1 << 4));
  assert.equal(renderedText(instance, 0), afterNext);

  sendKey(instance, 8n, 0x72); // r starts a fresh history.
  sendKey(instance, 9n, 0x73); // s
  sendKey(instance, 10n, 0x5b, 1 | (1 << 4));
  assert.match(renderedText(instance, 0), /qipdb  ●  i expand  \? help  WASM  274 B/);

  sendKey(instance, 11n, 0x66); // f
  const afterFinish = renderedText(instance, 0);
  const finishCount = Number(afterFinish.match(/qipdb  ●  i expand  \? help  executed=(\d+)/)?.[1]);
  assert.match(afterFinish, /INSTRUCTIONS  r restart/);
  assert.match(afterFinish, /^↑ {2}f\d+ .* end/m);
  sendKey(instance, 12n, 0x5b, 1 | (1 << 4)); // Alt/Option-[: undo the final instruction.
  const beforeFinish = renderedText(instance, 0);
  assert.match(beforeFinish, /^INSTRUCTIONS  Space run +STACKS\/LOCALS/m);
  assert.match(beforeFinish, new RegExp(`qipdb  ●  i expand  \\? help  executed=${finishCount - 1}`));

  sendKey(instance, 13n, 0x72); // r
  sendKey(instance, 14n, 0x63); // c reaches the same initial-frame result.
  assert.equal(renderedText(instance, 0), afterFinish);
  sendKey(instance, 15n, 0x5b, 1 | (1 << 4));
  assert.equal(renderedText(instance, 0), beforeFinish);
});

test("continue pauses and resumes an infinite component at command budgets", async () => {
  const [debuggerBytes, targetBytes] = await Promise.all([
    readFile(debuggerPath),
    readFile(infiniteLoopPath),
  ]);
  const { instance } = await WebAssembly.instantiate(debuggerBytes, {});
  const debuggerInput = multipart([["component", targetBytes]]);
  const inputPointer = instance.exports.input_ptr();
  new Uint8Array(instance.exports.memory.buffer, inputPointer, debuggerInput.length).set(debuggerInput);
  renderedText(instance, debuggerInput.length);
  instance.exports.begin_update_at(1n);
  instance.exports.finish_update();

  instance.exports.begin_update_at(2n);
  assert.equal(instance.exports.uniform_set_instruction_budget(0), 1);
  assert.equal(instance.exports.uniform_set_instruction_budget(0xffff_ffff), 1_000_000);
  assert.equal(instance.exports.finish_update(), 2n);

  sendKeyWithBudget(instance, 3n, 0x63, 7); // c
  const firstPauseANSI = renderedANSI(instance, 0);
  const firstPause = stripANSI(firstPauseANSI);
  assert.match(firstPauseANSI, /^\x1b\[1mqipdb\x1b\[0m  \x1b\[93m●\x1b\[0m/);
  assert.match(firstPause, /^INSTRUCTIONS  Space continue +STACKS\/LOCALS/m);
  assert.match(firstPause, /qipdb  ●  i expand  \? help  executed=7/);
  assert.match(firstPause, /Space continue/);
  assert.match(firstPause, /paused: 7-instruction budget/);
  assert.doesNotMatch(firstPause, /trap/);

  sendKeyWithBudget(instance, 4n, 0x20, 11); // Space: another independent budget.
  const secondPause = renderedText(instance, 0);
  assert.match(secondPause, /^INSTRUCTIONS  Space continue +STACKS\/LOCALS/m);
  assert.match(secondPause, /qipdb  ●  i expand  \? help  executed=18/);
  assert.match(secondPause, /paused: 11-instruction budget/);

  sendKey(instance, 5n, 0x73); // s: one instruction clears the budget pause.
  const afterStep = renderedText(instance, 0);
  assert.match(afterStep, /^INSTRUCTIONS  Space run +STACKS\/LOCALS/m);
  assert.match(afterStep, /qipdb  ●  i expand  \? help  executed=19/);
  assert.doesNotMatch(afterStep, /paused:/);
});

test("memory examine shortcuts retain the last read and write separately", async () => {
  const [debuggerBytes, targetBytes] = await Promise.all([
    readFile(debuggerPath),
    readFile(targetPath),
  ]);
  const { instance } = await WebAssembly.instantiate(debuggerBytes, {});
  const debuggerInput = multipart([
    ["component", targetBytes],
    ["input", Buffer.from("QIP")],
  ]);
  const inputPointer = instance.exports.input_ptr();
  new Uint8Array(instance.exports.memory.buffer, inputPointer, debuggerInput.length).set(debuggerInput);
  renderedText(instance, debuggerInput.length);
  instance.exports.begin_update_at(1n);
  instance.exports.finish_update();

  sendKey(instance, 2n, 0x63); // c
  sendKey(instance, 3n, 0x78); // x
  const memoryPrompt = renderedText(instance, 0);
  assertTerminalWidth(memoryPrompt);
  assert.match(memoryPrompt, /r last-read  w last-write/);
  sendKey(instance, 4n, 0x77); // w: final store8 destination.
  const lastWriteANSI = renderedANSI(instance, 0);
  assert.match(stripANSI(lastWriteANSI), /^  0001ffd0  /m);
  assert.match(stripANSI(lastWriteANSI), /^  0001fff0  /m);
  assert.match(stripANSI(lastWriteANSI), /^  00020000  /m);
  assert.match(lastWriteANSI, /\x1b\[1;4;92m50\x1b\[0m /);
  assert.match(lastWriteANSI, /\x1b\[1;4;92mP\x1b\[0m/);
  assert.doesNotMatch(stripANSI(lastWriteANSI), /last write|\^\^/);
  sendKey(instance, 5n, 0x78); // x
  sendKey(instance, 6n, 0x72); // r: final load8_u source.
  const lastReadANSI = renderedANSI(instance, 0);
  assert.match(stripANSI(lastReadANSI), /^  0000ffd0  /m);
  assert.match(stripANSI(lastReadANSI), /^  0000fff0  /m);
  assert.match(stripANSI(lastReadANSI), /^  00010000  /m);
  assert.match(lastReadANSI, /\x1b\[4;95m50\x1b\[0m /);
  assert.match(lastReadANSI, /\x1b\[4;95mP\x1b\[0m/);
  assert.doesNotMatch(stripANSI(lastReadANSI), /last read|\^\^/);

  sendKey(instance, 7n, 0x72); // r outside x still restarts.
  sendKey(instance, 8n, 0x78); // x
  assert.doesNotMatch(renderedText(instance, 0), /last-read|last-write/);
});

test("multipart input reaches the target component and survives restart", async () => {
  const [debuggerBytes, targetBytes] = await Promise.all([
    readFile(debuggerPath),
    readFile(wcPath),
  ]);
  const targetInput = Buffer.from("one two\n");
  const debuggerInput = multipart([
    ["component", targetBytes],
    ["input", targetInput],
  ]);
  const { instance } = await WebAssembly.instantiate(debuggerBytes, {});
  const inputPointer = instance.exports.input_ptr();
  new Uint8Array(instance.exports.memory.buffer, inputPointer, debuggerInput.length).set(debuggerInput);

  const initialANSI = renderedANSI(instance, debuggerInput.length);
  const initial = stripANSI(initialANSI);
  assert.equal(instance.exports.target_input_ptr(), 0x100000);
  assert.match(initial, /param\[0\] 0x0000000000000008/);
  assert.match(initial, /WASM  645 B  QIP content component  UTF-8 → UTF-8$/m);
  assert.doesNotMatch(initial, /input=8 B/);
  assert.match(initial, /^=> host wrote 8 B input at 0x00100000/m);
  assert.match(initial, /qipdb  ●  i expand  \? help  WASM  645 B  QIP content component/);
  assert.match(initial, /^  00100000  /m);
  assert.match(initial, /\|one two\.\.{8}\|/);
  assert.match(initialANSI, /\x1b\[4;34m6f\x1b\[0m \x1b\[4;34m6e\x1b\[0m /);
  assert.match(initialANSI, /\x1b\[4;34mone two\.\x1b\[0m/);
  assert.doesNotMatch(initialANSI, /\x1b\[4;34m6f /);
  assert.match(initialANSI, /\x1b\[2m00 00 00 00/);
  assert.match(initial, /global\[0\] 0x0000000000100000\n[^\n]*stack pointer \(inferred\)/);
  assert.match(initial, /global\.get 0  stack pointer/);
  assert.match(initial, /global\.set 0  allocate 16 B/);
  assert.equal(executionRowCount(initial), 11);

  sendKey(instance, 2n, 0x73); // s: global.get
  const afterFirstStepANSI = renderedANSI(instance, 0);
  assert.equal(executionRowCount(stripANSI(afterFirstStepANSI)), 11);
  assert.match(afterFirstStepANSI, /\x1b\[34m6f 6e 65 20 74 77 6f 0a /);
  assert.doesNotMatch(afterFirstStepANSI, /\x1b\[4;34m/);
  sendKey(instance, 3n, 0x73); // s: i32.const
  sendKey(instance, 4n, 0x73); // s: i32.sub, landing on local.tee
  const teeANSI = renderedANSI(instance, 0);
  assert.match(teeANSI, /\x1b\[34mlocal\x1b\[92m\.tee\x1b\[0m\x1b\[4m 1\x1b\[0m/);
  assert.match(teeANSI, /\x1b\[34mglobal\x1b\[92m\.set\x1b\[0m 0\x1b\[0m/);
  assert.match(teeANSI, /local\[0\] \x1b\[94m0x0000000000000000\x1b\[0m/);
  assert.match(teeANSI, /\x1b\[92m┌─▶ \x1b\[0m\x1b\[92mnext local\[0\] i32 \x1b\[94m0x000ffff0\x1b\[0m/);
  assert.match(teeANSI, /\x1b\[92m└─ {2}\x1b\[0m\x1b\[92mstack\[0\] i32 0x000ffff0\x1b\[0m/);
  assertTerminalWidth(stripANSI(teeANSI));
  sendKey(instance, 5n, 0x73); // s: write local[0]
  const globalSetANSI = renderedANSI(instance, 0);
  assert.match(globalSetANSI, /\x1b\[1;92mlocal\[0\] 0x00000000000ffff0\x1b\[0m/);
  assert.match(globalSetANSI, /global\[0\] \x1b\[94m0x0000000000100000\x1b\[0m/);
  assert.match(globalSetANSI, /\x1b\[92m┌▶\x1b\[0m\x1b\[92mnext global\[0\] i32 \x1b\[94m0x000ffff0\x1b\[0m/);
  assert.match(globalSetANSI, /\x1b\[92m└─ {2}\x1b\[0m\x1b\[92mstack\[0\] i32 0x000ffff0\x1b\[0m/);
  assertTerminalWidth(stripANSI(globalSetANSI));
  sendKey(instance, 6n, 0x73); // s: write global[0]
  assert.match(renderedANSI(instance, 0), /\x1b\[1;92mglobal\[0\] 0x00000000000ffff0\x1b\[0m/);
  sendKey(instance, 7n, 0x72); // r

  for (let time = 8n; time <= 17n; time++) sendKey(instance, time, 0x73); // s to select.
  const selectANSI = renderedANSI(instance, 0);
  const selectText = stripANSI(selectANSI);
  assert.match(selectANSI, /\x1b\[36mselect\x1b\[0m/);
  assert.match(selectANSI, /\x1b\[36m├─ {2}\x1b\[0m\x1b\[36mstack\[2\] i32 0x00000001\x1b\[0m/);
  assert.match(selectANSI, /\x1b\[36m├─ {2}\x1b\[0m\x1b\[36mstack\[1\] i32 0x00400000\x1b\[0m/);
  assert.match(selectANSI, /\x1b\[36m┌─ {2}\x1b\[0m\x1b\[4;94mstack\[0\] i32 0x00000008\x1b\[0m/);
  assert.match(selectText, /├─ {2}select[^\n]*\n[^\n]*└─▶ next stack\[0\] i32 0x00000008/);
  assertTerminalWidth(selectText);

  const nativeTarget = (await WebAssembly.instantiate(targetBytes, {})).instance;
  new Uint8Array(
    nativeTarget.exports.memory.buffer,
    nativeTarget.exports.input_ptr(),
    targetInput.length,
  ).set(targetInput);
  const expectedResult = BigInt.asUintN(64, nativeTarget.exports.render(targetInput.length));
  const expectedPacked = expectedResult.toString(16).padStart(16, "0");
  const expectedPointer = Number((expectedResult >> 32n) & 0x7fff_ffffn);
  const expectedMemoryView = new RegExp(`^  ${expectedPointer.toString(16).padStart(8, "0")}  `, "m");

  sendKey(instance, 18n, 0x72); // r
  sendKey(instance, 19n, 0x63); // c
  const firstCompleted = renderedText(instance, 0);
  assert.match(firstCompleted, new RegExp(`packed=0x${expectedPacked}`));
  assert.match(firstCompleted, expectedMemoryView);
  sendKey(instance, 20n, 0x72); // r
  assert.match(renderedText(instance, 0), /param\[0\] 0x0000000000000008/);
  sendKey(instance, 21n, 0x63); // c
  const secondCompleted = renderedText(instance, 0);
  assert.match(secondCompleted, new RegExp(`packed=0x${expectedPacked}`));
  assert.match(secondCompleted, expectedMemoryView);

  sendKey(instance, 22n, 0x72); // r
  let restoration = "";
  for (let step = 0; step < 500; step++) {
    restoration = renderedText(instance, 0);
    if (restoration.includes("restore 16 B")) break;
    sendKey(instance, BigInt(23 + step), 0x6e); // n: keep calls collapsed.
  }
  assert.match(restoration, /global\.set 0  restore 16 B/);
});

test("Go qip and Node qipx feed the same multipart debugger input", () => {
  const input = Buffer.from("one two\n");
  const args = [
    "run",
    "--form", `component=@${wcPath}`,
    "--form", "input=@-",
    debuggerPath,
  ];
  const go = spawnSync("./qip", args, { input });
  assert.equal(go.status, 0, go.stderr.toString());
  const node = spawnSync(process.execPath, ["npm/qipx/cli.mjs", ...args], { input });
  assert.equal(node.status, 0, node.stderr.toString());
  assert.deepEqual(node.stdout, go.stdout);
  assert.match(stripANSI(go.stdout.toString()), /param\[0\] 0x0000000000000008/);
});
