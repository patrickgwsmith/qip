import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { decodeRenderResult } from "./lib/content-component-host.mjs";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function readI32Export(exports, name) {
  const value = exports[name];
  return typeof value === "function" ? value() : value.value;
}

async function load(path) {
  return (await WebAssembly.instantiate(await readFile(path), {})).instance.exports;
}

function writeInput(exports, text) {
  const bytes = encoder.encode(text);
  const ptr = readI32Export(exports, "input_ptr");
  assert.ok(bytes.length <= readI32Export(exports, "input_utf8_cap"));
  new Uint8Array(exports.memory.buffer, ptr, bytes.length).set(bytes);
  return bytes.length;
}

function render(exports, text) {
  const result = decodeRenderResult(exports.render(writeInput(exports, text)));
  assert.equal(result.failed, false);
  return decoder.decode(new Uint8Array(exports.memory.buffer, result.outputPointer, result.value));
}

test("css-minify preserves whitespace required by CSS math", async () => {
  const exports = await load("text/css/css-minify.wasm");
  assert.equal(
    render(exports, ".x { width: calc(100% - 1rem); height: min(1px + 2px, 4px); --pair: red blue; }"),
    ".x{width:calc(100% - 1rem);height:min(1px + 2px,4px);--pair:red blue}",
  );
});

test("autolink-https respects HTML literal contexts and URL punctuation", async () => {
  const exports = await load("text/html/autolink-https.wasm");
  assert.equal(
    render(exports, "<p>See https://example.com/path).</p>"),
    '<p>See <a href="https://example.com/path">https://example.com/path</a>).</p>',
  );
  assert.equal(
    render(exports, "HTTPS://example.com/a_(b)."),
    '<a href="HTTPS://example.com/a_(b)">HTTPS://example.com/a_(b)</a>.',
  );
  const literal = '<a href="https://example.com">https://example.com</a><code>https://code.example</code><pre>https://pre.example</pre><textarea>https://text.example</textarea><script>"https://script.example"</script><style>/* https://style.example */</style>';
  assert.equal(render(exports, literal), literal);
});

test("html-wcag-contrast-aa uses the document cascade and HTML void elements", async () => {
  const exports = await load("text/html/html-wcag-contrast-aa.wasm");
  const pass = '<p id="message" class="muted">Readable</p><style>#message{color:#111}.muted{color:#aaa;background:#fff}</style>';
  assert.equal(render(exports, pass), pass);

  const lowContrast = '<p class="muted">Unreadable</p><style>.muted{color:#aaa;background:#fff}</style>';
  assert.throws(() => render(exports, lowContrast), WebAssembly.RuntimeError);

  const largeText = '<p style="font-size:24px;color:#888;background:#fff">Large readable text</p>';
  assert.equal(render(exports, largeText), largeText);
  const boldLargeText = '<p style="font-size:14pt;font-weight:700;color:#888;background:#fff">Large bold text</p>';
  assert.equal(render(exports, boldLargeText), boldLargeText);
  const normalText = '<p style="font-size:16px;color:#888;background:#fff">Small unreadable text</p>';
  assert.throws(() => render(exports, normalText), WebAssembly.RuntimeError);

  const voidElement = '<div style="color:#aaa;background:#fff"><br></div><p>Readable</p>';
  assert.equal(render(exports, voidElement), voidElement);

  const slashOnOrdinaryElement = '<div style="color:#aaa;background:#fff"/>Unreadable</div>';
  assert.throws(() => render(exports, slashOnOrdinaryElement), WebAssembly.RuntimeError);
});

test("html-wcag-contrast-aa matches compound, descendant, attribute, root, and nested selectors", async () => {
  const exports = await load("text/html/html-wcag-contrast-aa.wasm");
  const html = `<style>
    :root { color: #aaa; background: #fff; }
    section.card[data-tone="SAFE" i] {
      .Label.notice[data-kind~="warning"][data-code^="pre"][data-code$="fix"][data-code*="ref"][lang|="en"][data-present] { color: #111; background: #fff; }
    }
    article.panel {
      &.active {
        .copy { color: #111; background: #fff; }
      }
    }
    article[type="button"] .type-copy { color: #111; background: #fff; }
    article[type="button" s] .type-copy { color: #aaa; background: #fff; }
    #panel .Label[data-kind] { color: #aaa; background: #fff; }
    #Panel .label[data-kind] { color: #aaa; background: #fff; }
    #Panel [data-tone="SAFE"] .Label { color: #aaa; background: #fff; }
    #Panel[data-tone="SAFE" s] .Label { color: #aaa; background: #fff; }
  </style><html><body><section id="Panel" class="card" data-tone="safe"><p class="Label notice" data-kind="urgent warning" data-code="prereffix" lang="en-AU" data-present>Readable</p></section><article class="panel active"><p class="copy">Also readable</p></article><article type="BUTTON"><p class="type-copy">Case-insensitive HTML attribute</p></article></body></html>`;
  assert.equal(render(exports, html), html);

  const descendantMiss = `<style>:root{color:#111;background:#fff}.shell .target{color:#aaa;background:#fff}</style><html><body><p class="target">Readable</p></body></html>`;
  assert.equal(render(exports, descendantMiss), descendantMiss);
});
