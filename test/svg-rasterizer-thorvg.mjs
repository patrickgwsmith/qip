import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { deflateSync } from "node:zlib";
import test from "node:test";

const encoder = new TextEncoder();
const componentPath = new URL(
  "../image/svg+xml/svg-rasterize-thorvg-to-ktx2-r8g8b8a8-srgb.wasm",
  import.meta.url,
);
const tigerPath = new URL("fixtures/svg/ghostscript-tiger.svg", import.meta.url);
const pixelOffset = 224;

function decodeResult(value) {
  const bits = BigInt.asUintN(64, value);
  return {
    size: Number(bits & 0xffffffffn),
    pointer: Number((bits >> 32n) & 0x7fffffffn),
    failed: Number(bits >> 63n),
  };
}

async function instantiate(path = componentPath) {
  const { instance } = await WebAssembly.instantiate(await readFile(path));
  return instance.exports;
}

function render(exports, source, width = 0, height = 0) {
  const input = typeof source === "string" ? encoder.encode(source) : source;
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.length).set(input);
  if (width) assert.equal(exports.uniform_set_width(width), width);
  if (height) assert.equal(exports.uniform_set_height(height), height);
  return decodeResult(exports.render(input.length));
}

function inspectKtx2(exports, result, width, height) {
  assert.equal(result.failed, 0);
  assert.equal(result.size, pixelOffset + width * height * 4);
  const view = new DataView(exports.memory.buffer, result.pointer, result.size);
  assert.equal(view.getUint32(12, true), 43);
  assert.equal(view.getUint32(20, true), width);
  assert.equal(view.getUint32(24, true), height);
  return new Uint8Array(
    exports.memory.buffer,
    result.pointer + pixelOffset,
    width * height * 4,
  );
}

test("ThorVG SVG rasterizer has no host imports", async () => {
  const module = await WebAssembly.compile(await readFile(componentPath));
  assert.deepEqual(WebAssembly.Module.imports(module), []);
});

test("ThorVG scan conversion produces fractional edge coverage", async () => {
  const exports = await instantiate();
  const result = render(
    exports,
    '<svg width="16" height="16"><path d="M1 1L15 8L1 15Z" fill="#ff0000"/></svg>',
  );
  const pixels = inspectKtx2(exports, result, 16, 16);
  let fractionalAlpha = 0;
  let opaque = 0;
  for (let index = 3; index < pixels.length; index += 4) {
    if (pixels[index] > 0 && pixels[index] < 255) fractionalAlpha += 1;
    if (pixels[index] === 255) opaque += 1;
  }
  assert.equal(fractionalAlpha, 28);
  assert.equal(opaque, 84);
  assert.equal(exports.arena_live_bytes(), 0);
  assert.equal(exports.arena_failed_allocation(), 0);
  assert.equal(exports.arena_free_unmatched_count(), 0);
});

test("ThorVG rasterizer applies an RGBA background and resets uniforms", async () => {
  const exports = await instantiate();
  assert.equal(exports.uniform_set_background_color_rgba(0x112233ff), 0x112233ff);
  let result = render(exports, '<svg width="1" height="1"/>');
  assert.deepEqual([...inspectKtx2(exports, result, 1, 1)], [0x11, 0x22, 0x33, 0xff]);
  result = render(exports, '<svg width="1" height="1"/>');
  assert.deepEqual([...inspectKtx2(exports, result, 1, 1)], [0, 0, 0, 0]);
});

test("ThorVG rasterizer renders the unchanged Ghostscript Tiger fixture", async () => {
  const exports = await instantiate();
  const result = render(exports, await readFile(tigerPath), 64, 64);
  const pixels = inspectKtx2(exports, result, 64, 64);
  const output = new Uint8Array(exports.memory.buffer, result.pointer, result.size);
  assert.equal(
    createHash("sha256").update(output).digest("hex"),
    "51671f54a0e94edf81ffacfa10485997cea25ad87c391581363e1ef105e76525",
  );
  let painted = 0;
  let fractionalAlpha = 0;
  for (let index = 3; index < pixels.length; index += 4) {
    if (pixels[index] > 0) painted += 1;
    if (pixels[index] > 0 && pixels[index] < 255) fractionalAlpha += 1;
  }
  assert.equal(painted, 2811);
  assert.equal(fractionalAlpha, 406);
  assert.equal(exports.arena_live_bytes(), 0);
});

