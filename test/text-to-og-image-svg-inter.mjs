import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const componentPath = "text/text-to-og-image-svg-inter.wasm";

async function instantiate() {
  const { instance } = await WebAssembly.instantiate(
    await readFile(componentPath),
    {},
  );
  return instance;
}

function render(instance, text) {
  const input = Buffer.from(text);
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

function form(title, subtitle) {
  const fields = new URLSearchParams({ title });
  if (subtitle !== undefined) fields.set("subtitle", subtitle);
  return fields.toString();
}

function firstTwoXPositions(svg) {
  return [...svg.matchAll(/translate\(([^ ]+) [^)]+\)/g)]
    .slice(0, 2)
    .map((match) => Number(match[1]));
}

test("renders a left-aligned Inter title and smaller subtitle", async () => {
  const instance = await instantiate();
  instance.exports.uniform_set_text_color_rgba(0xffffffff);
  instance.exports.uniform_set_background_color_rgba(0x4b2e83ff);
  const svg = render(
    instance,
    form(
      "Inter makes beautifully spaced Open Graph titles",
      "Proportional paths and kerning, without an external font dependency.",
    ),
  );

  const inputContentType = Buffer.from(
    new Uint8Array(
      instance.exports.memory.buffer,
      instance.exports.input_content_type_ptr(),
      instance.exports.input_content_type_size(),
    ),
  ).toString("utf8");
  assert.equal(inputContentType, "application/x-www-form-urlencoded");
  assert.match(svg, /^<svg [^>]*width="1200" height="630"/);
  assert.match(svg, /<rect [^>]*fill="#4b2e83"\/\>/);
  assert.match(svg, /data-role="title"[^>]*data-font-weight="700"/);
  assert.match(svg, /data-role="subtitle"[^>]*data-font-weight="400"/);
  assert.ok((svg.match(/translate\(96\.000 /g) ?? []).length >= 2);
  const titleSize = Number(svg.match(/data-role="title"[^>]*data-font-size="(\d+)"/)[1]);
  const subtitleSize = Number(svg.match(/data-role="subtitle"[^>]*data-font-size="(\d+)"/)[1]);
  assert.ok(titleSize > subtitleSize);
  assert.doesNotMatch(svg, /<text\b|[\s<]font-family=/);
});

test("uses proportional advances and Inter pair kerning", async () => {
  const instance = await instantiate();
  instance.exports.uniform_set_font_weight(400);
  assert.equal(instance.exports.uniform_set_font_max_size(112), 112);
  const [aInAv, vInAv] = firstTwoXPositions(render(instance, form("AV")));
  instance.exports.uniform_set_font_weight(400);
  instance.exports.uniform_set_font_max_size(112);
  const [aInAa, secondA] = firstTwoXPositions(render(instance, form("AA")));
  assert.ok(vInAv - aInAv < secondA - aInAa, "expected AV kerning to tighten the pair");

  instance.exports.uniform_set_font_weight(400);
  instance.exports.uniform_set_font_max_size(112);
  const [i, w] = firstTwoXPositions(render(instance, form("iW")));
  assert.ok(w - i < secondA - aInAa, "expected the narrow i advance to be proportional");
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

test("supports common title punctuation and rejects unsupported scripts", async () => {
  let instance = await instantiate();
  assert.doesNotThrow(() => render(instance, form("“Clear”—fast… €42™", "A subtitle")));
  assert.doesNotThrow(() => render(instance, form("", "Subtitle without a title")));
  assert.doesNotThrow(() => render(instance, form("", "")));
  assert.throws(() => render(instance, form("Greek Ω is unsupported")));
  instance = await instantiate();
  assert.throws(() => render(instance, "subtitle=Missing+title"));
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
