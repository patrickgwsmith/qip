import { renderSize as qipRenderSize } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { access, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileP = promisify(execFile);
const path = (relative) => fileURLToPath(new URL(relative, import.meta.url));
const qip = path("../qip");
const bmpToKtx = path("../image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-r8g8b8a8-srgb.wasm");
const bmpToBgraKtx = path("../image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-b8g8r8a8-srgb.wasm");
const bmpToLossless = path("../image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossless.wasm");
const bmpToLossy = path("../image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy.wasm");
const webpToBmp = path("../image/webp/webp-to-bmp-b8g8r8a8-srgb.wasm");
const webpToKtx = path("../image/webp/webp-to-ktx2-r8g8b8a8-srgb.wasm");
const ktxToLossless = path("../image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-webp-lossless.wasm");
const ktxToLossy = path("../image/ktx2/ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm");

async function ensurePrerequisites(t) {
  try {
    for (const file of [qip, bmpToKtx, bmpToBgraKtx, bmpToLossless, bmpToLossy, webpToBmp,
      webpToKtx, ktxToLossless, ktxToLossy]) {
      await access(file, constants.R_OK);
    }
  } catch {
    t.skip("build qip and the WebP/KTX2 components first");
  }
}

function buildBMP(width, height) {
  const bmp = Buffer.alloc(54 + width * height * 4);
  bmp.write("BM", 0, "ascii");
  bmp.writeUInt32LE(bmp.length, 2);
  bmp.writeUInt32LE(54, 10);
  bmp.writeUInt32LE(40, 14);
  bmp.writeInt32LE(width, 18);
  bmp.writeInt32LE(-height, 22);
  bmp.writeUInt16LE(1, 26);
  bmp.writeUInt16LE(32, 28);
  bmp.writeUInt32LE(width * height * 4, 34);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const offset = 54 + (y * width + x) * 4;
      bmp[offset] = (x * 13 + y * 3) & 255;
      bmp[offset + 1] = (x * 5 + y * 17) & 255;
      bmp[offset + 2] = (x * 19 + y * 7) & 255;
      bmp[offset + 3] = (x + y) % 7 === 0 ? 0 : (x * 23 + y * 29) & 255;
    }
  }
  return bmp;
}

async function run(modules, input, output) {
  await execFileP(qip, ["run", ...modules, "-i", input, "-o", output]);
  return readFile(output);
}

test("direct KTX2 WebP encoders match the existing BMP encoders", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-ktx2-webp-encode-"));
  const bmpPath = join(dir, "input.bmp");
  const ktxPath = join(dir, "input.ktx2");
  const bgraKtxPath = join(dir, "input-bgra.ktx2");
  await writeFile(bmpPath, buildBMP(64, 48));
  await run([bmpToKtx], bmpPath, ktxPath);
  await run([bmpToBgraKtx], bmpPath, bgraKtxPath);

  const bmpLossless = await run([bmpToLossless], bmpPath, join(dir, "bmp-lossless.webp"));
  const ktxLossless = await run([ktxToLossless], ktxPath, join(dir, "ktx-lossless.webp"));
  assert.deepEqual(ktxLossless, bmpLossless);
  const bgraKtxLossless = await run([ktxToLossless], bgraKtxPath, join(dir, "bgra-ktx-lossless.webp"));
  assert.deepEqual(bgraKtxLossless, bmpLossless);

  const bmpLossy = await run([bmpToLossy], bmpPath, join(dir, "bmp-lossy.webp"));
  const ktxLossy = await run([ktxToLossy], ktxPath, join(dir, "ktx-lossy.webp"));
  assert.deepEqual(ktxLossy, bmpLossy);
});

test("direct WebP decoder matches WebP to BMP to canonical KTX2", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-webp-ktx2-decode-"));
  const bmpPath = join(dir, "input.bmp");
  const webpPath = join(dir, "input.webp");
  await writeFile(bmpPath, buildBMP(31, 23));
  await run([bmpToLossless], bmpPath, webpPath);

  const direct = await run([webpToKtx], webpPath, join(dir, "direct.ktx2"));
  const throughBmp = await run([webpToBmp, bmpToKtx], webpPath, join(dir, "through-bmp.ktx2"));
  assert.deepEqual(direct, throughBmp);
  assert.equal(direct.readUInt32LE(12), 43);
  assert.equal(direct.subarray(215, 218).toString("ascii"), "rd\0");
});

test("lossless direct round trip preserves canonical RGBA bytes", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-ktx2-webp-roundtrip-"));
  const bmpPath = join(dir, "input.bmp");
  const ktxPath = join(dir, "input.ktx2");
  await writeFile(bmpPath, buildBMP(29, 17));
  const original = await run([bmpToKtx], bmpPath, ktxPath);
  const roundTrip = await run([ktxToLossless, webpToKtx], ktxPath, join(dir, "round-trip.ktx2"));
  assert.deepEqual(roundTrip, original, "transparent RGB and alpha must remain exact");
});

test("KTX2 WebP encoder swaps disposable input R/B bytes in place", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-ktx2-webp-swap-"));
  const bmpPath = join(dir, "input.bmp");
  const ktxPath = join(dir, "input.ktx2");
  await writeFile(bmpPath, buildBMP(2, 1));
  const ktx = await run([bmpToKtx], bmpPath, ktxPath);

  const wasm = await readFile(ktxToLossy);
  const { instance: { exports } } = await WebAssembly.instantiate(wasm, {});
  const memory = new Uint8Array(exports.memory.buffer);
  memory.set(ktx, exports.input_ptr());
  const before = [...ktx.subarray(224, 228)];
  assert.ok(qipRenderSize(exports, ktx.length) > 0);
  const after = [...memory.subarray(exports.input_ptr() + 224, exports.input_ptr() + 228)];
  assert.deepEqual(after, [before[2], before[1], before[0], before[3]]);
});

test("lossless KTX2 WebP encoder leaves BGRA payload bytes unchanged", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-ktx2-webp-bgra-"));
  const bmpPath = join(dir, "input.bmp");
  const ktxPath = join(dir, "input.ktx2");
  await writeFile(bmpPath, buildBMP(2, 1));
  const ktx = await run([bmpToBgraKtx], bmpPath, ktxPath);

  const wasm = await readFile(ktxToLossless);
  const { instance: { exports } } = await WebAssembly.instantiate(wasm, {});
  const memory = new Uint8Array(exports.memory.buffer);
  memory.set(ktx, exports.input_ptr());
  const before = [...ktx.subarray(224, 232)];
  assert.ok(qipRenderSize(exports, ktx.length) > 0);
  const after = [...memory.subarray(exports.input_ptr() + 224, exports.input_ptr() + 232)];
  assert.deepEqual(after, before);
});

test("KTX2 WebP encoders reject a mismatched Vulkan format and DFD", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-ktx2-webp-invalid-"));
  const bmpPath = join(dir, "input.bmp");
  const ktxPath = join(dir, "input.ktx2");
  await writeFile(bmpPath, buildBMP(1, 1));
  const ktx = await run([bmpToKtx], bmpPath, ktxPath);
  ktx.writeUInt32LE(50, 12);

  const wasm = await readFile(ktxToLossy);
  const { instance: { exports } } = await WebAssembly.instantiate(wasm, {});
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), ktx.length).set(ktx);
  assert.equal(qipRenderSize(exports, ktx.length), 0);
});
