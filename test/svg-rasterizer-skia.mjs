import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import test from "node:test";

const component = new URL("../image/svg+xml/svg-rasterize-skia-with-fonts-to-ktx2-r8g8b8a8-srgb.wasm", import.meta.url);
const fontPaths = {
  regular: "fixtures/inter-4.1/ttf/InterDisplay-Regular.ttf",
  bold: "fixtures/inter-4.1/ttf/InterDisplay-Bold.ttf",
  italic: "fixtures/inter-4.1/ttf/InterDisplay-Italic.ttf",
};
const fonts = Object.fromEntries(await Promise.all(Object.entries(fontPaths).map(async ([name, path]) => [name, await readFile(path)])));
// WOFF and WOFF2 versions of the same Regular and Bold TrueType files.
const packedFonts = Object.fromEntries(await Promise.all(["woff", "woff2"].map(async flavor => [flavor, {
  regular: await readFile(`fixtures/inter-4.1/${flavor}/InterDisplay-Regular.${flavor}`),
  bold: await readFile(`fixtures/inter-4.1/${flavor}/InterDisplay-Bold.${flavor}`),
}])));
const module = await WebAssembly.compile(await readFile(component));
const defaultBoundary = "uuid-00000000-0000-0000-0000-000000000000";
const declaredType = `multipart/related;type="image/svg+xml";boundary=${defaultBoundary}`;
const textSVG = (weight, style = "normal") => `<svg width="100" height="40"><text x="2" y="30" font-family="Inter Display" font-size="28" font-weight="${weight}" font-style="${style}">Hello</text></svg>`;

function body(parts, boundary = defaultBoundary) {
  const chunks = [];
  for (const [type, bytes] of parts) chunks.push(Buffer.from(`--${boundary}\r\nContent-Type: ${type}\r\n\r\n`), Buffer.from(bytes), Buffer.from("\r\n"));
  chunks.push(Buffer.from(`--${boundary}--\r\n`));
  return Buffer.concat(chunks);
}
const svgWith = (svg, ...faces) => body([["image/svg+xml", svg], ...faces.map(face => ["font/ttf", fonts[face]])]);

function render(exports, input, width = 0, height = 0) {
  const bytes = typeof input === "string" ? Buffer.from(input) : input;
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), bytes.length).set(bytes);
  if (width) exports.uniform_set_width(width);
  if (height) exports.uniform_set_height(height);
  const bits = BigInt.asUintN(64, exports.render(bytes.length));
  if (bits >> 63n) return null;
  assert.equal(exports.arena_failed_allocation(), 0);
  assert.equal(exports.arena_free_unmatched_count(), 0);
  return new Uint8Array(exports.memory.buffer, Number(bits >> 32n), Number(bits & 0xffffffffn)).slice();
}
// SHA-256 of the KTX2 the former build with Inter Regular and Bold embedded produced.
const embeddedInterSHA256 = {
  400: "c7478e1d95d3a4c3081268eefd2b815f9c4883d59fd7543a1f1d3687d942420f",
  700: "1f09f3757a4dedcdf03dbd0b1f8df54ce0bcf31e8bdba040f138573f0d7067f3",
  tiger64: "0fc6aee9a53616a7673d6a546c779c158b4708295619012ac197e6f554867ed4",
};
const sha256 = bytes => createHash("sha256").update(bytes).digest("hex");
function instance() { return new WebAssembly.Instance(module).exports; }
// Renders a plain SVG as the root part with Inter Regular and Bold related.
function rasterize(exports, svg, width = 0, height = 0) {
  const output = render(exports, svgWith(svg, "regular", "bold"), width, height);
  if (!output) return null;
  const view = new DataView(output.buffer);
  assert.equal(view.getUint32(12, true), 43); // VK_FORMAT_R8G8B8A8_SRGB
  const w = view.getUint32(20, true), h = view.getUint32(24, true);
  assert.equal(output.length, 224 + w * h * 4);
  assert.equal(view.getBigUint64(80, true), 224n);
  assert.equal(view.getBigUint64(88, true), BigInt(w * h * 4));
  return { width: w, height: h, pixels: output.slice(224), output };
}
function pixel(image, x, y) {
  return [...image.pixels.slice((y * image.width + x) * 4, (y * image.width + x + 1) * 4)];
}
const coverage = output => output.slice(224).reduce((sum, value, i) => sum + (i % 4 === 3 ? value : 0), 0);
function contentType(exports) {
  return Buffer.from(exports.memory.buffer, exports.input_content_type_ptr(), exports.input_content_type_size()).toString();
}

