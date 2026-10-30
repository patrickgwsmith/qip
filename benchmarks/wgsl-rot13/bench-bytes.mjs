// Node: the wasm builds of rot13.wgsl and rot13_bytes.wgsl against Zig SIMD.
// Run from the repository root: node benchmarks/wgsl-rot13/bench-bytes.mjs
import { readFileSync } from "node:fs";
import { CORPUS_FILES } from "./bench-core.mjs";

const dir = "benchmarks/wgsl-rot13/";
const parts = CORPUS_FILES.map((f) => readFileSync(f));
function corpus(size) {
  const out = new Uint8Array(size);
  for (let o = 0; o < size;) for (const p of parts) {
    const n = Math.min(p.length, size - o);
    out.set(p.subarray(0, n), o);
    if ((o += n) === size) break;
  }
  return out;
}
async function load(name) {
  const { instance } = await WebAssembly.instantiate(readFileSync(dir + name));
  const e = instance.exports;
  return (input) => {
    new Uint8Array(e.memory.buffer, e.input_ptr(), input.length).set(input);
    const r = BigInt.asUintN(64, e.render(input.length));
    if (r >> 63n) throw new Error(`${name} rejected`);
    return new Uint8Array(e.memory.buffer, Number(r >> 32n), Number(r & 0xffffffffn)).slice();
  };
}
function time(fn, input) {
  for (let i = 0; i < 20; i++) fn(input);
  let reps = 0;
  for (const t0 = performance.now(); performance.now() - t0 < 5;) { fn(input); reps++; }
  const samples = [];
  for (let r = 0; r < 30; r++) {
    const t0 = performance.now();
    for (let i = 0; i < reps; i++) fn(input);
    samples.push((performance.now() - t0) / reps);
  }
  return samples.sort((a, b) => a - b)[15];
}
const builds = [
  ["Zig SIMD", "rot13_zig_simd.wasm"],
  ["rot13.wgsl vec4", "rot13_wgsl_vec4.wasm"],
  ["rot13.wgsl vec4, v128 loads", "rot13_wgsl_vec4_v128.wasm"],
  ["rot13_bytes.wgsl i8x16", "rot13_bytes_wgsl.wasm"],
];
const fns = await Promise.all(builds.map(([, file]) => load(file)));
console.log(`| Input | ${builds.map(([name]) => name).join(" | ")} |`);
console.log(`| --- |${" ---: |".repeat(builds.length)}`);
for (const [label, size] of [["64 KiB", 1 << 16], ["1 MiB", 1 << 20], ["4 MiB", 4 << 20]]) {
  const input = corpus(size);
  const want = Buffer.from(fns[0](input));
  const times = fns.map((fn, i) => {
    if (!want.equals(Buffer.from(fn(input)))) throw new Error(`${builds[i][0]} differs at ${label}`);
    return time(fn, input);
  });
  console.log(`| ${label} | ${times.map((t) => `${t.toFixed(3)} (${(t / times[0]).toFixed(2)}×)`).join(" | ")} |`);
}
