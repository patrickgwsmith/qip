import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function decode(result) {
  const bits = BigInt.asUintN(64, result);
  return { size: Number(bits & 0xffff_ffffn), pointer: Number((bits >> 32n) & 0x7fff_ffffn), failed: Number(bits >> 63n) };
}

function run(exports, text, uniforms = {}) {
  const bytes = encoder.encode(text);
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), bytes.length).set(bytes);
  for (const [name, value] of Object.entries(uniforms)) assert.equal(exports[`uniform_set_${name}`](value), value);
  const result = decode(exports.render(bytes.length));
  if (result.failed) return null;
  return decoder.decode(new Uint8Array(exports.memory.buffer, result.pointer, result.size));
}

async function instance(path) {
  return new WebAssembly.Instance(new WebAssembly.Module(await readFile(path))).exports;
}

const csv = `fiscal_quarter,revenue
FY2025Q3,$94B
FY2025Q4,$102.5B
FY2026Q1,$124.3B
FY2026Q2,$95.4B
FY2026Q3,$94B
FY2026Q4,$110B
`;

test("fiscal-quarter bars chain through y-axis, quarter x-axis and rolling mean", async () => {
  const bars = await instance("text/csv/fiscal-quarter-csv-to-svg-bars.wasm");
  const yAxis = await instance("image/svg+xml/svg-bars-add-y-axis.wasm");
  const xAxis = await instance("image/svg+xml/svg-bars-add-quarter-x-axis.wasm");
  const rolling = await instance("image/svg+xml/svg-bars-add-rolling-mean.wasm");

  const core = run(bars, csv);
  assert.match(core, /data-value-min="0" data-value-max="125" data-value-step="25" data-label-prefix="\$" data-label-suffix="B"/);
  assert.equal((core.match(/data-fiscal-quarter=/g) ?? []).length, 6);
  assert.match(core, /<title>FY2026Q1: \$124\.3B<\/title>/);

  const withY = run(yAxis, core);
  assert.deepEqual([...withY.matchAll(/>(-?\$[\d.]+B)<\/text>/g)].map((m) => m[1]), ["$0B", "$25B", "$50B", "$75B", "$100B", "$125B"]);
  assert.ok(withY.indexOf('data-layer="y-axis"') < withY.indexOf('data-layer="bars"'));

  const withX = run(xAxis, withY);
  assert.deepEqual([...withX.matchAll(/font-size="11">(Q\d)</g)].map((m) => m[1]), ["Q3", "Q4", "Q1", "Q2", "Q3", "Q4"]);
  assert.deepEqual([...withX.matchAll(/font-weight="bold">(’\d\d)</g)].map((m) => m[1]), ["’25", "’26"]);

  const withMean = run(rolling, withX);
  const points = withMean.match(/data-layer="rolling-mean" data-window-size="4" points="([^"]+)"/)[1].split(" ");
  assert.equal(points.length, 3);
  // Mean of the first four quarters is 104.05; y = 344 - 104.05 / 125 * 320.
  assert.equal(Number(points[0].split(",")[1]), 77.63);

  // Uniforms reset after each render.
  assert.match(run(rolling, withX, { window_size: 2 }), /data-window-size="2"/);
  assert.match(run(rolling, withX), /data-window-size="4"/);
  assert.equal((run(yAxis, core, { tick_count: 10 }).match(/<\/text>/g) ?? []).length, 7);
  assert.equal((run(yAxis, core).match(/<\/text>/g) ?? []).length, 6);
});

test("fiscal-quarter bars reject invalid input recoverably", async () => {
  const bars = await instance("text/csv/fiscal-quarter-csv-to-svg-bars.wasm");
  assert.equal(run(bars, "fiscal_quarter,v\nFY2026Q1,1\nFY2026Q3,2\n"), null);
  assert.equal(run(bars, "fiscal_quarter,v\nFY2026Q1,$1B\nFY2026Q2,2B\n"), null);
  assert.equal(run(bars, "fiscal_quarter,v\nFY2026Q1,\"1\"\n"), null);
  assert.ok(run(bars, "fiscal_quarter,v\nFY2026Q1,1\n"));

  const yAxis = await instance("image/svg+xml/svg-bars-add-y-axis.wasm");
  assert.equal(run(yAxis, "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>"), null);
});
