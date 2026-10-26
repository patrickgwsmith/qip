import { decodeRenderResult } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const wasmBytes = await readFile(
  new URL("../application/warc/warc-check-broken-links.wasm", import.meta.url),
);

const MISSING_RESOURCE = 0;
const ERROR_STATUS = 1;
const MISSING_FRAGMENT = 2;
const INVALID_URL = 3;
const MALFORMED_WARC = 4;

function response(target, body, status = "200 OK", contentType = "text/html") {
  const payload = Buffer.from(`HTTP/1.1 ${status}\r\nContent-Type: ${contentType}\r\n\r\n${body}`);
  return Buffer.concat([
    Buffer.from(
      "WARC/1.1\r\n" +
        "WARC-Type: response\r\n" +
        `WARC-Target-URI: ${target}\r\n` +
        "Content-Type: application/http; msgtype=response\r\n" +
        `Content-Length: ${payload.length}\r\n\r\n`,
    ),
    payload,
    Buffer.from("\r\n\r\n"),
  ]);
}

async function instantiate() {
  const { instance } = await WebAssembly.instantiate(wasmBytes);
  return instance.exports;
}

function render(wasm, input) {
  new Uint8Array(wasm.memory.buffer, wasm.input_ptr(), input.length).set(input);
  const result = decodeRenderResult(wasm.render(input.length));
  if (result.failed) {
    const modes = wasm.failure_modes_per_input_offset();
    return { inputOffset: Math.floor(result.value / modes), mode: result.value % modes };
  }
  return { output: Buffer.from(new Uint8Array(wasm.memory.buffer, result.outputPointer, result.value)) };
}

test("declares five failure modes per input offset", async () => {
  const wasm = await instantiate();
  assert.equal(wasm.failure_modes_per_input_offset(), 5);
});

test("returns the archive unchanged when every internal link resolves", async () => {
  const input = Buffer.concat([
    response("https://qip.dev/", '<a href="/about#team">Team</a><a href="https://example.com/x">External</a>'),
    response("https://qip.dev/about", '<h2 id="team">Team</h2>'),
  ]);
  const result = render(await instantiate(), input);
  assert.deepEqual(result.output, input);
});

for (const [name, pages, needle, mode] of [
  ["a missing page", [response("https://qip.dev/", '<a href="/nope">x</a>')], "/nope", MISSING_RESOURCE],
  [
    "a page with an error status",
    [
      response("https://qip.dev/", '<img src="/gone.png">'),
      response("https://qip.dev/gone.png", "", "404 Not Found", "image/png"),
    ],
    "/gone.png",
    ERROR_STATUS,
  ],
  [
    "a missing fragment",
    [response("https://qip.dev/", '<h1 id="intro">Hi</h1><a href="#outro">x</a>')],
    "#outro",
    MISSING_FRAGMENT,
  ],
  ["an unresolvable link", [response("https://qip.dev/", '<a href="https:/qip.dev">x</a>')], "https:/qip.dev", INVALID_URL],
]) {
  test(`rejects ${name} at the link's attribute value`, async () => {
    const input = Buffer.concat(pages);
    const result = render(await instantiate(), input);
    assert.deepEqual(result, { inputOffset: input.indexOf(needle), mode });
  });
}

test("reports the first broken link in archive order", async () => {
  const input = Buffer.concat([
    response("https://qip.dev/", '<a href="/first">1</a><a href="/second">2</a>'),
    response("https://qip.dev/other", '<a href="/third">3</a>'),
  ]);
  const result = render(await instantiate(), input);
  assert.deepEqual(result, { inputOffset: input.indexOf("/first"), mode: MISSING_RESOURCE });
});

test("rejects a truncated WARC record at its start", async () => {
  const valid = response("https://qip.dev/", "<p>ok</p>");
  const input = Buffer.concat([valid, Buffer.from("WARC/1.1\r\nContent-Length: 500\r\n\r\nshort")]);
  const result = render(await instantiate(), input);
  assert.deepEqual(result, { inputOffset: valid.length, mode: MALFORMED_WARC });
});

test("accepts valid input on the same instance after a rejection", async () => {
  const wasm = await instantiate();
  const broken = response("https://qip.dev/", '<a href="/nope">x</a>');
  assert.equal(render(wasm, broken).mode, MISSING_RESOURCE);
  const fixed = response("https://qip.dev/", '<a href="/">home</a>');
  assert.deepEqual(render(wasm, fixed).output, fixed);
});
