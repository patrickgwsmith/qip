import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { wasmMustComplyWithComponentContract } from "../npm/qipx/qipx.mjs";

const bytes = await readFile("gui/openai-anthropic-arr-svg.wasm");

function chart() {
  const e = new WebAssembly.Instance(new WebAssembly.Module(bytes), {}).exports;
  const text = (ptr, size) => new TextDecoder("utf-8", { fatal: true }).decode(new Uint8Array(e.memory.buffer, ptr, size));
  const render = () => {
    const result = BigInt.asUintN(64, e.render(0));
    const size = Number(result & 0xffffffffn);
    const ptr = Number((result >> 32n) & 0x7fffffffn);
    assert.equal(result >> 63n, 0n);
    assert.ok(size > 0 && size <= e.output_utf8_cap());
    return text(ptr, size);
  };
  const update = (time, fn) => {
    e.begin_update_at(BigInt(time));
    fn(e);
    const next = e.finish_update();
    return { next, svg: render() };
  };
  return { e, render, update, text };
}

test("SVG chart declares UTF-8 SVG and emits vector marks with live text", () => {
  assert.doesNotThrow(() => wasmMustComplyWithComponentContract(bytes));
  const { e, render, text } = chart();
  assert.equal(text(e.output_content_type_ptr(), e.output_content_type_size()), "image/svg+xml");
  const svg = render();
  assert.match(svg, /viewBox="0 0 820 540"/);
  assert.equal((svg.match(/<path /g) ?? []).length, 2);
  assert.equal((svg.match(/<circle /g) ?? []).length, 25);
  assert.match(svg, /<text[^>]*>OpenAI vs Anthropic revenue run rate<\/text>/);
  assert.match(svg, /data-qip-chart-control="scale-log"/);
  assert.doesNotMatch(svg, /<image\b|data:image\//);
});

test("SVG chart keeps milestone selection, hover tooltip, and scale animation", () => {
  const { e, render, update } = chart();
  render();
  let frame = update(1, (x) => { assert.equal(x.key_event(79, 1), 1); });
  assert.match(frame.svg, /OpenAI  Aug 2026  ARR \$40\.0B/);
  frame = update(2, (x) => { assert.equal(x.pointer_event(0, 713, 106), 1); });
  assert.match(frame.svg, /data-qip-chart-tooltip="true"/);
  assert.match(frame.svg, /Anthropic  \$65\.0B/);
  frame = update(3, (x) => { assert.equal(x.pointer_event(0, -1, -1), 1); });
  assert.doesNotMatch(frame.svg, /data-qip-chart-tooltip/);
  frame = update(4, (x) => { assert.equal(x.key_event(76, 1), 1); });
  assert.equal(frame.next, 20n);
  const start = frame.svg;
  frame = update(154, () => {});
  assert.notEqual(frame.svg, start);
  frame = update(304, () => {});
  assert.equal(frame.next, 304n);
  assert.notEqual(frame.svg, start);
});
