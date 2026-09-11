import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function decode(result) {
  const bits = BigInt.asUintN(64, result);
  return { size: Number(bits & 0xffff_ffffn), pointer: Number((bits >> 32n) & 0x7fff_ffffn), failed: Number(bits >> 63n) };
}

function render(exports, bytes, windowSize) {
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), bytes.length).set(bytes);
  if (windowSize !== undefined) assert.equal(exports.uniform_set_window_size(windowSize), windowSize);
  const result = decode(exports.render(bytes.length));
  assert.equal(result.failed, 0);
  return new Uint8Array(exports.memory.buffer, result.pointer, result.size);
}

async function instance(path) {
  return new WebAssembly.Instance(new WebAssembly.Module(await readFile(path))).exports;
}

test("time-series CSV renders value-space polylines and chart passes transform every series", async () => {
  const chart = await instance("text/csv/time-series-csv-to-svg-polylines.wasm");
  const ema = await instance("image/svg+xml/svg-polylines-exponential-moving-average.wasm");
  const mean = await instance("image/svg+xml/svg-polylines-rolling-mean.wasm");
  const meanLines = await instance("image/svg+xml/svg-polylines-add-mean-lines.wasm");
  const csv = encoder.encode("date,revenue,costs\n2026-01-01,10,30\n2026-01-02,20,20\n2026-01-03,50,10\n");
  const svg = decoder.decode(render(chart, csv));
  assert.equal((svg.match(/<polyline/g) ?? []).length, 2);
  assert.match(svg, /<g transform="translate\(/);
  assert.equal((svg.match(/vector-effect="non-scaling-stroke"/g) ?? []).length, 2);

  const annualCSV = encoder.encode("date,value\n2025-06-30,2\n2026-02-01,4\n2026-06-30,6\n");
  assert.equal(chart.uniform_set_x_axis_tick_year_interval(1), 1);
  const annualSvg = decoder.decode(render(chart, annualCSV));
  assert.match(annualSvg, />2025<\/text>/);
  assert.match(annualSvg, />2026<\/text>/);
  assert.match(annualSvg, /M 56 360 V 364/);
  const defaultAxisSvg = decoder.decode(render(chart, annualCSV));
  assert.doesNotMatch(defaultAxisSvg, />2025<\/text>/);

  const biannualCSV = encoder.encode("date,value\n2025-06-30,2\n2026-02-01,4\n2027-06-30,6\n");
  assert.equal(chart.uniform_set_x_axis_tick_year_interval(2), 2);
  const biannualSvg = decoder.decode(render(chart, biannualCSV));
  assert.match(biannualSvg, />2025<\/text>/);
  assert.doesNotMatch(biannualSvg, />2026<\/text>/);
  assert.match(biannualSvg, />2027<\/text>/);

  const emaSvg = decoder.decode(render(ema, encoder.encode(svg), 2));
  assert.match(emaSvg, /points="0,10 1,16\.666666666666664 2,38\.888888888888886"/);
  assert.match(emaSvg, /points="0,30 1,23\.333333333333336 2,14\.444444444444446"/);

  const meanSvg = decoder.decode(render(mean, encoder.encode(svg), 2));
  assert.match(meanSvg, /points="0,10 1,15 2,35"/);
  assert.match(meanSvg, /points="0,30 1,25 2,15"/);

  const meanLinesSvg = decoder.decode(render(meanLines, encoder.encode(svg)));
  assert.equal((meanLinesSvg.match(/<polyline/g) ?? []).length, 4);
  assert.match(meanLinesSvg, /points="0,26\.666666666666668 2,26\.666666666666668" fill="none" stroke="#2563eb" stroke-width="2" stroke-dasharray="4 4" vector-effect="non-scaling-stroke"/);
  assert.match(meanLinesSvg, /points="0,20 2,20" fill="none" stroke="#dc2626" stroke-width="2" stroke-dasharray="4 4" vector-effect="non-scaling-stroke"/);
});
