import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { promisify } from "node:util";
import { deflateSync, inflateSync } from "node:zlib";
import test from "node:test";

const execFileAsync = promisify(execFile);
const qip = join(process.cwd(), "qip");
const modulePath = join(
  process.cwd(),
  "application/pdf/pdf-extract-images.wasm",
);
const jpegFixture = join(
  process.cwd(),
  "compliance/jpeg-to-bmp-b8g8r8a8-srgb-fixtures/red-16x16-420.jpg",
);

function pdfObject(number, dictionary, stream) {
  return Buffer.concat([
    Buffer.from(`${number} 0 obj\n<< ${dictionary} /Length ${stream.length} >>\nstream\n`),
    stream,
    Buffer.from("\nendstream\nendobj\n"),
  ]);
}

function buildPdf(objects) {
  return Buffer.concat([
    Buffer.from("%PDF-1.7\n%\x80\x81\x82\x83\n", "latin1"),
    ...objects,
    Buffer.from("trailer\n<< /Size 99 >>\n%%EOF\n"),
  ]);
}

function ascii85Encode(input) {
  let output = "";
  for (let offset = 0; offset < input.length; offset += 4) {
    const count = Math.min(4, input.length - offset);
    const block = Buffer.alloc(4);
    input.copy(block, 0, offset, offset + count);
    const value = block.readUInt32BE();
    if (value === 0 && count === 4) {
      output += "z";
      continue;
    }
    const digits = Array(5);
    let remaining = value;
    for (let index = 4; index >= 0; index -= 1) {
      digits[index] = String.fromCharCode((remaining % 85) + 33);
      remaining = Math.floor(remaining / 85);
    }
    output += digits.slice(0, count + 1).join("");
  }
  return Buffer.from(`${output}~>`, "ascii");
}

function tarEntries(tar) {
  const entries = new Map();
  let offset = 0;
  while (offset + 512 <= tar.length) {
    const header = tar.subarray(offset, offset + 512);
    if (header.every((byte) => byte === 0)) break;
    const nameEnd = header.indexOf(0);
    const name = header.subarray(0, nameEnd).toString("utf8");
    const sizeText = header
      .subarray(124, 136)
      .toString("ascii")
      .replace(/\0.*$/, "")
      .trim();
    const size = Number.parseInt(sizeText || "0", 8);
    const body = tar.subarray(offset + 512, offset + 512 + size);
    entries.set(name, Buffer.from(body));
    offset += 512 + Math.ceil(size / 512) * 512;
  }
  return entries;
}

function parsePng(png) {
  assert.deepEqual(
    png.subarray(0, 8),
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
  );
  const width = png.readUInt32BE(16);
  const height = png.readUInt32BE(20);
  const bitDepth = png[24];
  const colorType = png[25];
  const idat = [];
  let palette;
  let offset = 8;
  while (offset < png.length) {
    const size = png.readUInt32BE(offset);
    const kind = png.subarray(offset + 4, offset + 8).toString("ascii");
    if (kind === "IDAT") idat.push(png.subarray(offset + 8, offset + 8 + size));
    if (kind === "PLTE") palette = Buffer.from(png.subarray(offset + 8, offset + 8 + size));
    offset += 12 + size;
    if (kind === "IEND") break;
  }
  return { width, height, bitDepth, colorType, palette, raster: inflateSync(Buffer.concat(idat)) };
}

function parseTiff(tiff) {
  assert.equal(tiff.subarray(0, 4).toString("latin1"), "II*\0");
  const ifdOffset = tiff.readUInt32LE(4);
  const count = tiff.readUInt16LE(ifdOffset);
  const tags = new Map();
  for (let index = 0; index < count; index += 1) {
    const offset = ifdOffset + 2 + index * 12;
    tags.set(tiff.readUInt16LE(offset), {
      type: tiff.readUInt16LE(offset + 2),
      count: tiff.readUInt32LE(offset + 4),
      value: tiff.readUInt32LE(offset + 8),
    });
  }
  const stripOffset = tags.get(273).value;
  const stripLength = tags.get(279).value;
  return { tags, strip: Buffer.from(tiff.subarray(stripOffset, stripOffset + stripLength)) };
}

async function extract(pdf) {
  const directory = await mkdtemp(join(tmpdir(), "qip-pdf-images-"));
  const input = join(directory, "input.pdf");
  const output = join(directory, "images.tar");
  await writeFile(input, pdf);
  await execFileAsync(qip, ["run", "-i", input, "-o", output, "--", modulePath]);
  await execFileAsync("tar", ["-tf", output]);
  return tarEntries(await readFile(output));
}

