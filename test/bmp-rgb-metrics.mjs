import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import { constants } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";

const modulePath = fileURLToPath(new URL("../image/bmp/bmp-rgb-metrics.wasm", import.meta.url));

function buildBMP(width, height, changed = false) {
  const stride = width * 4;
  const bmp = Buffer.alloc(54 + stride * height);
  bmp.write("BM", 0, "ascii");
  bmp.writeUInt32LE(bmp.length, 2);
  bmp.writeUInt32LE(54, 10);
  bmp.writeUInt32LE(40, 14);
  bmp.writeInt32LE(width, 18);
  bmp.writeInt32LE(height, 22);
  bmp.writeUInt16LE(1, 26);
  bmp.writeUInt16LE(32, 28);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const offset = 54 + y * stride + x * 4;
      bmp.set([x * 11 & 0xff, y * 13 & 0xff, (x + y) * 7 & 0xff, 255], offset);
    }
  }
  if (changed) bmp[54 + 5 * stride + 7 * 4 + 2] ^= 0x7f;
  return bmp;
}

function writeTarOctal(header, offset, length, value) {
  const encoded = value.toString(8).padStart(length - 1, "0") + "\0";
  header.write(encoded, offset, length, "ascii");
}

function tarEntry(name, body) {
  const header = Buffer.alloc(512);
  header.write(name, 0, 100, "ascii");
  writeTarOctal(header, 100, 8, 0o644);
  writeTarOctal(header, 108, 8, 0);
  writeTarOctal(header, 116, 8, 0);
  writeTarOctal(header, 124, 12, body.length);
  writeTarOctal(header, 136, 12, 0);
  header.fill(0x20, 148, 156);
  header[156] = 0x30;
  header.write("ustar\0", 257, 6, "ascii");
  header.write("00", 263, 2, "ascii");
  const checksum = header.reduce((sum, byte) => sum + byte, 0);
  const checksumText = checksum.toString(8).padStart(6, "0") + "\0 ";
  header.write(checksumText, 148, 8, "ascii");
  const padding = Buffer.alloc((512 - body.length % 512) % 512);
  return Buffer.concat([header, body, padding]);
}

function buildTar(entries) {
  return Buffer.concat([
    ...entries.map(([name, body]) => tarEntry(name, body)),
    Buffer.alloc(1024),
  ]);
}

async function loadComponent(t) {
  try {
    await access(modulePath, constants.R_OK);
  } catch {
    t.skip("build components first");
    return null;
  }
  const wasm = await readFile(modulePath);
  return (await WebAssembly.instantiate(wasm, {})).instance.exports;
}

function render(exports, input) {
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.length).set(input);
  const size = qipRenderSize(exports, input.length);
  return Buffer.from(exports.memory.buffer, qipRenderedOutputPointer(exports), size).toString("utf8");
}

function compare(exports, first, second, reversed = false) {
  const entries = [
    ["reference.bmp", first],
    ["candidate.bmp", second],
  ];
  if (reversed) entries.reverse();
  const result = render(exports, buildTar(entries));
  const size = Buffer.byteLength(result);
  assert.ok(size > 0);
  return JSON.parse(result);
}

test("bmp RGB metrics report exact identity and finite differences", async (t) => {
  const exports = await loadComponent(t);
  if (!exports) return;
  const reference = buildBMP(16, 16);

  const identical = compare(exports, reference, reference);
  assert.equal(identical.identical, true);
  assert.equal(identical.mse_rgb, 0);
  assert.equal(identical.psnr_rgb_db, null);
  assert.equal(identical.ssim_rgb, 1);

  const changed = compare(exports, reference, buildBMP(16, 16, true));
  assert.equal(changed.identical, false);
  assert.ok(changed.mse_rgb > 0);
  assert.ok(Number.isFinite(changed.psnr_rgb_db));
  assert.ok(changed.ssim_rgb > 0 && changed.ssim_rgb < 1);

  const reversed = compare(exports, reference, reference, true);
  assert.equal(reversed.identical, true);
});

test("bmp RGB metrics requires the named two-file ustar profile", async (t) => {
  const exports = await loadComponent(t);
  if (!exports) return;
  const bmp = buildBMP(16, 16);

  assert.equal(render(exports, buildTar([["reference.bmp", bmp]])), "");
  assert.equal(render(exports, buildTar([
    ["reference.bmp", bmp],
    ["reference.bmp", bmp],
    ["candidate.bmp", bmp],
  ])), "");
  assert.equal(render(exports, buildTar([
    ["reference.bmp", bmp],
    ["candidate.bmp", bmp],
    ["notes.txt", Buffer.from("unexpected")],
  ])), "");
  const damagedChecksum = buildTar([
    ["reference.bmp", bmp],
    ["candidate.bmp", bmp],
  ]);
  damagedChecksum[148] ^= 1;
  assert.equal(render(exports, damagedChecksum), "");

  const typePointer = exports.input_content_type_ptr();
  const typeLength = exports.input_content_type_size();
  assert.equal(
    Buffer.from(exports.memory.buffer, typePointer, typeLength).toString("ascii"),
    "application/x-tar",
  );
});
