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
const bmpToPng = path("../image/bmp/bmp-to-png.wasm");
const pngToBmp = path("../image/png/png-to-bmp-b8g8r8a8-srgb.wasm");
const pngToKtx = path("../image/png/png-to-ktx2-r8g8b8a8-srgb.wasm");
const bmpToRgbaKtx = path("../image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-r8g8b8a8-srgb.wasm");
const bmpToBgraKtx = path("../image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-b8g8r8a8-srgb.wasm");
const rgbaKtxToBmp = path("../image/ktx2/ktx2-r8g8b8a8-srgb-to-bmp-b8g8r8a8-srgb.wasm");
const bgraKtxToBmp = path("../image/ktx2/ktx2-b8g8r8a8-srgb-to-bmp-b8g8r8a8-srgb.wasm");
const ktxToPng = path("../image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-png.wasm");
const bmpToAvif = path("../image/bmp/bmp-b8g8r8a8-srgb-to-avif-lossy.wasm");
const ktxToAvif = path("../image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-avif-lossy.wasm");
const avifToKtx = path("../image/avif/avif-to-ktx2-r8g8b8a8-srgb.wasm");
const bmpToJpeg = path("../image/bmp/bmp-b8g8r8a8-srgb-to-jpeg-lossy.wasm");
const jpegToBmp = path("../image/jpeg/jpeg-to-bmp-b8g8r8a8-srgb.wasm");
const jpegToKtx = path("../image/jpeg/jpeg-to-ktx2-r8g8b8a8-srgb.wasm");
const zigJpegToKtx = path("../image/jpeg/jpeg-to-ktx2-r8g8b8a8-srgb-zig-progressive.wasm");
const progressiveJpeg = path("../fixtures/j-g-d-uP-haUp0YQw-unsplash.jpg");
const ktxToJpeg = path("../image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jpeg-lossy.wasm");
const svgToBmp = path("../image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm");
const svgToKtx = path("../image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm");

const prerequisites = [qip, bmpToPng, pngToBmp, pngToKtx, bmpToRgbaKtx,
  bmpToBgraKtx, rgbaKtxToBmp, bgraKtxToBmp, ktxToPng, bmpToAvif, ktxToAvif,
  avifToKtx, bmpToJpeg, jpegToBmp, jpegToKtx, zigJpegToKtx, ktxToJpeg,
  svgToBmp, svgToKtx];

async function ensurePrerequisites(t) {
  try {
    for (const file of prerequisites) await access(file, constants.R_OK);
  } catch {
    t.skip("build qip and the PNG, AVIF, BMP, and KTX2 components first");
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

function jpegFrameMarker(bytes) {
  let offset = 2;
  while (offset + 3 < bytes.length && bytes[offset] === 0xff) {
    while (bytes[offset] === 0xff) offset += 1;
    const marker = bytes[offset++];
    if (marker === 0xd9 || marker === 0xda) break;
    if (marker >= 0xd0 && marker <= 0xd7) continue;
    const size = bytes.readUInt16BE(offset);
    if (size < 2 || offset + size > bytes.length) break;
    if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) {
      return marker;
    }
    offset += size;
  }
  return undefined;
}

function markJpegAsRgb(bytes) {
  const adobe = Buffer.from([
    0xff, 0xee, 0x00, 0x0e,
    0x41, 0x64, 0x6f, 0x62, 0x65, 0x00, 0x64, 0x00, 0x00, 0x00, 0x00, 0x00,
  ]);
  let bodyOffset = 2;
  if (bytes[2] === 0xff && bytes[3] === 0xe0) {
    const size = bytes.readUInt16BE(4);
    const payload = bytes.subarray(6, 4 + size);
    if (payload.subarray(0, 5).toString("binary") === "JFIF\0") {
      bodyOffset = 4 + size;
    }
  }
  const rgb = Buffer.concat([bytes.subarray(0, 2), adobe, bytes.subarray(bodyOffset)]);
  const ids = [0x52, 0x47, 0x42]; // R, G, B
  let offset = 2;
  while (offset + 3 < rgb.length) {
    assert.equal(rgb[offset++], 0xff);
    while (rgb[offset] === 0xff) offset += 1;
    const marker = rgb[offset++];
    const size = rgb.readUInt16BE(offset);
    const payload = offset + 2;
    if ([0xc0, 0xc1, 0xc2].includes(marker)) {
      assert.equal(rgb[payload + 5], 3);
      for (let component = 0; component < 3; component += 1) {
        rgb[payload + 6 + component * 3] = ids[component];
      }
    } else if (marker === 0xda) {
      assert.equal(rgb[payload], 3);
      for (let component = 0; component < 3; component += 1) {
        rgb[payload + 1 + component * 2] = ids[component];
      }
      return rgb;
    }
    offset += size;
  }
  assert.fail("JPEG must contain a start-of-scan marker");
}

test("direct PNG decoder matches PNG through BMP to canonical KTX2", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-png-ktx2-decode-"));
  const bmpPath = join(dir, "input.bmp");
  const pngPath = join(dir, "input.png");
  await writeFile(bmpPath, buildBMP(37, 23));
  await run([bmpToPng], bmpPath, pngPath);

  const direct = await run([pngToKtx], pngPath, join(dir, "direct.ktx2"));
  const throughBmp = await run([pngToBmp, bmpToRgbaKtx], pngPath, join(dir, "through-bmp.ktx2"));
  assert.deepEqual(direct, throughBmp);
  assert.equal(direct.readUInt32LE(12), 43);
  assert.equal(direct.subarray(215, 218).toString("ascii"), "rd\0");
});