test("extracts DCT image bytes unchanged", async () => {
  const jpeg = await readFile(jpegFixture);
  const pdf = buildPdf([
    pdfObject(
      4,
      "/Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode",
      jpeg,
    ),
  ]);
  const entries = await extract(pdf);
  assert.deepEqual([...entries.keys()], ["image-0001.jpg"]);
  assert.deepEqual(entries.get("image-0001.jpg"), jpeg);
});

test("extracts JPX bytes unchanged", async () => {
  const jp2 = Buffer.from([
    0, 0, 0, 12, 0x6a, 0x50, 0x20, 0x20, 13, 10, 0x87, 10,
    0xde, 0xad, 0xbe, 0xef,
  ]);
  const pdf = buildPdf([
    pdfObject(
      7,
      "/Type /XObject /Subtype /Image /Width 1 /Height 1 /Filter /JPXDecode",
      jp2,
    ),
  ]);
  const entries = await extract(pdf);
  assert.deepEqual([...entries.keys()], ["image-0001.jp2"]);
  assert.deepEqual(entries.get("image-0001.jp2"), jp2);
});

test("removes an ASCII85 wrapper around a DCT stream", async () => {
  const jpeg = await readFile(jpegFixture);
  const pdf = buildPdf([
    pdfObject(
      8,
      "/Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter [/ASCII85Decode /DCTDecode]",
      ascii85Encode(jpeg),
    ),
  ]);
  const entries = await extract(pdf);
  assert.deepEqual([...entries.keys()], ["image-0001.jpg"]);
  assert.deepEqual(entries.get("image-0001.jpg"), jpeg);
});

test("converts unfiltered and Flate RGB rasters to PNG", async () => {
  const raw = Buffer.from([
    255, 0, 0, 0, 255, 0,
    0, 0, 255, 255, 255, 255,
  ]);
  const pdf = buildPdf([
    pdfObject(
      2,
      "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8",
      raw,
    ),
    pdfObject(
      9,
      "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode",
      deflateSync(raw),
    ),
  ]);
  const entries = await extract(pdf);
  assert.deepEqual([...entries.keys()], ["image-0001.png", "image-0002.png"]);
  for (const name of entries.keys()) {
    const image = parsePng(entries.get(name));
    assert.deepEqual(
      { width: image.width, height: image.height, bitDepth: image.bitDepth, colorType: image.colorType },
      { width: 2, height: 2, bitDepth: 8, colorType: 2 },
    );
    assert.deepEqual(image.raster, Buffer.from([0, ...raw.subarray(0, 6), 0, ...raw.subarray(6)]));
  }
});

test("reuses a Flate PNG predictor stream as PNG IDAT", async () => {
  const filtered = Buffer.from([
    1, 10, 10, 10, 10, 10, 10,
    2, 5, 5, 5, 5, 5, 5,
  ]);
  const compressed = deflateSync(filtered);
  const pdf = buildPdf([
    pdfObject(
      3,
      "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /DecodeParms << /Predictor 15 /Colors 3 /Columns 2 /BitsPerComponent 8 >>",
      compressed,
    ),
  ]);
  const entries = await extract(pdf);
  const png = entries.get("image-0001.png");
  assert.ok(png);
  const image = parsePng(png);
  assert.deepEqual(image.raster, filtered);
  assert.ok(png.includes(compressed));
});

test("emits direct Indexed DeviceRGB data as a paletted PNG", async () => {
  const packedIndices = Buffer.from([0b00011011]);
  const pdf = buildPdf([
    pdfObject(
      10,
      "/Type /XObject /Subtype /Image /Width 4 /Height 1 /ColorSpace [/Indexed /DeviceRGB 3 <ff000000ff0000000fffffffff>] /BitsPerComponent 2",
      packedIndices,
    ),
  ]);
  const entries = await extract(pdf);
  const image = parsePng(entries.get("image-0001.png"));
  assert.deepEqual(
    { width: image.width, height: image.height, bitDepth: image.bitDepth, colorType: image.colorType },
    { width: 4, height: 1, bitDepth: 2, colorType: 3 },
  );
  assert.deepEqual(
    image.palette,
    Buffer.from([
      255, 0, 0,
      0, 255, 0,
      0, 0, 15,
      255, 255, 255,
    ]),
  );
  assert.deepEqual(image.raster, Buffer.from([0, ...packedIndices]));
});

test("expands an Indexed DeviceGray palette through the PNG bit-depth range", async () => {
  const pdf = buildPdf([
    pdfObject(
      11,
      "/Subtype /Image /Width 2 /Height 1 /ColorSpace [/Indexed /DeviceGray 1 <20e0>] /BitsPerComponent 2",
      Buffer.from([0b00010000]),
    ),
  ]);
  const entries = await extract(pdf);
  const image = parsePng(entries.get("image-0001.png"));
  assert.deepEqual(
    image.palette,
    Buffer.from([
      0x20, 0x20, 0x20,
      0xe0, 0xe0, 0xe0,
      0xe0, 0xe0, 0xe0,
      0xe0, 0xe0, 0xe0,
    ]),
  );
});