test("ThorVG rasterizer rejects malformed SVG recoverably", async () => {
  const exports = await instantiate();
  const result = render(exports, "<svg><path></svg>");
  assert.equal(result.failed, 0);
  assert.equal(result.size, 0);
  assert.equal(exports.arena_live_bytes(), 0);
  assert.equal(exports.arena_failed_allocation(), 0);
  assert.equal(exports.arena_free_unmatched_count(), 0);
});

const jpegFixture = new URL(
  "../compliance/jpeg-to-bmp-b8g8r8a8-srgb-fixtures/gradient-16x16-444.jpg",
  import.meta.url,
);

function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = crc & 1 ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function pngChunk(type, data) {
  const out = Buffer.alloc(12 + data.length);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, "latin1");
  data.copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
}

// Builds an RGBA8 PNG from a pixel callback.
function makePng(width, height, pixel) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 6;
  const rows = [];
  for (let y = 0; y < height; y += 1) {
    rows.push(0);
    for (let x = 0; x < width; x += 1) rows.push(...pixel(x, y));
  }
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    pngChunk("IHDR", header),
    pngChunk("IDAT", deflateSync(Buffer.from(rows))),
    pngChunk("IEND", Buffer.alloc(0)),
  ]);
}

// A 4x2 PNG: the left half red, the right half blue.
const halvesPng = makePng(4, 2, (x) => (x < 2 ? [255, 0, 0, 255] : [0, 0, 255, 255]));
const halvesHref = `data:image/png;base64,${halvesPng.toString("base64")}`;

// One letter per pixel: R red, B blue, G green, . transparent, ? mixed.
function letters(pixels, width, height) {
  const rows = [];
  for (let y = 0; y < height; y += 1) {
    let row = "";
    for (let x = 0; x < width; x += 1) {
      const [r, g, b, a] = pixels.subarray((y * width + x) * 4, (y * width + x) * 4 + 4);
      if (a < 32) row += ".";
      else if (r > 200 && g < 60 && b < 60) row += "R";
      else if (b > 200 && r < 60 && g < 60) row += "B";
      else if (g > 200 && r < 60 && b < 60) row += "G";
      else row += "?";
    }
    rows.push(row);
  }
  return rows;
}

function assertArenaClean(exports) {
  assert.equal(exports.arena_live_bytes(), 0);
  assert.equal(exports.arena_failed_allocation(), 0);
  assert.equal(exports.arena_free_unmatched_count(), 0);
}

test("ThorVG rasterizer accepts an 8 MiB input", async () => {
  const exports = await instantiate();
  assert.equal(exports.input_bytes_cap(), 8 * 1024 * 1024);
});

test("ThorVG rasterizer draws embedded PNG pixels with alpha", async () => {
  const exports = await instantiate();
  const quad = makePng(2, 2, (x, y) =>
    [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 255, 0]][y * 2 + x],
  );
  const result = render(
    exports,
    `<svg xmlns="http://www.w3.org/2000/svg" width="2" height="2"><image width="2" height="2" href="data:image/png;base64,${quad.toString("base64")}"/></svg>`,
  );
  const pixels = inspectKtx2(exports, result, 2, 2);
  assert.deepEqual([...pixels], [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 0, 0, 0, 0]);
  assertArenaClean(exports);
});

test("ThorVG rasterizer draws an embedded JPEG through xlink:href and clip-path", async () => {
  const exports = await instantiate();
  const jpeg = (await readFile(jpegFixture)).toString("base64");
  const result = render(
    exports,
    `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="16" height="16"><clipPath id="round"><circle cx="8" cy="8" r="8"/></clipPath><image width="16" height="16" clip-path="url(#round)" xlink:href="data:image/jpeg;base64,${jpeg}"/></svg>`,
  );
  const pixels = inspectKtx2(exports, result, 16, 16);
  assert.equal(pixels[3], 0, "corner is outside the circle");
  assert.equal(pixels[(8 * 16 + 8) * 4 + 3], 255, "centre is opaque");
  assertArenaClean(exports);
});