test("Skia declares multipart/related with an SVG root and no imports", () => {
  assert.deepEqual(WebAssembly.Module.imports(module), []);
  const exports = instance();
  assert.equal(contentType(exports), declaredType);
  assert.equal(exports.input_bytes_cap(), 32 * 1024 * 1024);
  assert.equal(exports.input_utf8_cap, undefined);
  assert.equal(exports.output_bytes_cap(), 100000224);
  assert.equal(exports.memory.buffer.byteLength, 544 * 1024 * 1024);
});

test("Skia accepts 63 fonts in a body near the 32 MiB cap", () => {
  const exports = instance();
  const faces = Array.from({ length: 63 }, (_, i) => ["regular", "bold", "italic"][i % 3]);
  const expected = render(exports, svgWith(textSVG(700), "regular", "bold"));
  const input = svgWith(textSVG(700), ...faces);
  assert.ok(input.length > 24 * 1024 * 1024 && input.length <= 32 * 1024 * 1024, `${input.length} bytes`);
  assert.deepEqual(render(exports, input), expected);
});

test("Inter passed as related parts renders the same pixels as embedded Inter did", () => {
  const exports = instance();
  for (const weight of [400, 700]) {
    const output = render(exports, svgWith(textSVG(weight), "regular", "bold"));
    assert.ok(coverage(output) > 0);
    assert.equal(sha256(output), embeddedInterSHA256[weight], `weight ${weight}`);
  }
});

test("WOFF and WOFF2 fonts render the same pixels as their TrueType sources", () => {
  const exports = instance();
  for (const weight of [400, 700]) {
    const svg = textSVG(weight);
    for (const flavor of ["woff", "woff2"]) {
      const { regular, bold } = packedFonts[flavor];
      const output = render(exports, body([["image/svg+xml", svg], [`font/${flavor}`, regular], [`font/${flavor}`, bold]]));
      assert.equal(sha256(output), embeddedInterSHA256[weight], `${flavor} weight ${weight}`);
    }
    // Formats mix in one body, and FreeType detects each from its bytes, not its label.
    const mixed = body([["image/svg+xml", svg], ["font/woff", packedFonts.woff.regular], ["FONT/TTF; x=y", packedFonts.woff2.bold]]);
    assert.equal(sha256(render(exports, mixed)), embeddedInterSHA256[weight], `mixed weight ${weight}`);
  }
});

test("Skia draws text only with supplied fonts and matches their styles", () => {
  const exports = instance();
  const none = render(exports, svgWith(textSVG(400)));
  assert.equal(coverage(none), 0);
  const shape = render(exports, svgWith('<svg width="2" height="2"><rect width="2" height="2" fill="red"/></svg>'));
  assert.deepEqual([...shape.slice(224, 228)], [255, 0, 0, 255]);
  const regular = render(exports, svgWith(textSVG(400), "regular"));
  // With only Regular supplied, Bold requests fall back to it.
  assert.deepEqual(render(exports, svgWith(textSVG(700), "regular")), regular);
  assert.notDeepEqual(render(exports, svgWith(textSVG(700), "regular", "bold")), regular);
  // Italic is used when supplied.
  assert.notDeepEqual(render(exports, svgWith(textSVG(400, "italic"), "regular", "italic")), regular);
});

test("Skia reads a host-patched boundary on every call", () => {
  const exports = instance();
  const uuid = "12345678-90ab-cdef-1234-567890abcdef";
  const slot = exports.input_content_type_ptr() + exports.input_content_type_size() - 36;
  const expected = render(exports, svgWith(textSVG(400), "regular"));
  new Uint8Array(exports.memory.buffer, slot, 36).set(Buffer.from(uuid));
  assert.equal(render(exports, svgWith(textSVG(400), "regular")), null);
  assert.deepEqual(render(exports, body([["image/svg+xml", textSVG(400)], ["font/ttf", fonts.regular]], `uuid-${uuid}`)), expected);
  const upper = uuid.toUpperCase();
  new Uint8Array(exports.memory.buffer, slot, 36).set(Buffer.from(upper));
  assert.equal(render(exports, body([["image/svg+xml", textSVG(400)]], `uuid-${upper}`)), null);
});

