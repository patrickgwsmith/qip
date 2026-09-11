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
const bmpToKtx = fileURLToPath(new URL("../image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-b8g8r8a8-srgb.wasm", import.meta.url));
const ktxToBmp = fileURLToPath(new URL("../image/ktx2/ktx2-b8g8r8a8-srgb-to-bmp-b8g8r8a8-srgb.wasm", import.meta.url));

async function ensurePrerequisites(t) {
  try {
    await access(qip, constants.X_OK);
    await access(bmpToKtx, constants.R_OK);
    await access(ktxToBmp, constants.R_OK);
  } catch {
    t.skip("build ./qip and the BGRA8 sRGB KTX2 components first");
  }
}

function buildBMP(width, height, pixelAt, topDown = false) {
  const rowBytes = width * 4;
  const bmp = Buffer.alloc(54 + rowBytes * height);
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
      bmp.set([b, g, r, a], 54 + (storedY * width + x) * 4);
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
      result.push([...bmp.subarray(p, p + 4)]);
    }
  }
  return result;
}

async function runPipeline(modules, inputPath, outputPath) {
  await execFileP(qip, ["run", ...modules, "-i", inputPath, "-o", outputPath]);
  return readFile(outputPath);
}

function reversePayloadRows(ktx) {
  const width = ktx.readUInt32LE(20);
  const height = ktx.readUInt32LE(24);
  const offset = Number(ktx.readBigUInt64LE(80));
  const rowBytes = width * 4;
  const copy = Buffer.from(ktx.subarray(offset, offset + rowBytes * height));
  for (let y = 0; y < height; y += 1) {
    copy.copy(ktx, offset + y * rowBytes, (height - 1 - y) * rowBytes, (height - y) * rowBytes);
  }
}

test("BMP wraps as canonical VK_FORMAT_B8G8R8A8_SRGB with unchanged BGRA bytes", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-ktx2-bgra8-"));
  const bmp = buildBMP(2, 2, (x, y) => [20 + x * 70, 30 + y * 80, 40 + x * 9 + y * 11, 50 + x * 60 + y * 20]);
  const input = join(dir, "in.bmp");
  await writeFile(input, bmp);
  const ktx = await runPipeline([bmpToKtx], input, join(dir, "out.ktx2"));

  assert.deepEqual([...ktx.subarray(0, 12)], [0xab, 0x4b, 0x54, 0x58, 0x20, 0x32, 0x30, 0xbb, 0x0d, 0x0a, 0x1a, 0x0a]);
  assert.equal(ktx.readUInt32LE(12), 50, "VK_FORMAT_B8G8R8A8_SRGB");
  assert.equal(ktx.readUInt32LE(16), 1);
  assert.equal(ktx[118], 2, "KHR_DF_TRANSFER_SRGB");
  assert.deepEqual([...ktx.subarray(135, 136)], [2], "first DFD sample is blue");
  assert.equal(Number(ktx.readBigUInt64LE(80)), 224);
  assert.equal(Number(ktx.readBigUInt64LE(88)), 16);
  assert.deepEqual([...ktx.subarray(224)], logicalPixels(bmp).flat());
  assert.equal(ktx.subarray(215, 218).toString("ascii"), "rd\0");
});

test("BGRA8 sRGB round trip is byte-exact for top-down and bottom-up BMP", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-ktx2-bgra8-roundtrip-"));
  for (const topDown of [false, true]) {
    const bmp = buildBMP(19, 7, (x, y) => [x * 13, y * 37, (x * 17 + y * 19) & 255, (x * 23 + y * 29) & 255], topDown);
    const input = join(dir, topDown ? "top.bmp" : "bottom.bmp");
    await writeFile(input, bmp);
    const output = await runPipeline([bmpToKtx, ktxToBmp], input, join(dir, `${topDown ? "top" : "bottom"}-out.bmp`));
    assert.deepEqual(logicalPixels(output), logicalPixels(bmp));
  }
});

test("KTX2 decoder accepts explicit ru and implicit rd orientation", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-ktx2-bgra8-orientation-"));
  const bmp = buildBMP(5, 4, (x, y) => [x * 41, y * 59, x * 17 + y * 13, 255 - y * 31]);
  const bmpPath = join(dir, "in.bmp");
  await writeFile(bmpPath, bmp);
  const canonical = await runPipeline([bmpToKtx], bmpPath, join(dir, "canonical.ktx2"));

  const ru = Buffer.from(canonical);
  ru[216] = "u".charCodeAt(0);
  reversePayloadRows(ru);
  const ruPath = join(dir, "ru.ktx2");
  await writeFile(ruPath, ru);
  const ruBmp = await runPipeline([ktxToBmp], ruPath, join(dir, "ru.bmp"));
  assert.deepEqual(logicalPixels(ruBmp), logicalPixels(bmp));

  const implicit = Buffer.from(canonical);
  implicit.writeUInt32LE(0, 56);
  implicit.writeUInt32LE(0, 60);
  const implicitPath = join(dir, "implicit.ktx2");
  await writeFile(implicitPath, implicit);
  const implicitBmp = await runPipeline([ktxToBmp], implicitPath, join(dir, "implicit.bmp"));
  assert.deepEqual(logicalPixels(implicitBmp), logicalPixels(bmp));
});

test("BGRA8 sRGB decoder rejects a UNORM format claim", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-ktx2-bgra8-invalid-"));
  const bmpPath = join(dir, "in.bmp");
  await writeFile(bmpPath, buildBMP(1, 1, () => [80, 90, 100, 110]));
  const ktx = await runPipeline([bmpToKtx], bmpPath, join(dir, "valid.ktx2"));
  ktx.writeUInt32LE(44, 12); // VK_FORMAT_B8G8R8A8_UNORM
  const invalidPath = join(dir, "invalid.ktx2");
  await writeFile(invalidPath, ktx);
  await assert.rejects(execFileP(qip, ["run", ktxToBmp, "-i", invalidPath, "-o", join(dir, "out.bmp")]));
});
