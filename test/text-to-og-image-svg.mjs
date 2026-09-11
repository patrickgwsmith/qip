import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const componentPath =
  "text/text-to-og-image-svg-dejavu-sans-mono.wasm";

async function instantiate() {
  const { instance } = await WebAssembly.instantiate(
    await readFile(componentPath),
    {},
  );
  return instance;
}

function form(title, subtitle = "") {
  return new URLSearchParams({ title, subtitle }).toString();
}

function render(instance, fields) {
  const input = Buffer.from(fields);
  assert.ok(input.length <= instance.exports.input_utf8_cap());
  new Uint8Array(
    instance.exports.memory.buffer,
    instance.exports.input_ptr(),
    input.length,
  ).set(input);
  const outputSize = qipRenderSize(instance.exports, input.length);
  return Buffer.from(
    new Uint8Array(
      instance.exports.memory.buffer,
      qipRenderedOutputPointer(instance.exports),
      outputSize,
    ),
  ).toString("utf8");
}

test("renders a left-aligned title and smaller subtitle with configurable colors", async () => {
  const instance = await instantiate();
  const inputContentType = Buffer.from(
    instance.exports.memory.buffer,
    instance.exports.input_content_type_ptr(),
    instance.exports.input_content_type_size(),
  ).toString("utf8");
  assert.equal(inputContentType, "application/x-www-form-urlencoded");
  assert.equal(
    instance.exports.uniform_set_text_color_rgba(0xffffffff) >>> 0,
    0xffffffff,
  );
  assert.equal(
    instance.exports.uniform_set_background_color_rgba(0x4b2e83ff),
    0x4b2e83ff,
  );
  assert.equal(instance.exports.uniform_set_font_weight(700), 700);

  const svg = render(
    instance,
    form(
      "Reusable fonts make Open Graph images easier to recognize and share",
      "A smaller supporting line",
    ),
  );
  assert.match(svg, /^<svg [^>]*width="1200" height="630"/);
  assert.match(svg, /<rect [^>]*fill="#4b2e83"\/\>/);
  assert.match(svg, /<g fill="#ffffff" [^>]*data-role="title"[^>]*data-font-weight="700"/);
  assert.match(svg, /data-role="subtitle"[^>]*data-font-weight="400"/);
  assert.ok((svg.match(/translate\(96\.000 /g) ?? []).length >= 2);
  assert.ok((svg.match(/translate\(/g) ?? []).length > 20);

  const lineBaselines = new Set(
    [...svg.matchAll(/translate\([^ ]+ ([^)]+)\)/g)].map((match) => match[1]),
  );
  assert.ok(lineBaselines.size >= 2, "expected the title to wrap");
  assert.match(svg, /<path d="[^"]+" transform="translate\(/);
  assert.doesNotMatch(svg, /<text\b|[\s<]font-family=/);
});

test("selects regular outlines and preserves alpha in colors", async () => {
  const instance = await instantiate();
  assert.equal(instance.exports.uniform_set_font_weight(400), 400);
  assert.equal(instance.exports.uniform_set_font_max_size(64), 64);
  assert.equal(instance.exports.uniform_set_font_size, undefined);
  instance.exports.uniform_set_text_color_rgba(0x11223344);
  instance.exports.uniform_set_background_color_rgba(0xaabbccff);
  const svg = render(instance, form("Café & jalapeño!", "Crème brûlée"));
  assert.match(svg, /<rect [^>]*fill="#aabbcc"\/\>/);
  assert.match(svg, /<g fill="#11223344" [^>]*data-font-weight="400"/);
  const renderedSize = Number(svg.match(/data-role="title"[^>]*data-font-size="(\d+)"/)[1]);
  assert.ok(renderedSize <= 64);
});

test("traps on punctuation outside the embedded Latin-1 tables", async () => {
  const instance = await instantiate();
  assert.throws(() => render(instance, form("An em dash — is not Latin-1")));
});

test("requires a title and rejects malformed form data", async () => {
  let instance = await instantiate();
  assert.doesNotThrow(() => render(instance, form("", "Subtitle without a title")));
  assert.doesNotThrow(() => render(instance, form("", "")));
  assert.throws(() => render(instance, "subtitle=Only"));
  instance = await instantiate();
  assert.throws(() => render(instance, "title=Bad%2"));
});

test("uniforms reset to authored defaults after render", async () => {
  const instance = await instantiate();
  instance.exports.uniform_set_text_color_rgba(0x11223344);
  instance.exports.uniform_set_background_color_rgba(0xaabbccff);
  instance.exports.uniform_set_font_weight(400);
  instance.exports.uniform_set_font_max_size(64);
  const configured = render(instance, form("A"));
  assert.match(configured, /fill="#aabbcc"/);
  assert.match(configured, /fill="#11223344"/);
  assert.match(configured, /data-font-weight="400"/);
  assert.match(configured, /data-font-size="64"/);

  const defaults = render(instance, form("A"));
  assert.match(defaults, /fill="#eecc33"/);
  assert.match(defaults, /fill="#101010"/);
  assert.match(defaults, /data-font-weight="700"/);
  assert.match(defaults, /data-font-size="112"/);
});

test("font_max_size remains a ceiling while auto-fit can select less", async () => {
  const instance = await instantiate();
  assert.equal(instance.exports.uniform_set_font_max_size(64), 64);
  assert.equal(instance.exports.uniform_set_font_max_size(999), 160);
  assert.equal(instance.exports.uniform_set_font_max_size(64), 64);
  assert.equal(instance.exports.uniform_set_font_size, undefined);
  const svg = render(instance, form(
    "A deliberately long title that must wrap and shrink below its configured ceiling ".repeat(5),
    "Maximum means maximum, not a fixed size.",
  ));
  const renderedSize = Number(svg.match(/data-role="title"[^>]*data-font-size="(\d+)"/)[1]);
  assert.ok(renderedSize < 64);
});
