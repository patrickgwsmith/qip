// HTML escaping across many pages: the existing component, one page per call,
// against the prototype kernels in escape_kernels.wasm.
// Run from the repository root (after `make site-static`):
//   node benchmarks/html-escape-batch/bench.mjs
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const dir = "benchmarks/html-escape-batch/";

function walk(root, ext, out = []) {
  for (const name of readdirSync(root)) {
    const p = join(root, name);
    if (statSync(p).isDirectory()) walk(p, ext, out);
    else if (p.endsWith(ext)) out.push(readFileSync(p));
  }
  return out;
}

const corpora = [
  ["site-static HTML", walk("site-static", ".html")],
  ["site + docs markdown", [...walk("site", ".md"), ...walk("docs", ".md")]],
];

const component = await (async () => {
  const { instance } = await WebAssembly.instantiate(readFileSync("text/html/html-escape.wasm"));
  const e = instance.exports;
  return (pageList) => pageList.map((page) => {
    new Uint8Array(e.memory.buffer, e.input_ptr(), page.length).set(page);
    const r = BigInt.asUintN(64, e.render(page.length));
    return new Uint8Array(e.memory.buffer, Number((r >> 32n) & 0x7fffffffn), Number(r & 0xffffffffn)).slice();
  });
})();

const { instance } = await WebAssembly.instantiate(readFileSync(dir + "escape_kernels.wasm"));
const k = instance.exports;

// Lays pages out once per corpus (in_off 16-aligned, out_off 6x room + slack)
// and returns a runner that copies pages in, runs, and copies results out.
function kernel(name, pageList, interleaved) {
  const mem = () => k.memory.buffer;
  const table = new Uint32Array(mem(), k.pages_ptr(), pageList.length * 4);
  const layout = new Uint32Array(pageList.length * 4);
  let inOff = 0, outOff = 0;
  pageList.forEach((page, p) => {
    layout.set([inOff, page.length, outOff, 0], p * 4);
    inOff += (page.length + 15) & ~15;
    outOff += ((page.length * 6 + 8 + 15) & ~15);
  });
  if (interleaved) {
    // Untimed transpose: byte i of the group's 16 pages is one 16-byte row.
    const il = new Uint8Array(mem(), k.il_ptr());
    const offs = new Uint32Array(mem(), k.il_offs_ptr(), Math.ceil(pageList.length / 16));
    let o = 0;
    for (let g = 0; g < pageList.length; g += 16) {
      const group = pageList.slice(g, g + 16);
      const max = Math.max(...group.map((x) => x.length));
      offs[g / 16] = o;
      group.forEach((page, l) => { for (let i = 0; i < page.length; i++) il[o + i * 16 + l] = page[i]; });
      o += max * 16;
    }
  }
  const input = new Uint8Array(mem(), k.in_ptr());
  const out = new Uint8Array(mem(), k.out_ptr());
  return () => {
    table.set(layout);
    if (!interleaved) pageList.forEach((page, p) => input.set(page, table[p * 4]));
    k[name](pageList.length);
    return pageList.map((_, p) => out.slice(table[p * 4 + 2], table[p * 4 + 2] + table[p * 4 + 3]));
  };
}

function time(fn) {
  for (let i = 0; i < 5; i++) fn();
  let reps = 0;
  for (const t0 = performance.now(); performance.now() - t0 < 20;) { fn(); reps++; }
  const samples = [];
  for (let r = 0; r < 31; r++) {
    const t0 = performance.now();
    for (let i = 0; i < reps; i++) fn();
    samples.push((performance.now() - t0) / reps);
  }
  return samples.sort((a, b) => a - b)[15];
}

for (const [label, unsorted] of corpora) {
  const bytes = unsorted.reduce((n, p) => n + p.length, 0);
  const sorted = [...unsorted].sort((a, b) => b.length - a.length);
  const want = component(unsorted);
  const outBytes = want.reduce((n, p) => n + p.length, 0);
  console.log(`\n${label}: ${unsorted.length} pages, ${(bytes / 1024).toFixed(0)} KiB in, ${(outBytes / 1024).toFixed(0)} KiB out`);
  const runs = [
    ["html-escape.wasm, one call per page", () => component(unsorted), unsorted],
    ["LUT, one page at a time", kernel("run_lut", unsorted), unsorted],
    ["16-byte blocks, one page at a time", kernel("run_block", unsorted), unsorted],
    ["16 pages per i8x16, gathered", kernel("run_lanes16", unsorted), unsorted],
    ["16 pages per i8x16, gathered, sorted by length", kernel("run_lanes16", sorted), sorted],
    ["16 pages per i8x16, pre-interleaved, sorted", kernel("run_lanes16_interleaved", sorted, true), sorted],
  ];
  const base = time(runs[0][1]);
  console.log("| Kernel | ms | vs component |\n| --- | ---: | ---: |");
  for (const [name, fn, order] of runs) {
    const expect = order === unsorted ? want : component(order);
    const got = fn();
    got.forEach((g, p) => {
      if (!Buffer.from(g).equals(Buffer.from(expect[p]))) throw new Error(`${name} differs on page ${p}`);
    });
    const t = name.startsWith("html-escape") ? base : time(fn);
    console.log(`| ${name} | ${t.toFixed(3)} | ${(t / base).toFixed(2)}× |`);
  }
}