test("ThorVG rasterizer applies preserveAspectRatio to images", async () => {
  const exports = await instantiate();
  const svg = (attrs, width = 8, height = 8) =>
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}"><rect width="8" height="8" fill="#0f0"/><image ${attrs} href="${halvesHref}"/></svg>`;
  const draw = (attrs, width, height) =>
    letters(inspectKtx2(exports, render(exports, svg(attrs, width, height)), width ?? 8, height ?? 8), width ?? 8, height ?? 8);

  // The default, xMidYMid meet, letterboxes the 2:1 bitmap.
  assert.deepEqual(draw('width="8" height="8"'), [
    "GGGGGGGG", "GGGGGGGG", "RRRR?BBB", "RRRR?BBB", "RRRR?BBB", "RRRR?BBB", "GGGGGGGG", "GGGGGGGG",
  ]);
  assert.deepEqual(draw('width="8" height="4" preserveAspectRatio="none"', 8, 4), [
    "RRRR?BBB", "RRRR?BBB", "RRRR?BBB", "RRRR?BBB",
  ]);
  // slice fills the viewport and clips the overflow to it.
  assert.deepEqual(draw('x="2" y="2" width="4" height="4" preserveAspectRatio="xMidYMid slice"'), [
    "GGGGGGGG", "GGGGGGGG", "GGRR?BGG", "GGRR?BGG", "GGRR?BGG", "GGRR?BGG", "GGGGGGGG", "GGGGGGGG",
  ]);
  assert.deepEqual(draw('x="2" y="2" width="4" height="4" preserveAspectRatio="xMinYMid slice"'), [
    "GGGGGGGG", "GGGGGGGG", "GGRRRRGG", "GGRRRRGG", "GGRRRRGG", "GGRRRRGG", "GGGGGGGG", "GGGGGGGG",
  ]);
  // A missing width or height follows the bitmap's own size.
  assert.deepEqual(draw("", 8, 4), ["RRBBGGGG", "RRBBGGGG", "GGGGGGGG", "GGGGGGGG"]);
  assert.deepEqual(draw('width="8"', 8, 4), ["RRRR?BBB", "RRRR?BBB", "RRRR?BBB", "RRRR?BBB"]);
  assertArenaClean(exports);
});

test("ThorVG rasterizer skips images it cannot load and draws the rest", async () => {
  const exports = await instantiate();
  const truncated = halvesPng.subarray(0, halvesPng.length - 20).toString("base64");
  for (const href of [
    "https://example.com/avatar.png",
    "file:///etc/passwd.png",
    "avatar.png",
    "data:image/gif;base64,R0lGODlhAQABAAAAACw=",
    "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQ",
    "data:image/png;base64,!!!!",
    `data:image/png;base64,${truncated}`,
  ]) {
    const result = render(
      exports,
      `<svg xmlns="http://www.w3.org/2000/svg" width="2" height="2"><rect width="2" height="2" fill="#00f"/><image width="2" height="2" href="${href}"/></svg>`,
    );
    const pixels = inspectKtx2(exports, result, 2, 2);
    assert.deepEqual([...pixels.subarray(0, 4)], [0, 0, 255, 255], href);
    assertArenaClean(exports);
  }
});

test("ThorVG rasterizer fails recoverably when a decoded image exceeds its arena", async () => {
  const exports = await instantiate();
  const side = 10000;
  const header = Buffer.alloc(13);
  header.writeUInt32BE(side, 0);
  header.writeUInt32BE(side, 4);
  header[8] = 8;
  header[9] = 6;
  const bomb = Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    pngChunk("IHDR", header),
    pngChunk("IDAT", deflateSync(Buffer.alloc(side * (side * 4 + 1)))),
    pngChunk("IEND", Buffer.alloc(0)),
  ]);
  let result = render(
    exports,
    `<svg xmlns="http://www.w3.org/2000/svg" width="2" height="2"><image width="2" height="2" href="data:image/png;base64,${bomb.toString("base64")}"/></svg>`,
  );
  assert.equal(result.failed, 0);
  assert.equal(result.size, 0);
  assert.equal(exports.arena_live_bytes(), 0);
  result = render(exports, '<svg width="1" height="1"><rect width="1" height="1"/></svg>');
  inspectKtx2(exports, result, 1, 1);
  assertArenaClean(exports);
});
