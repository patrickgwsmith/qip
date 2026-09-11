import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
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
const qip = fileURLToPath(new URL("../qip", import.meta.url));
const bmpToKtx = fileURLToPath(new URL("../image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-rgba32float.wasm", import.meta.url));
const warmFade = fileURLToPath(new URL("../image/ktx2/ktx2-rgba32float-look-warm-fade.wasm", import.meta.url));
const ktxToBmp = fileURLToPath(new URL("../image/ktx2/ktx2-rgba32float-to-bmp-b8g8r8a8-srgb.wasm", import.meta.url));

async function ensurePrerequisites(t) {
  try {
    await access(qip, constants.X_OK);
    await access(bmpToKtx, constants.R_OK);
    await access(warmFade, constants.R_OK);
    await access(ktxToBmp, constants.R_OK);
  } catch {
    t.skip("build ./qip and the KTX2 components first");
  }
}

function buildBMP(width, height, pixelAt, topDown = false) {
  const stride = width * 4;
  const bmp = Buffer.alloc(54 + stride * height);
  bmp.write("BM", 0, "ascii");
  bmp.writeUInt32LE(bmp.length, 2);
  bmp.writeUInt32LE(54, 10);
  bmp.writeUInt32LE(40, 14);
  bmp.writeInt32LE(width, 18);
  bmp.writeInt32LE(topDown ? -height : height, 22);
  bmp.writeUInt16LE(1, 26);
  bmp.writeUInt16LE(32, 28);
  for (let y = 0; y < height; y += 1) {
    const storedY = topDown ? y : height - 1 - y;
    for (let x = 0; x < width; x += 1) {
      const [r, g, b, a] = pixelAt(x, y);
      bmp.set([b, g, r, a], 54 + storedY * stride + x * 4);
    }
  }
  return bmp;
}

function logicalPixels(bmp) {
  const width = bmp.readInt32LE(18);
  const signedHeight = bmp.readInt32LE(22);
  const height = Math.abs(signedHeight);
  const offset = bmp.readUInt32LE(10);
  const result = [];
  for (let y = 0; y < height; y += 1) {
    const storedY = signedHeight < 0 ? y : height - 1 - y;
    for (let x = 0; x < width; x += 1) {
      const p = offset + (storedY * width + x) * 4;
      result.push([bmp[p + 2], bmp[p + 1], bmp[p], bmp[p + 3]]);
    }
  }
  return result;
}

async function runPipeline(modules, inputPath, outputPath) {
  await execFileP(qip, ["run", ...modules, "-i", inputPath, "-o", outputPath]);
  return readFile(outputPath);
}

test("BMP converts to the canonical linear RGBA32F KTX2 profile", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-ktx2-"));
  const bmp = buildBMP(2, 2, (x, y) => [x ? 255 : 64, y ? 128 : 32, 16, 255 - x * 80]);
  const input = join(dir, "in.bmp");
  await writeFile(input, bmp);
  const ktx = await runPipeline([bmpToKtx], input, join(dir, "out.ktx2"));

  assert.deepEqual([...ktx.subarray(0, 12)], [0xab, 0x4b, 0x54, 0x58, 0x20, 0x32, 0x30, 0xbb, 0x0d, 0x0a, 0x1a, 0x0a]);
  assert.equal(ktx.readUInt32LE(12), 109, "VK_FORMAT_R32G32B32A32_SFLOAT");
  assert.equal(ktx.readUInt32LE(16), 4, "component byte size");
  assert.equal(ktx.readUInt32LE(20), 2);
  assert.equal(ktx.readUInt32LE(24), 2);
  assert.equal(ktx.readUInt32LE(36), 1, "face count");
  assert.equal(ktx.readUInt32LE(40), 1, "level count");
  assert.equal(ktx.readUInt32LE(44), 0, "no supercompression");
  assert.equal(Number(ktx.readBigUInt64LE(80)), 224, "pixel payload offset");
  assert.equal(Number(ktx.readBigUInt64LE(88)), 64, "pixel payload bytes");
  assert.equal(ktx.length, 288);
  const expectedRed = Math.pow((64 / 255 + 0.055) / 1.055, 2.4);
  assert.ok(Math.abs(ktx.readFloatLE(224) - expectedRed) < 1e-7);
  assert.equal(ktx.readFloatLE(236), 1);
});

test("BMP to KTX2 to BMP is pixel-exact for both BMP row orders", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-ktx2-roundtrip-"));
  for (const topDown of [false, true]) {
    const bmp = buildBMP(17, 9, (x, y) => [x * 15, y * 29, (x * 7 + y * 13) & 255, (x * 19 + y * 5) & 255], topDown);
    const input = join(dir, topDown ? "top.bmp" : "bottom.bmp");
    await writeFile(input, bmp);
    const output = await runPipeline([bmpToKtx, ktxToBmp], input, join(dir, topDown ? "top-out.bmp" : "bottom-out.bmp"));
    assert.deepEqual(logicalPixels(output), logicalPixels(bmp));
  }
});

test("Warm Fade applies its LUT, preserves alpha, and supports strength", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-ktx2-look-"));
  const bmp = buildBMP(3, 1, (x) => [x * 96 + 24, x * 88 + 32, x * 72 + 40, 41 + x * 79]);
  const input = join(dir, "in.bmp");
  await writeFile(input, bmp);

  const identity = await runPipeline([bmpToKtx, warmFade, "?strength=0", ktxToBmp], input, join(dir, "identity.bmp"));
  assert.deepEqual(logicalPixels(identity), logicalPixels(bmp), "zero strength must be pixel-exact");

  const looked = await runPipeline([bmpToKtx, warmFade, ktxToBmp], input, join(dir, "looked.bmp"));
  const before = logicalPixels(bmp);
  const after = logicalPixels(looked);
  assert.notDeepEqual(after, before);
  assert.deepEqual(after.map((pixel) => pixel[3]), before.map((pixel) => pixel[3]), "alpha changed");
  assert.ok(after[1][0] > after[1][2], "midtone should receive a restrained warm bias");
});

test("Warm Fade returns a separate buffer for its modified output", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-ktx2-look-buffer-"));
  const bmpPath = join(dir, "in.bmp");
  await writeFile(bmpPath, buildBMP(1, 1, () => [64, 96, 128, 255]));
  const input = await runPipeline([bmpToKtx], bmpPath, join(dir, "in.ktx2"));
  const bytes = await readFile(warmFade);
  const { instance } = await WebAssembly.instantiate(bytes, {});
  new Uint8Array(instance.exports.memory.buffer, instance.exports.input_ptr(), input.length).set(input);
  qipRenderSize(instance.exports, input.length);
  assert.notEqual(instance.exports.input_ptr(), qipRenderedOutputPointer(instance.exports));
  assert.equal(instance.exports.input_bytes_cap(), instance.exports.output_bytes_cap());
});

test("KTX2 components reject a profile mismatch", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-ktx2-invalid-"));
  const input = join(dir, "in.bmp");
  await writeFile(input, buildBMP(1, 1, () => [128, 128, 128, 255]));
  const ktx = await runPipeline([bmpToKtx], input, join(dir, "valid.ktx2"));
  ktx.writeUInt32LE(97, 12); // VK_FORMAT_R16G16B16A16_SFLOAT
  const invalid = join(dir, "invalid.ktx2");
  await writeFile(invalid, ktx);
  await assert.rejects(execFileP(qip, ["run", warmFade, "-i", invalid, "-o", join(dir, "out.ktx2")]));
});
