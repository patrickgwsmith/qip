import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";

const directory = fileURLToPath(new URL(".", import.meta.url));
const componentPath = fileURLToPath(new URL(
  "../../text/javascript/js-syntax-highlight-html.wasm",
  import.meta.url,
));
const manifest = JSON.parse(await readFile(`${directory}/fixtures.json`, "utf8"));
const fixture = manifest.find((candidate) => candidate.name === "three-minified");
const response = await fetch(fixture.url);
if (!response.ok) throw new Error(`fixture returned HTTP ${response.status}`);
const fixtureBytes = new Uint8Array(await response.arrayBuffer());
const digest = createHash("sha256").update(fixtureBytes).digest("hex");
if (fixtureBytes.length !== fixture.bytes || digest !== fixture.sha256) {
  throw new Error("fixture does not match its manifest");
}

const copies = 10;
const input = new Uint8Array(fixtureBytes.length * copies);
for (let index = 0; index < copies; index += 1) {
  input.set(fixtureBytes, index * fixtureBytes.length);
}

const wasm = await readFile(componentPath);
const { instance } = await WebAssembly.instantiate(wasm);
const exports = instance.exports;
if (input.length > exports.input_utf8_cap()) throw new Error("input exceeds component capacity");

function render() {
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.length).set(input);
  const packed = BigInt.asUintN(64, exports.render(input.length));
  if ((packed & (1n << 63n)) !== 0n) throw new Error("component rejected the fixture");
  const outputLength = Number(packed & 0xffff_ffffn);
  const outputPointer = Number((packed >> 32n) & 0x7fff_ffffn);
  return Buffer.from(new Uint8Array(exports.memory.buffer, outputPointer, outputLength));
}

const expected = render();
const samples = [];
for (let run = 0; run < 10; run += 1) {
  const start = performance.now();
  const output = render();
  samples.push(performance.now() - start);
  if (!output.equals(expected)) throw new Error(`output changed on run ${run + 1}`);
}

const sorted = [...samples].sort((left, right) => left - right);
const mean = samples.reduce((sum, sample) => sum + sample, 0) / samples.length;
const percentile = (fraction) => sorted[Math.ceil(sorted.length * fraction) - 1];
console.table({
  mean_ms: mean.toFixed(2),
  p50_ms: percentile(0.5).toFixed(2),
  p95_ms: percentile(0.95).toFixed(2),
  max_ms: sorted.at(-1).toFixed(2),
  input_bytes: input.length,
  output_bytes: expected.length,
  output_sha256: createHash("sha256").update(expected).digest("hex"),
  node: process.versions.node,
  v8: process.versions.v8,
});
