import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const componentPath = "text/text-to-svg-inter.wasm";

async function instantiate() {
  const { instance } = await WebAssembly.instantiate(await readFile(componentPath), {});
  return instance;
}

function render(instance, text) {
  const input = Buffer.from(text);
  assert.ok(input.length <= instance.exports.input_utf8_cap());
  new Uint8Array(instance.exports.memory.buffer, instance.exports.input_ptr(), input.length).set(input);
  const outputSize = qipRenderSize(instance.exports, input.length);
  return Buffer.from(new Uint8Array(
    instance.exports.memory.buffer,
    qipRenderedOutputPointer(instance.exports),
    outputSize,
  )).toString("utf8");
}

function contentType(instance, prefix) {
  return Buffer.from(new Uint8Array(
    instance.exports.memory.buffer,
    instance.exports[`${prefix}_content_type_ptr`](),
    instance.exports[`${prefix}_content_type_size`](),
  )).toString("utf8");
}

function transforms(svg) {
  return [...svg.matchAll(/translate\(([^ ]+) ([^)]+)\)/g)]
    .map((match) => ({ x: Number(match[1]), y: Number(match[2]) }));
}

test("renders intrinsic wrapped Inter paths without padding", async () => {
  const instance = await instantiate();
  instance.exports.uniform_set_measure(320);
  const svg = render(instance, "Inter text wraps onto more than one line.");

  assert.equal(contentType(instance, "input"), "text/plain");
  assert.equal(contentType(instance, "output"), "image/svg+xml");
  assert.equal(instance.exports.uniform_set_background_color_rgba, undefined);
  assert.equal(instance.exports.uniform_set_font_max_size, undefined);
  assert.match(svg, /^<svg [^>]*width="320" height="[^"]+" viewBox="0 0 320 /);
  assert.match(svg, /data-role="text"[^>]*data-font-family="Inter Display"/);
  assert.match(svg, /translate\(0\.000 /);
  assert.ok(new Set(transforms(svg).map(({ y }) => y)).size > 1);
  assert.doesNotMatch(svg, /<rect\b|<text\b|background/);
});

test("applies exact font size, weight, alignment, and resets them", async () => {
  const instance = await instantiate();
  instance.exports.uniform_set_text_color_rgba(0x11223344);
  assert.equal(instance.exports.uniform_set_font_weight(700), 700);
  assert.equal(instance.exports.uniform_set_font_size(80), 80);
  assert.equal(instance.exports.uniform_set_measure(400), 400);
  assert.equal(instance.exports.uniform_set_alignment(2), 1);
  const configured = render(instance, "AV");
  assert.match(configured, /fill="#11223344"/);
  assert.match(configured, /data-font-weight="700"/);
  assert.match(configured, /data-font-size="80"/);
  assert.ok(transforms(configured)[0].x > 200);

  const defaults = render(instance, "AV");
  assert.match(defaults, /^<svg [^>]*width="1080"/);
  assert.match(defaults, /fill="#101010"/);
  assert.match(defaults, /data-font-weight="400"/);
  assert.match(defaults, /data-font-size="64"/);
  assert.equal(transforms(defaults)[0].x, 0);
});

test("line height advances later baselines without moving the first", async () => {
  const instance = await instantiate();
  instance.exports.uniform_set_font_size(64);
  assert.equal(instance.exports.uniform_set_line_height_em(1.5), 1.5);
  const spaced = transforms(render(instance, "A\nB"));
  assert.equal(spaced[1].y - spaced[0].y, 96);

  instance.exports.uniform_set_font_size(64);
  assert.equal(instance.exports.uniform_set_line_height_em(0), 0);
  const overlaid = transforms(render(instance, "A\nB"));
  assert.equal(overlaid[0].y, spaced[0].y);
  assert.equal(overlaid[1].y, overlaid[0].y);

  const natural = transforms(render(instance, "A\nB"));
  assert.equal(natural[0].y, spaced[0].y);
  assert.ok(natural[1].y - natural[0].y > 77);
  assert.ok(natural[1].y - natural[0].y < 78);
});

test("preserves empty lines and emits optional layout metrics", async () => {
  const instance = await instantiate();
  instance.exports.uniform_set_font_size(64);
  instance.exports.uniform_set_line_height_em(1);
  instance.exports.uniform_set_inspect_layout_metrics(1);
  const inspected = render(instance, "A\n\nB\n");
  assert.match(inspected, /<g data-inspect="layout_metrics"/);
  assert.equal((inspected.match(/data-metric="baseline"/g) ?? []).length, 4);
  assert.equal((inspected.match(/data-metric="line_start"/g) ?? []).length, 4);
  assert.match(inspected, /data-metric="measure_start"/);
  assert.match(inspected, /data-metric="measure_end"/);

  instance.exports.uniform_set_font_size(64);
  instance.exports.uniform_set_line_height_em(1);
  const normal = render(instance, "A\n\nB\n");
  const dimensions = (svg) => svg.match(/^<svg [^>]*width="([^"]+)" height="([^"]+)"/).slice(1);
  assert.deepEqual(dimensions(inspected), dimensions(normal));
  assert.doesNotMatch(normal, /data-inspect=/);
});

test("rejects unsupported scripts", async () => {
  const instance = await instantiate();
  assert.doesNotThrow(() => render(instance, ""));
  assert.throws(() => render(instance, "Greek Ω is unsupported"));
});
