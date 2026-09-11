import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const wasmBytes = await readFile(
  new URL("../application/warc/warc-text-uri-list-to-redirect.wasm", import.meta.url),
);

function response(target, contentType, body, extraHeaders = "") {
  const payload = Buffer.from(
    "HTTP/1.1 200 OK\r\n" +
      `Content-Type: ${contentType}\r\n` +
      extraHeaders +
      `Content-Length: ${Buffer.byteLength(body)}\r\n\r\n` +
      body,
  );
  return Buffer.concat([
    Buffer.from(
      "WARC/1.1\r\n" +
        "WARC-Type: response\r\n" +
        `WARC-Target-URI: ${target}\r\n` +
        "WARC-Date: 2000-01-01T00:00:00Z\r\n" +
        "WARC-Record-ID: <urn:uuid:00000000-0000-4000-8000-000000000001>\r\n" +
        "Content-Type: application/http; msgtype=response\r\n" +
        `Content-Length: ${payload.length}\r\n\r\n`,
    ),
    payload,
    Buffer.from("\r\n\r\n"),
  ]);
}

async function transform(input) {
  const { instance } = await WebAssembly.instantiate(wasmBytes);
  const wasm = instance.exports;
  new Uint8Array(wasm.memory.buffer, wasm.input_ptr(), input.length).set(input);
  const outputLength = qipRenderSize(wasm, input.length);
  return Buffer.from(new Uint8Array(wasm.memory.buffer, qipRenderedOutputPointer(wasm), outputLength));
}

function firstHTTPPayload(warc) {
  const warcHeaderEnd = warc.indexOf("\r\n\r\n");
  assert.notEqual(warcHeaderEnd, -1);
  const header = warc.subarray(0, warcHeaderEnd).toString();
  const length = Number(/^Content-Length: (\d+)\r?$/m.exec(header)?.[1]);
  assert.ok(Number.isSafeInteger(length));
  return warc.subarray(warcHeaderEnd + 4, warcHeaderEnd + 4 + length);
}

test("turns the first non-comment URI into a 302 response", async () => {
  const input = response(
    "http://qip.local/old",
    "text/uri-list; charset=utf-8",
    "\uFEFF# moved\r\n\r\n  /new-location  \r\n/ignored\r\n",
    'ETag: "stale"\r\nX-Test: kept\r\n',
  );
  const payload = firstHTTPPayload(await transform(input));
  assert.match(payload.toString(), /^HTTP\/1\.1 302 Found\r\n/);
  assert.match(payload.toString(), /\r\nLocation: \/new-location\r\n/);
  assert.match(payload.toString(), /\r\nX-Test: kept\r\n/);
  assert.match(payload.toString(), /\r\nContent-Length: 0\r\n\r\n$/);
  assert.doesNotMatch(payload.toString(), /\r\n(?:Content-Type|ETag):/);
});

test("rewrites every URI-list response in a WARC", async () => {
  const input = Buffer.concat([
    response("http://qip.local/one", "text/uri-list", "/first\n"),
    response("http://qip.local/plain", "text/plain", "kept"),
    response("http://qip.local/two", "text/uri-list", "/second\n"),
  ]);
  const output = await transform(input);
  assert.equal((output.toString().match(/HTTP\/1\.1 302 Found/g) || []).length, 2);
  assert.match(output.toString(), /HTTP\/1\.1 200 OK[\s\S]*kept/);
});

test("leaves a canonical non-URI-list WARC byte-identical", async () => {
  const input = response("http://qip.local/plain", "text/plain", "/not-a-redirect");
  assert.deepEqual(await transform(input), input);
});

test("traps when a URI list has no target", async () => {
  const input = response("http://qip.local/old", "text/uri-list", "# only a comment\n \n");
  await assert.rejects(() => transform(input), /unreachable/);
});
