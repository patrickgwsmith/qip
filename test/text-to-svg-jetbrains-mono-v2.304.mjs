import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const componentPath = "text/text-to-svg-jetbrains-mono-v2.304.wasm";

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

function transforms(svg) {
  return [...svg.matchAll(/translate\(([^ ]+) ([^)]+)\)/g)]
    .map((match) => ({ x: Number(match[1]), y: Number(match[2]) }));
}

test("renders intrinsic JetBrains Mono paths without ligatures", async () => {
  const instance = await instantiate();
  instance.exports.uniform_set_measure(600);
  const svg = render(instance, "!=");
  assert.equal(instance.exports.uniform_set_background_color_rgba, undefined);
  assert.equal(instance.exports.uniform_set_font_max_size, undefined);
  assert.equal(instance.exports.uniform_set_text_color_rgba, undefined);
  assert.match(svg, /^<svg [^>]*width="600" height="[^"]+"/);
  assert.match(svg, /data-role="text"[^>]*data-font-family="JetBrains Mono NL"/);
  assert.equal((svg.match(/<path\b/g) ?? []).length, 2);
  assert.match(svg, /translate\(0\.000 /);
  assert.doesNotMatch(svg, /<rect\b|<text\b|background/);
});

test("uses equal advances in Regular and Bold", async () => {
  const instance = await instantiate();
  const regular = transforms(render(instance, "Wi"));
  assert.equal(regular.length, 2);

  instance.exports.uniform_set_font_weight(700);
  const bold = transforms(render(instance, "Wi"));
  assert.equal(bold.length, 2);
  assert.ok(Math.abs((regular[1].x - regular[0].x) - (bold[1].x - bold[0].x)) < 0.001);
});

test("applies intrinsic layout uniforms and resets them", async () => {
  const instance = await instantiate();
  instance.exports.uniform_set_font_weight(700);
  instance.exports.uniform_set_font_size(64);
  instance.exports.uniform_set_measure(400);
  instance.exports.uniform_set_alignment(0.5);
  instance.exports.uniform_set_line_height_em(1.5);
  instance.exports.uniform_set_inspect_layout_metrics(1);
  const configured = render(instance, "A\nB");
  const positions = transforms(configured);
  assert.equal(positions[1].y - positions[0].y, 96);
  assert.ok(positions[0].x > 100);
  assert.match(configured, /fill="currentColor"/);
  assert.match(configured, /data-font-weight="700"/);
  assert.match(configured, /data-inspect="layout_metrics"/);

  const defaults = render(instance, "A\nB");
  const defaultPositions = transforms(defaults);
  assert.match(defaults, /^<svg [^>]*width="1080"/);
  assert.match(defaults, /fill="currentColor"/);
  assert.match(defaults, /data-font-weight="400"/);
  assert.match(defaults, /data-font-size="64"/);
  assert.equal(defaultPositions[0].x, 0);
  assert.ok(defaultPositions[1].y - defaultPositions[0].y > 84);
  assert.ok(defaultPositions[1].y - defaultPositions[0].y < 85);
  assert.doesNotMatch(defaults, /data-inspect=/);
});

test("zero line height overlays baselines", async () => {
  const instance = await instantiate();
  instance.exports.uniform_set_line_height_em(0);
  const positions = transforms(render(instance, "A\nB"));
  assert.equal(positions[0].y, positions[1].y);
});

test("wraps and rejects unsupported scripts", async () => {
  let instance = await instantiate();
  instance.exports.uniform_set_measure(280);
  const svg = render(instance, "Monospaced text wraps predictably across this composition layer.");
  assert.ok(new Set(transforms(svg).map(({ y }) => y)).size > 1);

  instance = await instantiate();
  assert.throws(() => render(instance, "Greek Ω is unsupported"));
});
