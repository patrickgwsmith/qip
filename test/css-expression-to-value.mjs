import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { decodeRenderResult } from "./lib/content-component-host.mjs";

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

function readI32Export(exports, name) {
  const value = exports[name];
  return typeof value === "function" ? value() : value.value;
}

function render(exports, input, uniforms = {}) {
  const bytes = encoder.encode(input);
  const inputPtr = readI32Export(exports, "input_ptr");
  assert.ok(bytes.length <= readI32Export(exports, "input_utf8_cap"));
  new Uint8Array(exports.memory.buffer, inputPtr, bytes.length).set(bytes);
  for (const [name, value] of Object.entries(uniforms)) {
    exports[`uniform_set_${name}`](value);
  }
  const result = decodeRenderResult(exports.render(bytes.length));
  assert.equal(result.failed, false);
  return decoder.decode(new Uint8Array(exports.memory.buffer, result.outputPointer, result.value));
}

async function load() {
  return (await WebAssembly.instantiate(
    await readFile("text/css/css-expression-to-value.wasm"),
    {},
  )).instance.exports;
}

test("resolves rem and viewport units using uniforms", async () => {
  const exports = await load();
  const uniforms = {
    root_font_size: 18,
    root_line_height: 27,
    viewport_width: 1440,
    viewport_height: 900,
  };

  assert.equal(render(exports, "1rem", uniforms), "18px");
  assert.equal(render(exports, "2rlh", uniforms), "54px");
  assert.equal(render(exports, "10vw", uniforms), "144px");
  assert.equal(render(exports, "10vh", uniforms), "90px");
  assert.equal(render(exports, "calc(50% * 1rem)", uniforms), "9px");
  assert.equal(render(exports, "calc(100vh - 2rlh)", uniforms), "846px");
  assert.equal(render(exports, "calc((10vw - 4px) / 2)", uniforms), "70px");
});

test("returns numbers and discards instances after invalid expressions trap", async () => {
  const exports = await load();
  assert.equal(render(exports, "calc(1 + 5 / 2)"), "3.5");

  for (const invalid of ["", "1em", "1rem + 2", "1rem * 2px", "1 / 0", "calc(1rem"]) {
    const trapped = await load();
    assert.throws(() => render(trapped, invalid), WebAssembly.RuntimeError);
  }
  const replacement = await load();
  assert.equal(render(replacement, "2px + 3px"), "5px");
});

test("resolves mobile viewport and environment values", async () => {
  const exports = await load();
  const uniforms = {
    root_font_size: 16,
    viewport_width: 430,
    viewport_height: 932,
    small_viewport_width: 430,
    small_viewport_height: 780,
    dynamic_viewport_width: 430,
    dynamic_viewport_height: 844,
    safe_area_inset_bottom: 34,
    keyboard_inset_height: 290,
  };

  assert.equal(render(exports, "100lvh", uniforms), "932px");
  assert.equal(render(exports, "100svh", uniforms), "780px");
  assert.equal(render(exports, "100dvh", uniforms), "844px");
  assert.equal(render(exports, "max(1rem, env(safe-area-inset-bottom))", uniforms), "34px");
  assert.equal(render(exports, "calc(100dvh - env(keyboard-inset-height))", uniforms), "554px");
  assert.equal(render(exports, "env(not-supported, 12px)", uniforms), "12px");
});

test("exports every safe-area and keyboard uniform used by the tool", async () => {
  const exports = await load();
  const names = [
    "safe_area_inset_top", "safe_area_inset_right", "safe_area_inset_bottom", "safe_area_inset_left",
    "safe_area_max_inset_top", "safe_area_max_inset_right", "safe_area_max_inset_bottom", "safe_area_max_inset_left",
    "keyboard_inset_top", "keyboard_inset_right", "keyboard_inset_bottom", "keyboard_inset_left",
    "keyboard_inset_width", "keyboard_inset_height",
  ];
  for (const [index, name] of names.entries()) {
    assert.equal(typeof exports[`uniform_set_${name}`], "function", name);
    assert.equal(exports[`uniform_set_${name}`](index + 1), index + 1, name);
  }
  assert.equal(render(exports, "env(safe-area-max-inset-left)"), "8px");
  exports.uniform_set_keyboard_inset_width(13);
  assert.equal(render(exports, "env(keyboard-inset-width)"), "13px");
});

test("uses the plain UTF-8 QIP contract without MIME metadata", async () => {
  const exports = await load();
  for (const name of [
    "input_content_type_ptr",
    "input_content_type_size",
    "output_content_type_ptr",
    "output_content_type_size",
  ]) {
    assert.equal(exports[name], undefined);
  }
});