test("direct PNG encoder accepts RGBA and BGRA KTX2 with identical pixels", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-ktx2-png-encode-"));
  const bmpPath = join(dir, "input.bmp");
  const rgbaPath = join(dir, "rgba.ktx2");
  const bgraPath = join(dir, "bgra.ktx2");
  await writeFile(bmpPath, buildBMP(41, 29));
  await run([bmpToRgbaKtx], bmpPath, rgbaPath);
  await run([bmpToBgraKtx], bmpPath, bgraPath);

  const expected = await run([bmpToPng], bmpPath, join(dir, "expected.png"));
  const rgba = await run([ktxToPng], rgbaPath, join(dir, "rgba.png"));
  const bgra = await run([ktxToPng], bgraPath, join(dir, "bgra.png"));
  assert.deepEqual(rgba, expected);
  assert.deepEqual(bgra, expected);
});

test("direct AVIF encoder accepts RGBA and BGRA KTX2 without changing the encode", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-ktx2-avif-encode-"));
  const bmpPath = join(dir, "input.bmp");
  const rgbaPath = join(dir, "rgba.ktx2");
  const bgraPath = join(dir, "bgra.ktx2");
  await writeFile(bmpPath, buildBMP(64, 48));
  await run([bmpToRgbaKtx], bmpPath, rgbaPath);
  await run([bmpToBgraKtx], bmpPath, bgraPath);

  const expected = await run([bmpToAvif], bmpPath, join(dir, "expected.avif"));
  const rgba = await run([ktxToAvif], rgbaPath, join(dir, "rgba.avif"));
  const bgra = await run([ktxToAvif], bgraPath, join(dir, "bgra.avif"));
  assert.deepEqual(rgba, expected);
  assert.deepEqual(bgra, expected);
});

test("AVIF records sRGB CICP and decodes directly to canonical KTX2", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-avif-ktx2-decode-"));
  const bmpPath = join(dir, "input.bmp");
  const avifPath = join(dir, "input.avif");
  await writeFile(bmpPath, buildBMP(64, 48));
  const avif = await run([bmpToAvif], bmpPath, avifPath);

  const nclx = avif.indexOf(Buffer.from("nclx"));
  assert.ok(nclx >= 0, "AVIF should contain nclx CICP metadata");
  assert.equal(avif.readUInt16BE(nclx + 4), 1); // BT.709 primaries
  assert.equal(avif.readUInt16BE(nclx + 6), 13); // sRGB transfer
  assert.equal(avif.readUInt16BE(nclx + 8), 6); // BT.601 matrix

  const ktx = await run([avifToKtx], avifPath, join(dir, "decoded.ktx2"));
  assert.equal(ktx.readUInt32LE(12), 43);
  assert.equal(ktx.readUInt32LE(20), 64);
  assert.equal(ktx.readUInt32LE(24), 48);
  assert.equal(ktx.subarray(215, 218).toString("ascii"), "rd\0");

  const hdr = Buffer.from(avif);
  hdr.writeUInt16BE(16, nclx + 6); // SMPTE ST 2084 (PQ), not sRGB.
  const hdrPath = join(dir, "hdr-tagged.avif");
  await writeFile(hdrPath, hdr);
  const rejected = await run([avifToKtx], hdrPath, join(dir, "hdr.ktx2"));
  assert.equal(rejected.length, 0);
});

