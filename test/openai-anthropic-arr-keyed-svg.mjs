import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { wasmMustComplyWithComponentContract } from "../npm/qipx/qipx.mjs";

const bytes = await readFile("gui/openai-anthropic-arr-keyed-svg.wasm");
const plainBytes = await readFile("gui/openai-anthropic-arr-svg.wasm");

function chart(wasm = bytes) {
  const e = new WebAssembly.Instance(new WebAssembly.Module(wasm), {}).exports;
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

function fnv1a32(text) {
  let hash = 0x811c9dc5;
  for (const byte of new TextEncoder().encode(text)) hash = Math.imul(hash ^ byte, 0x01000193) >>> 0;
  return hash.toString(16).padStart(8, "0");
}

// Yields [key, content, rev] for each keyed element, matching nested <g> tags.
function* keyedContents(svg) {
  for (const match of svg.matchAll(/<g data-key="([^"]+)"[^>]*data-rev="([0-9a-f]{8})">/g)) {
    const start = match.index + match[0].length;
    let depth = 1;
    const tags = /<(\/?)g[ >]/g;
    tags.lastIndex = start;
    let tag;
    while (depth > 0 && (tag = tags.exec(svg))) depth += tag[1] ? -1 : 1;
    yield [match[1], svg.slice(start, tag.index), match[2]];
  }
}

const revs = (svg) => Object.fromEntries([...keyedContents(svg)].map(([key, , rev]) => [key, rev]));
const changedKeys = (from, to) => {
  const a = revs(from);
  const b = revs(to);
  return [...new Set([...Object.keys(a), ...Object.keys(b)])].filter((key) => a[key] !== b[key]).sort();
};
const texts = (svg) => [...svg.matchAll(/<text[^>]*>([^<]*)<\/text>/g)].map((match) => match[1]).sort();

test("keyed chart digests each part's content into data-rev", () => {
  assert.doesNotThrow(() => wasmMustComplyWithComponentContract(bytes));
  const { e, render, update, text } = chart();
  assert.equal(text(e.output_content_type_ptr(), e.output_content_type_size()), "image/svg+xml");
  const frames = [render()];
  frames.push(update(1, (x) => x.pointer_event(0, 713, 106)).svg);
  frames.push(update(2, (x) => x.key_event(76, 1)).svg);
  frames.push(update(152, () => {}).svg);
  for (const svg of frames) {
    for (const [, content, rev] of keyedContents(svg)) assert.equal(rev, fnv1a32(content));
  }
  assert.deepEqual(Object.keys(revs(frames[1])), [
    "title", "series-openai", "series-anthropic", "scale-linear", "scale-log",
    "plot", "y-linear", "y-log", "openai", "anthropic", "selection", "tooltip", "detail",
  ]);
});

test("keyed chart draws the same marks and text as the plain chart", () => {
  const keyed = chart();
  const plain = chart(plainBytes);
  const pairs = [[keyed.render(), plain.render()]];
  const event = (x) => x.pointer_event(0, 713, 106);
  pairs.push([keyed.update(1, event).svg, plain.update(1, event).svg]);
  for (const [a, b] of pairs) {
    assert.deepEqual(texts(a).filter((label) => !/^\$/.test(label)), texts(b).filter((label) => !/^\$/.test(label)));
    assert.equal((a.match(/<path /g) ?? []).length, (b.match(/<path /g) ?? []).length);
    // The selected point keeps its small dot under the larger one.
    assert.equal((a.match(/<circle /g) ?? []).length, (b.match(/<circle /g) ?? []).length + 1);
  }
  // The plain chart omits the hidden axis; the keyed chart hides its group.
  assert.match(pairs[0][0], /<g data-key="y-linear" display="none"/);
  assert.deepEqual(texts(pairs[0][0].replace(/<g data-key="y-linear".*?<\/g>/, "")), texts(pairs[0][1]));
});

test("keyed chart changes only the parts a hover or scale tween touches", () => {
  const { render, update } = chart();
  const start = render();
  // Hovering Anthropic's April 2026 point moves the selection and opens the tooltip.
  const hover = update(1, (x) => assert.equal(x.pointer_event(0, 651, 156), 1)).svg;
  assert.match(hover, /Anthropic  Apr 2026/);
  assert.deepEqual(changedKeys(start, hover), ["detail", "selection", "tooltip"]);
  // Hovering an OpenAI point also changes which series button is active.
  const openai = update(2, (x) => assert.equal(x.pointer_event(0, 733, 146), 1)).svg;
  assert.match(openai, /OpenAI  Aug 2026/);
  assert.deepEqual(changedKeys(hover, openai), ["detail", "selection", "series-anthropic", "series-openai", "tooltip"]);
  // Mid-tween, the axes fade through group opacity and keep their digests.
  const toggled = update(3, (x) => assert.equal(x.key_event(76, 1), 1)).svg;
  const mid = update(103, () => {}).svg;
  assert.match(mid, /<g data-key="y-log" opacity="0\.\d+"/);
  assert.match(mid, /<g data-key="y-linear" display="none"/);
  assert.deepEqual(changedKeys(toggled, mid), ["anthropic", "openai", "selection", "tooltip"]);
});
