import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { wasmMustComplyWithComponentContract } from "../npm/qipx/qipx.mjs";

const bytes = await readFile("gui/date-range-picker-svg.wasm");
const XK_ENTER = 0xff0d;
const XK_ESCAPE = 0xff1b;
const XK_LEFT = 0xff51;
const XK_RIGHT = 0xff53;
const XK_PAGE_UP = 0xff55;
const XK_PAGE_DOWN = 0xff56;

function picker() {
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

const months = (svg) => [...svg.matchAll(/data-key="m(\d{4}-\d{2})"/g)].map((match) => match[1]);
const days = (svg) => [...svg.matchAll(/data-key="d(\d{8})"/g)].map((match) => match[1]);
const footer = (svg) => svg.match(/(Pick a check-in|Check-in [A-Z])[^<]*/)[0];

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

test("date picker declares SVG and draws two keyed months", () => {
  assert.doesNotThrow(() => wasmMustComplyWithComponentContract(bytes));
  const { e, render, text } = picker();
  assert.equal(text(e.output_content_type_ptr(), e.output_content_type_size()), "image/svg+xml");
  const svg = render();
  assert.match(svg, /viewBox="0 0 820 480"/);
  assert.deepEqual(months(svg), ["2026-10", "2026-11"]);
  const keys = days(svg);
  assert.equal(keys.length, 61);
  assert.equal(keys[0], "20261001");
  assert.equal(keys.at(-1), "20261130");
  assert.match(svg, />October 2026</);
  assert.equal(footer(svg), "Pick a check-in date. Crossed-out dates are booked.");
});

test("date picker pages months with the focus and keeps panels keyed", () => {
  const { render, key } = picker();
  render();
  assert.deepEqual(months(key(XK_PAGE_DOWN).svg), ["2026-10", "2026-11"]);
  assert.deepEqual(months(key(XK_PAGE_DOWN).svg), ["2026-11", "2026-12"]);
  assert.deepEqual(months(key(XK_PAGE_UP).svg), ["2026-11", "2026-12"]);
  assert.deepEqual(months(key(XK_PAGE_UP).svg), ["2026-10", "2026-11"]);
  assert.equal(key(XK_PAGE_UP).changed, 0);
  assert.equal(key(XK_LEFT).changed, 0);
});

test("date picker selects a stay with the keyboard and previews it", () => {
  const { render, key } = picker();
  render();
  let frame = key(XK_ENTER);
  assert.equal(footer(frame.svg), "Check-in Mon 5 Oct. Now pick check-out, up to 30 nights later.");
  frame = key(XK_RIGHT);
  assert.match(frame.svg, /<g data-key="d20261006" data-rev="[0-9a-f]{8}"><rect x="\d+" y="\d+" width="24" height="36" rx="0" fill="#151D33"\/>/);
  for (let i = 0; i < 3; i++) frame = key(XK_RIGHT);
  frame = key(XK_ENTER);
  assert.equal(footer(frame.svg), "Check-in Mon 5 Oct. Check-out Fri 9 Oct. 4 nights.");
  frame = key(XK_ESCAPE);
  assert.equal(footer(frame.svg), "Pick a check-in date. Crossed-out dates are booked.");
});

test("date picker refuses past and booked dates", () => {
  const { render, update } = picker();
  const svg = render();
  // Click October 1, before the first bookable day.
  const frame = update((x) => x.pointer_event(1, 50 + 3 * 48 + 24, 146 + 21) | x.pointer_event(0, 50 + 3 * 48 + 24, 146 + 21));
  assert.equal(footer(frame.svg), footer(svg));
  const booked = [...svg.matchAll(/data-key="d(\d{8})"[^>]*>(?:(?!<\/g>).)*<line /g)].map((match) => match[1]);
  assert.ok(booked.length > 0);
});

test("date picker digests each keyed element's content into data-rev", () => {
  const { render, update, key } = picker();
  const before = render();
  for (const [, content, rev] of keyedContents(before)) assert.equal(rev, fnv1a32(content));
  // Paging moves November to the left panel without changing its content.
  key(XK_PAGE_DOWN);
  const after = key(XK_PAGE_DOWN).svg;
  const revOf = (svg, key) => svg.match(new RegExp(`data-key="${key}"[^>]*data-rev="([0-9a-f]{8})"`))[1];
  assert.match(before, /data-key="m2026-11" transform="translate\(434 0\)"/);
  assert.match(after, /data-key="m2026-11" transform="translate\(50 0\)"/);
  assert.equal(revOf(after, "m2026-11"), revOf(before, "m2026-11"));
  // Hovering an open day (5 November) changes its content and so its digest,
  // and the digest of the month that contains it.
  const hovered = update((x) => x.pointer_event(0, 50 + 3 * 48 + 24, 146 + 42 + 21)).svg;
  const revs = (svg) => new Map([...keyedContents(svg)].map(([key, , rev]) => [key, rev]));
  const [beforeHover, afterHover] = [revs(after), revs(hovered)];
  const changed = [...afterHover.keys()].filter((key) => afterHover.get(key) !== beforeHover.get(key));
  assert.deepEqual(changed, ["m2026-11", "d20261105"]);
});
