import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const chronographWasm = await readFile("components/interactive/chronograph.wasm");
const transferWasm = await readFile(
  "image/ktx2/ktx2-rgba32float-display-p3-linear-to-ktx2-rgba32float-display-p3.wasm",
);

function decodeRender(result) {
  const bits = BigInt.asUintN(64, result);
  assert.equal(bits >> 63n, 0n);
  return {
    size: Number(bits & 0xffff_ffffn),
    pointer: Number((bits >> 32n) & 0x7fff_ffffn),
  };
}

test("linear-p3-to-p3 keeps float HDR headroom without packing binary16", () => {
  const chronograph = new WebAssembly.Instance(
    new WebAssembly.Module(chronographWasm),
    {},
  ).exports;
  chronograph.uniform_set_current_seconds(15.2);
  chronograph.uniform_set_hdr(1);
  const source = decodeRender(chronograph.render(0));
  const sourceBytes = new Uint8Array(
    chronograph.memory.buffer,
    source.pointer,
    source.size,
  );
  const sourcePixels = new Float32Array(
    chronograph.memory.buffer,
    source.pointer + 224,
    360 * 360 * 4,
  );

  const transfer = new WebAssembly.Instance(
    new WebAssembly.Module(transferWasm),
    {},
  ).exports;
  new Uint8Array(transfer.memory.buffer, transfer.input_ptr(), source.size).set(sourceBytes);
  const output = decodeRender(transfer.render(source.size));
  assert.equal(output.pointer, transfer.input_ptr());
  assert.equal(output.size, source.size);

  const encodedBytes = new Uint8Array(transfer.memory.buffer, output.pointer, output.size);
  assert.equal(encodedBytes[117], 12, "Display P3 primaries changed");
  assert.equal(encodedBytes[118], 2, "output should use the Display P3 transfer function");
  const encodedPixels = new Float32Array(
    transfer.memory.buffer,
    output.pointer + 224,
    360 * 360 * 4,
  );
  const extendedIndex = sourcePixels.findIndex((value, index) => index % 4 !== 3 && value > 1);
  assert.notEqual(extendedIndex, -1);
  assert.ok(encodedPixels[extendedIndex] > 1, "float output clipped HDR headroom");
  assert.equal(encodedPixels[3], sourcePixels[3], "alpha should remain linear and unchanged");
});
