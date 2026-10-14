// Times gui/colosseum.wasm's two renderers on the same fixed views: the
// Build-style sector renderer and the true 3D polygon BSP. Each sample
// renders one 640 by 480 frame on a reused instance, as <qip-play> does.
// Engines alternate sample by sample so background load affects both alike.
//
// Usage: node tools/bench-colosseum-renderers.mjs [module.wasm] [--runs N] [--warmup N] [--csv out.csv]

import { readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import { performance } from "node:perf_hooks";

const args = process.argv.slice(2);
function option(name, fallback) {
  const i = args.indexOf(name);
  if (i < 0) return fallback;
  const value = args[i + 1];
  args.splice(i, 2);
  return value;
}
const runs = Number(option("--runs", 60));
const warmup = Number(option("--warmup", 10));
const csvPath = option("--csv", null);
const path = args[0] ?? "gui/colosseum.wasm";

const VIEWS = ["street", "deck", "hypogeum", "ambulatory", "terrace", "seats"];
const MODES = [
  { name: "sectors", flags: 0 },
  { name: "bsp", flags: 1 },
  { name: "sectors-flat", flags: 2 },
  { name: "bsp-flat", flags: 3 },
];
const PIXEL_BYTES = 640 * 480 * 4;

const exports = new WebAssembly.Instance(new WebAssembly.Module(readFileSync(path)), {}).exports;

function renderFrame() {
  const result = BigInt.asUintN(64, exports.render(0));
  if ((result >> 63n) !== 0n) throw new Error("render failed");
  return Number((result >> 32n) & 0x7fff_ffffn);
}

function pixels(ptr) {
  return new Uint8Array(exports.memory.buffer, ptr + 224, PIXEL_BYTES).slice();
}

function median(sorted) {
  return sorted[sorted.length >> 1];
}

function percentile(sorted, p) {
  return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * p) - 1)];
}

let start = performance.now();
renderFrame();
const levelMs = performance.now() - start;
start = performance.now();
exports.bench_set_view(0, 1);
const bspBuildMs = performance.now() - start;

const rows = [];
for (let v = 0; v < VIEWS.length; v++) {
  const samples = MODES.map(() => []);
  const frames = [];
  const stats = [];
  for (const [m, mode] of MODES.entries()) {
    exports.bench_set_view(v, mode.flags);
    let ptr = 0;
    for (let i = 0; i < warmup; i++) ptr = renderFrame();
    frames[m] = pixels(ptr);
    stats[m] = { visits: exports.bench_stat(0), nodes: exports.bench_stat(1), polys: exports.bench_stat(2) };
  }
  for (let i = 0; i < runs; i++) {
    for (const [m, mode] of MODES.entries()) {
      exports.bench_set_view(v, mode.flags);
      const t0 = performance.now();
      renderFrame();
      samples[m].push(performance.now() - t0);
    }
  }
  let same = 0;
  for (let p = 0; p < 640 * 480; p++) {
    let ok = true;
    for (let c = 0; c < 3; c++) if (Math.abs(frames[0][p * 4 + c] - frames[1][p * 4 + c]) > 8) ok = false;
    if (ok) same++;
  }
  for (const [m, mode] of MODES.entries()) {
    const sorted = samples[m].sort((a, b) => a - b);
    rows.push({
      view: VIEWS[v],
      mode: mode.name,
      median: median(sorted),
      p95: percentile(sorted, 0.95),
      min: sorted[0],
      work: mode.flags & 1 ? `${stats[m].nodes} nodes, ${stats[m].polys} polygons` : `${stats[m].visits} sector visits`,
      agree: (100 * same) / (640 * 480),
    });
  }
}
exports.bench_set_view(-1, 0);

const cpu = os.cpus()[0]?.model ?? "unknown CPU";
console.log(`${path}: ${exports.bench_stat(3)} sectors, ${exports.bench_stat(4)} edges`);
console.log(`polygon BSP: ${exports.bench_stat(5)} polygons, ${exports.bench_stat(6)} nodes, depth ${exports.bench_stat(7)}`);
console.log(`level build ${levelMs.toFixed(1)} ms (first render), BSP build ${bspBuildMs.toFixed(1)} ms`);
console.log(`Node ${process.version}, ${cpu}, load ${os.loadavg().map((n) => n.toFixed(1)).join(" ")}; ${runs} runs after ${warmup} warmup renders`);
console.log("");
console.log("| View | Renderer | Median ms | p95 ms | Min ms | Work | Same pixels |");
console.log("| --- | --- | ---: | ---: | ---: | --- | ---: |");
for (const r of rows) {
  console.log(`| ${r.view} | ${r.mode} | ${r.median.toFixed(2)} | ${r.p95.toFixed(2)} | ${r.min.toFixed(2)} | ${r.work} | ${r.agree.toFixed(2)}% |`);
}
if (csvPath) {
  const lines = ["view,renderer,median_ms,p95_ms,min_ms,work,same_pixels_percent"];
  for (const r of rows) lines.push(`${r.view},${r.mode},${r.median.toFixed(3)},${r.p95.toFixed(3)},${r.min.toFixed(3)},"${r.work}",${r.agree.toFixed(2)}`);
  writeFileSync(csvPath, `${lines.join("\n")}\n`);
}
