import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });
const header = "path,input_encoding,input_mime,input_capacity_bytes,output_encoding,output_mime,output_capacity_bytes";

async function generate(csv) {
  const module = await WebAssembly.compile(await readFile(join(
    root,
    "text/csv/content-recipe-to-browser-javascript.wasm",
  )));
  const exports = new WebAssembly.Instance(module, {}).exports;
  const input = encoder.encode(csv);
  assert.ok(input.length <= exports.input_utf8_cap());
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.length).set(input);
  const outputLength = qipRenderSize(exports, input.length);
  return decoder.decode(new Uint8Array(exports.memory.buffer, qipRenderedOutputPointer(exports), outputLength));
}

test("generated browser JavaScript runs a multi-component recipe", async () => {
  const csv = `${header}\n` +
    "/image/svg+xml/svg-to-data-uri.wasm,utf8,image/svg+xml,20473,utf8,text/uri-list,61440\n" +
    "/text/uri-list/data-uri-to-css-url.wasm,utf8,text/uri-list,20477,utf8,text/plain,61440\n";
  const javascript = await generate(csv);

  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (source) => {
    const path = String(source);
    assert.ok(path.startsWith("/"));
    return new Response(await readFile(join(root, path.slice(1))), {
      headers: { "Content-Type": "application/wasm" },
    });
  };
  try {
    const sourceURL = `data:text/javascript;base64,${Buffer.from(javascript).toString("base64")}`;
    const recipe = await import(sourceURL);
    assert.equal(
      recipe.render('<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0"/></svg>'),
      'url("data:image/svg+xml,%3Csvg%20xmlns=%22http://www.w3.org/2000/svg%22%3E%3Cpath%20d=%22M0%200%22/%3E%3C/svg%3E")',
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("generator traps on a disconnected recipe", async () => {
  const csv = `${header}\n` +
    "/one.wasm,utf8,text/markdown,10,utf8,text/html,20\n" +
    "/two.wasm,utf8,text/plain,20,utf8,text/html,30\n";
  await assert.rejects(generate(csv), WebAssembly.RuntimeError);
});
