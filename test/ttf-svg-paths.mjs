import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { promisify } from "node:util";
import test from "node:test";

const execFileAsync = promisify(execFile);
const root = process.cwd();
const qip = join(root, "qip");
const fixture = join(
  root,
  "fixtures/dejavu-fonts-ttf-2.37/ttf/DejaVuSans.ttf",
);
const csvComponent = join(
  root,
  "font/ttf/ttf-to-svg-paths-csv.wasm",
);
const defsComponent = join(
  root,
  "font/ttf/ttf-to-svg-path-defs.wasm",
);

async function convert(component, first, last) {
  const { stdout } = await execFileAsync(qip, [
    "run",
    "-i",
    fixture,
    "--",
    component,
    `?first_codepoint=${first}&last_codepoint=${last}`,
  ]);
  return stdout;
}

async function renderTwice(component) {
  const [{ instance }, input] = await Promise.all([
    WebAssembly.instantiate(await readFile(component)),
    readFile(fixture),
  ]);
  const e = instance.exports;
  const memory = new Uint8Array(e.memory.buffer);
  memory.set(input, e.input_ptr());
  const decode = (size) =>
    new TextDecoder("utf-8", { fatal: true }).decode(
      memory.subarray(qipRenderedOutputPointer(e), qipRenderedOutputPointer(e) + size),
    );

  e.uniform_set_first_codepoint(65);
  e.uniform_set_last_codepoint(65);
  const configured = decode(qipRenderSize(e, input.length));
  const defaults = decode(qipRenderSize(e, input.length));
  return { configured, defaults };
}

test("extracts a proportional glyph as SVG path CSV", async () => {
  const csv = await convert(csvComponent, 65, 65);
  const lines = csv.trimEnd().split("\n");
  assert.equal(lines.length, 2);
  assert.match(lines[0], /^codepoint,hex,glyph_id,advance_x,/);
  assert.match(lines[1], /^65,U\+0041,36,1401,16,/);
  assert.match(lines[1], /,"M [^"]+ Z"$/);
});

test("resolves a compound glyph and gives its SVG path a codepoint ID", async () => {
  const svg = await convert(defsComponent, 0x00e9, 0x00e9);
  assert.match(svg, /^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg"/);
  assert.match(svg, /<path id="u-00E9" data-codepoint="U\+00E9"/);
  assert.match(svg, / d="M [^"]+ Z"\/>/);
  assert.equal((svg.match(/<path /g) ?? []).length, 1);
  assert.match(svg.trimEnd(), /<\/defs><\/svg>$/);
});

test("rejects a codepoint range above the fixed limit", async () => {
  await assert.rejects(convert(csvComponent, 0, 4096));
});

test("CSV range uniforms reset to U+0020 through U+00FF", async () => {
  const { configured, defaults } = await renderTwice(csvComponent);
  assert.equal(configured.trimEnd().split("\n").length, 2);
  assert.match(configured, /\n65,U\+0041,36,1401,16,/);
  assert.match(defaults, /\n32,U\+0020,3,651,0,/);
  assert.match(defaults, /\n255,U\+00FF,/);
});

test("SVG range uniforms reset to U+0020 through U+00FF", async () => {
  const { configured, defaults } = await renderTwice(defsComponent);
  assert.equal((configured.match(/<path /g) ?? []).length, 1);
  assert.match(configured, /<path id="u-0041" data-codepoint="U\+0041"/);
  assert.match(defaults, /<path id="u-0020" data-codepoint="U\+0020"/);
  assert.match(defaults, /<path id="u-00FF" data-codepoint="U\+00FF"/);
});
