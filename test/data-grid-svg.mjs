import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { wasmMustComplyWithComponentContract } from "../npm/qipx/qipx.mjs";

const bytes = await readFile("gui/data-grid-svg.wasm");
const XK_BACKSPACE = 0xff08;
const XK_ESCAPE = 0xff1b;
const XK_DOWN = 0xff54;
const XK_END = 0xff57;

function grid() {
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
  let time = 0;
  const update = (fn) => {
    e.begin_update_at(BigInt(++time));
    const changed = fn(e);
    e.finish_update();
    return { changed, svg: render() };
  };
  const key = (code) => update((x) => x.key_event(code, 1));
  return { e, render, update, key, text };
}

const rowKeys = (svg) => [...svg.matchAll(/data-key="o(\d+)"/g)].map((match) => Number(match[1]));
const summary = (svg) => svg.match(/Rows [^<]*/)[0];

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

test("data grid declares SVG and renders 17 keyed rows of 1,000", () => {
  assert.doesNotThrow(() => wasmMustComplyWithComponentContract(bytes));
  const { e, render, text } = grid();
  assert.equal(text(e.output_content_type_ptr(), e.output_content_type_size()), "image/svg+xml");
  const svg = render();
  assert.match(svg, /viewBox="0 0 820 540"/);
  assert.deepEqual(rowKeys(svg), Array.from({ length: 17 }, (_, i) => 10001 + i));
  assert.equal(summary(svg), "Rows 1-17 of 1000. Sorted by Order, ascending.");
});

test("data grid scrolls with the cursor and clicks headers to sort", () => {
  const { render, update, key } = grid();
  render();
  let frame;
  for (let i = 0; i < 20; i++) frame = key(XK_DOWN);
  assert.equal(summary(frame.svg), "Rows 5-21 of 1000. Sorted by Order, ascending.");
  assert.equal(key(XK_END).svg.includes('data-key="o11000"'), true);

  const clickAmount = () => update((x) => x.pointer_event(1, 700, 70) | x.pointer_event(0, 700, 70));
  frame = clickAmount();
  assert.equal(summary(frame.svg), "Rows 1-17 of 1000. Sorted by Amount, ascending.");
  const amounts = (svg) => [...svg.matchAll(/text-anchor="end">\$([\d,.]+)</g)].map((m) => Number(m[1].replace(",", "")));
  const ascending = amounts(frame.svg);
  assert.deepEqual(ascending, ascending.toSorted((a, b) => a - b));
  frame = clickAmount();
  assert.match(summary(frame.svg), /descending/);
  const descending = amounts(frame.svg);
  assert.deepEqual(descending, descending.toSorted((a, b) => b - a));
});

test("data grid filters by typed text and clears with Escape", () => {
  const { render, key } = grid();
  render();
  let frame;
  for (const char of "north") frame = key(char.charCodeAt(0));
  const count = Number(summary(frame.svg).match(/of (\d+)/)[1]);
  assert.ok(count > 0 && count < 1000);
  assert.match(frame.svg, /<text[^>]*>north<\/text>/);
  assert.equal([...frame.svg.matchAll(/>North</g)].length, 17);
  for (const char of "zzz") frame = key(char.charCodeAt(0));
  assert.match(frame.svg, /No orders match &quot;northzzz&quot;/);
  frame = key(XK_BACKSPACE);
  assert.match(frame.svg, /No orders match &quot;northzz&quot;/);
  frame = key(XK_ESCAPE);
  assert.equal(summary(frame.svg), "Rows 1-17 of 1000. Sorted by Order, ascending.");
  assert.equal(key(XK_ESCAPE).changed, 0);
});

test("data grid escapes filter text", () => {
  const { render, key } = grid();
  render();
  let frame;
  for (const char of "<&\"") frame = key(char.charCodeAt(0));
  assert.match(frame.svg, /&lt;&amp;&quot;/);
  assert.doesNotMatch(frame.svg, /<&/);
});

test("data grid digests each keyed element's content into data-rev", () => {
  const { render, update, key } = grid();
  const svg = render();
  const keyed = [...keyedContents(svg)];
  assert.equal(keyed.length, 1 + 1 + 6 + 1 + 17 + 1);
  for (const [, content, rev] of keyed) assert.equal(rev, fnv1a32(content));
  const row = (svg, id) => svg.match(new RegExp(`<g data-key="o${id}" transform="([^"]+)" fill="([^"]+)" data-rev="([0-9a-f]{8})">`)).slice(1);

  // Hover and scrolling change only the row's own attributes, not its digest.
  const hovered = update((x) => x.pointer_event(0, 400, 92 + 24 * 3 + 12)).svg;
  assert.deepEqual(row(hovered, 10004), [row(svg, 10004)[0], "#1A2236", row(svg, 10004)[2]]);
  let scrolled = hovered;
  for (let i = 0; i < 17; i++) scrolled = key(0xff54).svg;
  const [transform, , rev] = row(scrolled, 10005);
  assert.notEqual(transform, row(svg, 10005)[0]);
  assert.equal(rev, row(svg, 10005)[2]);
  // The cursor bar is content, so moving the cursor changes both rows' digests.
  const fresh = grid();
  const first = fresh.render();
  const moved = fresh.key(0xff54).svg;
  assert.notEqual(row(moved, 10001)[2], row(first, 10001)[2]);
  assert.notEqual(row(moved, 10002)[2], row(first, 10002)[2]);
  assert.equal(row(moved, 10003)[2], row(first, 10003)[2]);
});
