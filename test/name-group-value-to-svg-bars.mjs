import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const { instance } = await WebAssembly.instantiate(
  readFileSync("text/csv/name-group-value-to-svg-bars.wasm"),
);
const component = instance.exports;

function render(csv) {
  const bytes = Buffer.from(csv);
  assert.ok(bytes.length <= component.input_utf8_cap());
  new Uint8Array(component.memory.buffer, component.input_ptr(), bytes.length).set(bytes);
  const result = component.render(bytes.length);
  if (result >> 63n) return null;
  const length = Number(result & 0xffffffffn);
  const pointer = Number(result >> 32n);
  assert.ok(length <= component.output_utf8_cap());
  return Buffer.from(new Uint8Array(component.memory.buffer, pointer, length)).toString("utf8");
}

test("renders reordered columns, quoted labels, and grouped bars", () => {
  const svg = render('value,group,name\r\n132.4,Scalar,"WAT & <C>"\r\n16.7,SIMD,"WAT & <C>"\r\n22,"SIMD, fast",Zig\r\n');
  assert.match(svg, /^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg"/);
  assert.match(svg, /WAT &amp; &lt;C&gt;/);
  assert.match(svg, /SIMD, fast/);
  assert.match(svg, /<rect x="300" y="120" width="700" height="16" fill="#2563eb"\/>/);
  assert.match(svg, />132\.4<\/text>/);
});

test("rejects malformed rows and can render again after rejection", () => {
  for (const csv of [
    "name,group,value\nWAT,Scalar,1\nWAT,Scalar,2\n",
    "name,group,value\nWAT,Scalar,NaN\n",
    "name,group,value\nWAT,Scalar,-1\n",
    'name,group,value\n"WAT,Scalar,1\n',
    "name,group,value\nWAT,Scalar,1,extra\n",
  ]) {
    assert.equal(render(csv), null, csv);
    assert.match(render("name,group,value\nWAT,Scalar,1\n"), />WAT<\/text>/);
  }
});

test("renders the maximum number of names and groups", () => {
  const rows = ["name,group,value"];
  for (let name = 0; name < 32; name++) {
    for (let group = 0; group < 8; group++) {
      rows.push(`Name ${name},Group ${group},${name * 8 + group}`);
    }
  }
  const svg = render(`${rows.join("\n")}\n`);
  assert.match(svg, />Name 31<\/text>/);
  assert.match(svg, />255<\/text>/);
});