test("direct JPEG routes match their BMP equivalents", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-jpeg-ktx2-"));
  const bmpPath = join(dir, "input.bmp");
  const jpegPath = join(dir, "input.jpg");
  const rgbaPath = join(dir, "input.ktx2");
  const bmp = buildBMP(64, 48);
  for (let i = 57; i < bmp.length; i += 4) bmp[i] = 255;
  await writeFile(bmpPath, bmp);
  await run([bmpToJpeg], bmpPath, jpegPath);
  await run([bmpToRgbaKtx], bmpPath, rgbaPath);

  const directDecode = await run([jpegToKtx], jpegPath, join(dir, "direct.ktx2"));
  const throughBmp = await run([jpegToBmp, bmpToRgbaKtx], jpegPath, join(dir, "through-bmp.ktx2"));
  assert.deepEqual(directDecode, throughBmp);

  const directEncode = await run([ktxToJpeg], rgbaPath, join(dir, "direct.jpg"));
  const throughBmpEncode = await run([bmpToJpeg], bmpPath, join(dir, "through-bmp.jpg"));
  assert.deepEqual(directEncode, throughBmpEncode);
});

test("direct JPEG decoder accepts progressive Huffman JPEG", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-progressive-jpeg-ktx2-"));
  const jpeg = await readFile(progressiveJpeg);
  assert.equal(jpegFrameMarker(jpeg), 0xc2, "fixture must be progressive JPEG");

  const ktx = await run([jpegToKtx], progressiveJpeg, join(dir, "decoded.ktx2"));
  assert.equal(ktx.readUInt32LE(12), 43);
  assert.equal(ktx.readUInt32LE(20), 4032);
  assert.equal(ktx.readUInt32LE(24), 3024);
  assert.equal(ktx.length, 224 + 4032 * 3024 * 4);
  assert.equal(ktx[224 + 3], 255);
  assert.equal(ktx[ktx.length - 1], 255);
});

test("self-contained Zig JPEG decoder handles encoded RGB components", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-rgb-jpeg-zig-"));
  const bmpPath = join(dir, "input.bmp");
  const jpegPath = join(dir, "rgb.jpg");
  await writeFile(bmpPath, buildBMP(37, 23));
  const encoded = await run([bmpToJpeg], bmpPath, join(dir, "encoded.jpg"));
  await writeFile(jpegPath, markJpegAsRgb(encoded));

  const ycbcr = await run([jpegToKtx], join(dir, "encoded.jpg"), join(dir, "ycbcr.ktx2"));
  const reference = await run([jpegToKtx], jpegPath, join(dir, "mozjpeg.ktx2"));
  const decoded = await run([zigJpegToKtx], jpegPath, join(dir, "zig.ktx2"));
  assert.notDeepEqual(reference, ycbcr, "fixture must exercise RGB rather than YCbCr conversion");
  assert.deepEqual(decoded, reference);
});

test("self-contained Zig JPEG decoder matches MozJPEG on progressive input", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-progressive-jpeg-zig-"));
  const reference = await run([jpegToKtx], progressiveJpeg, join(dir, "mozjpeg.ktx2"));
  const decoded = await run([zigJpegToKtx], progressiveJpeg, join(dir, "zig.ktx2"));
  assert.deepEqual(decoded, reference);
});

test("SVG rasterizer writes the same canonical pixels without BMP", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-svg-ktx2-"));
  const svgPath = join(dir, "input.svg");
  await writeFile(svgPath, `<svg xmlns="http://www.w3.org/2000/svg" width="37" height="23"><rect width="37" height="23" fill="#123456"/><circle cx="18" cy="11" r="8" fill="#f08" fill-opacity=".6"/></svg>`);

  const direct = await run([svgToKtx], svgPath, join(dir, "direct.ktx2"));
  const throughBmp = await run([svgToBmp, bmpToRgbaKtx], svgPath, join(dir, "through-bmp.ktx2"));
  assert.deepEqual(direct, throughBmp);
});

test("direct PNG, AVIF, and JPEG encoders reject mismatched KTX2 metadata", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-ktx2-codec-invalid-"));
  const bmpPath = join(dir, "input.bmp");
  const ktxPath = join(dir, "invalid.ktx2");
  await writeFile(bmpPath, buildBMP(2, 1));
  const ktx = await run([bmpToRgbaKtx], bmpPath, ktxPath);
  ktx.writeUInt32LE(50, 12); // BGRA vkFormat with the unchanged RGBA DFD.
  await writeFile(ktxPath, ktx);

  const png = await run([ktxToPng], ktxPath, join(dir, "invalid.png"));
  const avif = await run([ktxToAvif], ktxPath, join(dir, "invalid.avif"));
  const jpeg = await run([ktxToJpeg], ktxPath, join(dir, "invalid.jpg"));
  assert.equal(png.length, 0);
  assert.equal(avif.length, 0);
  assert.equal(jpeg.length, 0);
});
