import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { decodeRenderResult } from "./lib/content-component-host.mjs";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const wasm = await readFile("text/youtube-id-extractor.wasm");

async function load() {
  return (await WebAssembly.instantiate(wasm, {})).instance.exports;
}

function readI32Export(exports, name) {
  const value = exports[name];
  return typeof value === "function" ? value() : value.value;
}

function render(exports, text) {
  const input = encoder.encode(text);
  assert.ok(input.byteLength <= readI32Export(exports, "input_utf8_cap"));
  const inputPointer = readI32Export(exports, "input_ptr");
  new Uint8Array(exports.memory.buffer, inputPointer, input.byteLength).set(input);

  const result = decodeRenderResult(exports.render(input.byteLength));
  assert.equal(result.failed, false);
  return decoder.decode(
    new Uint8Array(exports.memory.buffer, result.outputPointer, result.value),
  );
}

test("youtube-id-extractor accepts supported URL forms", async () => {
  const exports = await load();
  assert.equal(
    render(
      exports,
      [
        "https://youtu.be/dQw4w9WgXcQ.",
        "https://www.youtube.com:443/watch?v=9bZkp7q19f0",
        "https://youtube-nocookie.com/embed/3JZ_D3ELwOQ",
        "https://m.youtube.com/shorts/L_jWHffIx5E",
        "youtube.com/live/kJQP7kiw5Fk",
        "music.youtube.com/watch?v=Zi_XLOBDo_Y",
      ].join(" "),
    ),
    "dQw4w9WgXcQ\n9bZkp7q19f0\n3JZ_D3ELwOQ\nL_jWHffIx5E\nkJQP7kiw5Fk\nZi_XLOBDo_Y",
  );
});

test("youtube-id-extractor rejects malformed URLs and lookalike hosts", async () => {
  const exports = await load();
  assert.equal(
    render(
      exports,
      [
        "https://youtu.be/dQw4w9WgXcQ.jpg",
        "https://youtube.com/watch?v=dQw4w9WgXcQ%20junk",
        "https://youtube.com:not-a-port/watch?v=dQw4w9WgXcQ",
        "https://youtube.com:65536/watch?v=dQw4w9WgXcQ",
        "https://youtube.com.example/watch?v=dQw4w9WgXcQ",
      ].join(" "),
    ),
    "",
  );
});
