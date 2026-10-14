import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// The sample from site/image/svg-rasterize.md: an objectBoundingBox linear
// gradient, rounded corners, fill-opacity, a cubic path, a round-capped
// stroke, and bold Inter text.
const SAMPLE = `<svg xmlns="http://www.w3.org/2000/svg" width="320" height="200" viewBox="0 0 320 200">
  <defs>
    <linearGradient id="sky" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#ff7a59"/>
      <stop offset="1" stop-color="#6a5cff"/>
    </linearGradient>
  </defs>
  <rect x="10" y="10" width="300" height="180" rx="24" fill="url(#sky)"/>
  <circle cx="90" cy="100" r="50" fill="#ffd23f" fill-opacity="0.85"/>
  <path d="M150 160 C180 40 260 40 290 160 Z" fill="#0b132b" fill-opacity="0.7"/>
  <path d="M30 170 L130 30" stroke="#ffffff" stroke-width="6" stroke-linecap="round"/>
  <text x="160" y="185" font-family="Inter" font-size="18" font-weight="bold" fill="#ffffff" text-anchor="middle">Hello, SVG</text>
</svg>`;

const WIDTH = 320;
const HEIGHT = 200;

function linearToSrgb8(value) {
  const v = Math.min(1, Math.max(0, value));
  const encoded = v <= 0.0031308 ? v * 12.92 : 1.055 * v ** (1 / 2.4) - 0.055;
  return Math.round(encoded * 255);
}

const modules = [
  {
    name: "center-sampled BMP",
    file: "svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm",
    pixel(memory, x, y) {
      const offset = 54 + ((HEIGHT - 1 - y) * WIDTH + x) * 4;
      return [memory[offset + 2], memory[offset + 1], memory[offset], memory[offset + 3]];
    },
  },
  {
    name: "center-sampled KTX2",
    file: "svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm",
    pixel(memory, x, y) {
      const offset = 224 + (y * WIDTH + x) * 4;
      return [...memory.subarray(offset, offset + 4)];
    },
  },
  {
    name: "SIMD RGBA8 KTX2",
    file: "svg-rasterize-to-ktx2-r8g8b8a8-srgb-simd.wasm",
    pixel(memory, x, y) {
      const offset = 224 + (y * WIDTH + x) * 4;
      return [...memory.subarray(offset, offset + 4)];
    },
  },
  {
    name: "SIMD RGBA32F KTX2",
    file: "svg-rasterize-to-ktx2-rgba32float-bt709-linear-simd.wasm",
    pixel(memory, x, y) {
      const view = new DataView(memory.buffer, memory.byteOffset);
      const offset = 224 + (y * WIDTH + x) * 16;
      const [r, g, b, a] = [0, 4, 8, 12].map((channel) => view.getFloat32(offset + channel, true));
      return [linearToSrgb8(r), linearToSrgb8(g), linearToSrgb8(b), Math.round(a * 255)];
    },
  },
];

function decodeResult(result) {
  const bits = BigInt.asUintN(64, result);
  return {
    sizeOrFailure: Number(bits & 0xffffffffn),
    pointer: Number((bits >> 32n) & 0x7fffffffn),
    failed: Number(bits >> 63n),
  };
}

async function renderSample(file) {
  const path = new URL(`../image/svg+xml/${file}`, import.meta.url);
  const { instance } = await WebAssembly.instantiate(await readFile(path));
  const exports = instance.exports;
  const input = new TextEncoder().encode(SAMPLE);
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.length).set(input);
  exports.uniform_set_background_color_rgba(0xffffffff);
  const result = decodeResult(exports.render(input.length));
  assert.equal(result.failed, 0);
  return new Uint8Array(exports.memory.buffer, result.pointer, result.sizeOrFailure);
}

for (const module of modules) {
  test(`${module.name} renders the comparison page sample`, async () => {
    const memory = await renderSample(module.file);
    const at = (x, y) => module.pixel(memory, x, y);

    // Outside the 24px corner radius the white background shows through.
    assert.deepEqual(at(11, 11), [255, 255, 255, 255]);

    // The diagonal gradient runs from #ff7a59 to #6a5cff across the box.
    const start = at(22, 22);
    const end = at(296, 176);
    assert.ok(start[0] > 230 && start[2] < 130, `gradient start ${start}`);
    assert.ok(end[2] > 230 && end[0] < 140, `gradient end ${end}`);

    // fill-opacity lets the gradient tint the yellow circle.
    const circle = at(60, 100);
    assert.ok(circle[0] > 220 && circle[1] > 160 && circle[2] < 120, `circle ${circle}`);
    assert.notDeepEqual(circle, [0xff, 0xd2, 0x3f, 255]);

    // The translucent navy path darkens the gradient without hiding it.
    const shadow = at(220, 140);
    assert.ok(shadow[0] < 140 && shadow[2] > shadow[1], `path ${shadow}`);

    // The white stroke crosses the circle.
    const stroke = at(80, 100);
    assert.ok(stroke.slice(0, 3).every((channel) => channel > 230), `stroke ${stroke}`);

    // White text pixels appear in the centred caption's band only.
    let caption = 0;
    for (let y = 168; y < 190; y += 1) {
      for (let x = 100; x < 220; x += 1) {
        if (at(x, y).slice(0, 3).every((channel) => channel > 240)) caption += 1;
      }
    }
    assert.ok(caption > 60, `caption pixels ${caption}`);
  });
}