test("Skia rejects malformed bodies, wrong part types, and unreadable fonts", () => {
  const exports = instance();
  const svg = '<svg width="1" height="1"/>';
  const good = svgWith(svg, "regular");
  const rejected = [
    "",
    textSVG(400),
    good.subarray(0, good.length - 4),
    body([["font/ttf", fonts.regular], ["image/svg+xml", svg]]),
    body([["text/html", svg]]),
    body([["image/svg+xml", svg], ["font/collection", fonts.regular]]),
    body([["image/svg+xml", svg], ["font/ttf", "not a font"]]),
    body([["image/svg+xml", svg], ["font/woff", packedFonts.woff.regular.subarray(0, 4096)]]),
    body([["image/svg+xml", svg], ["font/woff2", packedFonts.woff2.regular.subarray(0, 4096)]]),
    body([["image/svg+xml", svg], ...Array.from({ length: 64 }, () => ["font/ttf", fonts.regular])]),
    Buffer.from(`--${defaultBoundary}\r\nContent-Type: image/svg+xml\r\nContent-Type: image/svg+xml\r\n\r\n${svg}\r\n--${defaultBoundary}--\r\n`),
    Buffer.from(`--${defaultBoundary}\r\nContent-Type: image/svg+xml\r\nContent-Transfer-Encoding: base64\r\n\r\n${svg}\r\n--${defaultBoundary}--\r\n`),
    Buffer.concat([good, Buffer.from("x")]),
  ];
  for (const [index, input] of rejected.entries()) assert.equal(render(exports, input), null, `case ${index}`);
  assert.ok(render(exports, good));
  assert.ok(render(exports, Buffer.from(`--${defaultBoundary}\r\ncontent-type: Image/SVG+XML; charset=utf-8\r\nContent-ID: <root>\r\n\r\n${svg}\r\n--${defaultBoundary}--`)));
});

test("Skia reuses an instance across font sets without retaining fonts", () => {
  const exports = instance();
  const both = svgWith(textSVG(700), "regular", "bold");
  const regularOnly = svgWith(textSVG(700), "regular");
  const first = render(exports, both), fallback = render(exports, regularOnly);
  render(exports, both); // Warm retained singletons.
  const live = exports.arena_live_bytes();
  for (let i = 0; i < 6; i++) {
    assert.deepEqual(render(exports, regularOnly), fallback);
    assert.deepEqual(render(exports, both), first);
    assert.equal(exports.arena_live_bytes(), live);
  }
});

test("every host builds the related body from -i and -F and matches embedded Inter output", () => {
  const svgPath = "test/fixtures/svg/ghostscript-tiger.svg";
  for (const [label, command, prefix] of [
    ["Go qip", "./qip", []],
    ["Node qipx", process.execPath, ["npm/qipx/cli.mjs"]],
    ["Rust qipx", resolve("rust/qipx/target/debug/qipx"), []],
  ]) {
    const tiger = spawnSync(command, [...prefix, "run", "-i", svgPath, "-F", `@${fontPaths.regular};type=font/ttf`, component.pathname, "-u", "width=64", "-u", "height=64"], { maxBuffer: 1 << 24 });
    assert.equal(tiger.status, 0, `${label}: ${tiger.stderr}`);
    assert.equal(sha256(tiger.stdout), embeddedInterSHA256.tiger64, label);
    const result = spawnSync(command, [...prefix, "run", "-i", "-", "-F", `regular=@${fontPaths.regular};type=font/ttf`, "-F", `bold=@${fontPaths.bold};type=font/ttf`, component.pathname], { input: textSVG(700), maxBuffer: 1 << 24 });
    assert.equal(result.status, 0, `${label}: ${result.stderr}`);
    assert.equal(sha256(result.stdout), embeddedInterSHA256[700], label);
  }
});

test("Skia returns straight alpha and antialiased edges", () => {
  const image = rasterize(instance(), '<svg width="16" height="16"><path d="M1 1L15 8L1 15Z" fill="red"/></svg>');
  let fractional = 0, opaque = 0;
  for (let i = 0; i < image.pixels.length; i += 4) {
    const alpha = image.pixels[i + 3];
    if (alpha) assert.deepEqual([...image.pixels.slice(i, i + 3)], [255, 0, 0]);
    if (alpha > 0 && alpha < 255) fractional++;
    if (alpha === 255) opaque++;
  }
  assert.ok(fractional > 0);
  assert.ok(opaque > 0);
});