test("applies grayscale and RGB Decode mappings before writing PNG", async () => {
  const pdf = buildPdf([
    pdfObject(
      12,
      "/Subtype /Image /Width 3 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Decode [1 0]",
      Buffer.from([0, 64, 255]),
    ),
    pdfObject(
      13,
      "/Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Decode [1 0 0 1 1 0]",
      Buffer.from([10, 20, 30]),
    ),
  ]);
  const entries = await extract(pdf);
  assert.deepEqual(
    parsePng(entries.get("image-0001.png")).raster,
    Buffer.from([0, 255, 191, 0]),
  );
  assert.deepEqual(
    parsePng(entries.get("image-0002.png")).raster,
    Buffer.from([0, 245, 20, 225]),
  );
});

test("reverses a PNG predictor before applying a non-default Decode mapping", async () => {
  const filtered = Buffer.from([1, 10, 10]);
  const pdf = buildPdf([
    pdfObject(
      14,
      "/Subtype /Image /Width 2 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Decode [1 0] /Filter /FlateDecode /DecodeParms << /Predictor 15 /Colors 1 /Columns 2 /BitsPerComponent 8 >>",
      deflateSync(filtered),
    ),
  ]);
  const entries = await extract(pdf);
  assert.deepEqual(
    parsePng(entries.get("image-0001.png")).raster,
    Buffer.from([0, 245, 235]),
  );
});

test("applies a reversed Decode range to packed Indexed samples", async () => {
  const pdf = buildPdf([
    pdfObject(
      15,
      "/Subtype /Image /Width 4 /Height 1 /ColorSpace [/Indexed /DeviceRGB 3 <000000550000aa0000ff0000>] /BitsPerComponent 2 /Decode [3 0]",
      Buffer.from([0b00011011]),
    ),
  ]);
  const entries = await extract(pdf);
  assert.deepEqual(
    parsePng(entries.get("image-0001.png")).raster,
    Buffer.from([0, 0b11100100]),
  );
});

test("wraps CCITT Group 4 bytes in a TIFF without recompression", async () => {
  const ccitt = Buffer.from([
    0x33, 0x14, 0xbe, 0x11, 0xdc, 0xef, 0x08, 0x15, 0x04, 0x0a, 0x82,
    0x05, 0x41, 0x02, 0xac, 0x44, 0x58, 0x88, 0xc0, 0x04, 0x00, 0x40,
  ]);
  const pdf = buildPdf([
    pdfObject(
      16,
      "/Subtype /Image /Width 16 /Height 4 /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /CCITTFaxDecode /DecodeParms << /K -1 /Columns 16 /Rows 4 /BlackIs1 true >>",
      ccitt,
    ),
  ]);
  const entries = await extract(pdf);
  assert.deepEqual([...entries.keys()], ["image-0001.tif"]);
  const image = parseTiff(entries.get("image-0001.tif"));
  assert.equal(image.tags.get(256).value, 16);
  assert.equal(image.tags.get(257).value, 4);
  assert.equal(image.tags.get(259).value & 0xffff, 4);
  assert.equal(image.tags.get(262).value & 0xffff, 0);
  assert.equal(image.tags.get(293).value, 0);
  assert.deepEqual(image.strip, ccitt);
});

test("Decode inversion changes CCITT TIFF photometric interpretation", async () => {
  const pdf = buildPdf([
    pdfObject(
      17,
      "/Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 1 /Decode [1 0] /Filter /CCITTFaxDecode /DecodeParms << /K -1 /BlackIs1 false >>",
      Buffer.from([0x80]),
    ),
  ]);
  const entries = await extract(pdf);
  const image = parseTiff(entries.get("image-0001.tif"));
  assert.equal(image.tags.get(262).value & 0xffff, 0);
});

test("skips unsupported filters without leaving numbering gaps", async () => {
  const jpeg = await readFile(jpegFixture);
  const pdf = buildPdf([
    pdfObject(
      1,
      "/Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /JBIG2Decode",
      Buffer.from("unsupported"),
    ),
    pdfObject(
      18,
      "/Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /CCITTFaxDecode /DecodeParms << /K 0 >>",
      Buffer.from([0x80]),
    ),
    pdfObject(
      19,
      "/Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Decode [0 1 0]",
      Buffer.from([0]),
    ),
    pdfObject(
      2,
      "/Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode",
      jpeg,
    ),
  ]);
  const entries = await extract(pdf);
  assert.deepEqual([...entries.keys()], ["image-0001.jpg"]);
  assert.equal(basename([...entries.keys()][0]), "image-0001.jpg");
});