test("Skia applies a background and resets all uniforms", () => {
  const exports = instance();
  exports.uniform_set_background_color_rgba(0x112233ff);
  const image = rasterize(exports, '<svg width="1" height="1"/>', 2, 2);
  assert.deepEqual(pixel(image, 0, 0), [17, 34, 51, 255]);
  const next = rasterize(exports, '<svg width="1" height="1"/>');
  assert.deepEqual([next.width, next.height], [1, 1]);
  assert.deepEqual(pixel(next, 0, 0), [0, 0, 0, 0]);
});

test("Skia uses viewBox dimensions and fits the requested viewport", () => {
  const svg = '<svg viewBox="0 0 4 2"><rect width="4" height="2" fill="lime"/></svg>';
  const exports = instance();
  assert.deepEqual([rasterize(exports, svg).width, rasterize(exports, svg).height], [4, 2]);
  const image = rasterize(exports, svg, 8, 8);
  assert.deepEqual(pixel(image, 4, 0), [0, 0, 0, 0]);
  assert.deepEqual(pixel(image, 4, 4), [0, 255, 0, 255]);
});

test("Skia renders gradients, clipping, masks, and blur filters", () => {
  const svg = '<svg width="32" height="16"><defs><linearGradient id="g"><stop stop-color="red"/><stop offset="1" stop-color="blue"/></linearGradient><clipPath id="c"><rect width="24" height="16"/></clipPath><mask id="m"><rect width="32" height="16" fill="white"/></mask><filter id="b"><feGaussianBlur stdDeviation="1"/></filter></defs><rect x="2" y="2" width="28" height="12" fill="url(#g)" clip-path="url(#c)" mask="url(#m)" filter="url(#b)"/></svg>';
  const image = rasterize(instance(), svg);
  assert.ok(pixel(image, 5, 8)[0] > pixel(image, 5, 8)[2]);
  assert.ok(pixel(image, 20, 8)[2] > pixel(image, 20, 8)[0]);
  assert.equal(pixel(image, 30, 8)[3], 0);
  assert.ok(pixel(image, 2, 8)[3] > 0 && pixel(image, 2, 8)[3] < 255);
});

test("Skia rejects malformed XML, entity declarations, and excessive dimensions", () => {
  const exports = instance();
  for (const svg of ['', '<svg><path></svg>', '<html/>', '<!DOCTYPE svg [<!ENTITY x "hello">]><svg width="1" height="1">&x;</svg>', '<svg width="9000" height="1"/>']) {
    assert.equal(rasterize(exports, svg), null, svg);
  }
  assert.equal(rasterize(exports, '<svg width="1" height="1"/>', 8192, 8192), null);
  assert.equal(exports.uniform_set_width(9000), 8192);
  assert.equal(exports.uniform_set_height(9000), 8192);
});

test("Skia ignores external images without loading host resources", () => {
  const image = rasterize(instance(), '<svg width="2" height="2"><image href="file:///tmp/image.png" width="2" height="2"/></svg>');
  assert.ok(image.pixels.every(value => value === 0));
});

test("Skia keeps complex path spans inside the Tiger outline", async () => {
  const tiger = await readFile(new URL("fixtures/svg/ghostscript-tiger.svg", import.meta.url));
  const image = rasterize(instance(), tiger, 512, 512);
  assert.deepEqual(pixel(image, 435, 49), [255, 255, 255, 255]);
  for (let y = 0; y < image.height; y++) {
    assert.equal(pixel(image, 511, y)[3], 0, `unexpected span at right edge, row ${y}`);
  }
});

test("Skia reuses an instance without growing retained allocations or changing output", async () => {
  const exports = instance();
  const tiger = await readFile(new URL("fixtures/svg/ghostscript-tiger.svg", import.meta.url));
  const first = rasterize(exports, tiger, 64, 64);
  assert.ok(first.pixels.some((value, i) => i % 4 === 3 && value > 0));
  rasterize(exports, tiger, 64, 64); // Warm retained singletons.
  const live = exports.arena_live_bytes();
  for (let i = 0; i < 12; i++) {
    assert.deepEqual(rasterize(exports, tiger, 64, 64).output, first.output);
    assert.equal(exports.arena_live_bytes(), live);
    assert.equal(exports.memory.buffer.byteLength, 544 * 1024 * 1024);
    assert.equal(rasterize(exports, '<svg><path></svg>'), null);
  }
});
