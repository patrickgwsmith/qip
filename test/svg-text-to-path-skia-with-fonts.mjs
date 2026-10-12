import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { resolve } from "node:path";
import test from "node:test";

const component = new URL("../image/svg+xml/svg-text-to-path-skia-with-fonts.wasm", import.meta.url);
const rasterizer = new URL("../image/svg+xml/svg-rasterize-skia-with-fonts-to-ktx2-r8g8b8a8-srgb.wasm", import.meta.url);
const fontPaths = Object.fromEntries(["Regular", "Bold", "Italic", "BoldItalic"].map(face => [face, `fixtures/inter-4.1/ttf/InterDisplay-${face}.ttf`]));
const fonts = Object.fromEntries(await Promise.all(Object.entries(fontPaths).map(async ([face, path]) => [face, await readFile(path)])));
const interFaces = ["Regular", "Bold", "Italic", "BoldItalic"];
// WOFF and WOFF2 versions of the same four TrueType files.
const packedFonts = Object.fromEntries(await Promise.all(["woff", "woff2"].map(async flavor => [flavor,
  Object.fromEntries(await Promise.all(interFaces.map(async face => [face, await readFile(`fixtures/inter-4.1/${flavor}/InterDisplay-${face}.${flavor}`)])))])));
const encoder = new TextEncoder();
const decoder = new TextDecoder();
const module = await WebAssembly.compile(await readFile(component));
const rasterModule = await WebAssembly.compile(await readFile(rasterizer));
const boundary = "uuid-00000000-0000-0000-0000-000000000000";
const declaredType = `multipart/related;type="image/svg+xml";boundary=${boundary}`;
const sha256 = bytes => createHash("sha256").update(bytes).digest("hex");
function instance() { return new WebAssembly.Instance(module).exports; }
function body(parts) {
  const chunks = parts.flatMap(([type, bytes]) => [Buffer.from(`--${boundary}\r\nContent-Type: ${type}\r\n\r\n`), Buffer.from(bytes), Buffer.from("\r\n")]);
  return Buffer.concat([...chunks, Buffer.from(`--${boundary}--\r\n`)]);
}
const svgWith = (svg, ...faces) => body([["image/svg+xml", svg], ...faces.map(face => ["font/ttf", fonts[face]])]);
function call(exports, input) {
  const bytes = typeof input === "string" ? encoder.encode(input) : input;
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), bytes.length).set(bytes);
  const bits = BigInt.asUintN(64, exports.render(bytes.length));
  if (bits >> 63n) return null;
  return new Uint8Array(exports.memory.buffer, Number(bits >> 32n), Number(bits & 0xffffffffn)).slice();
}
function convertBody(input, exports = instance()) {
  const output = call(exports, input);
  if (!output) return null;
  assert.equal(exports.arena_failed_allocation(), 0);
  assert.equal(exports.arena_free_unmatched_count(), 0);
  return decoder.decode(output);
}
// Converts a plain SVG with all four Inter Display faces passed as font parts.
const convert = (svg, exports) => convertBody(svgWith(svg, ...interFaces), exports);
// Rasterizes with Inter Regular and Bold passed as multipart/related font parts.
function alpha(svg) {
  const output = call(new WebAssembly.Instance(rasterModule).exports, svgWith(svg, "Regular", "Bold"));
  const pixels = output.subarray(224);
  return Uint8Array.from({ length: pixels.length / 4 }, (_, i) => pixels[i * 4 + 3]);
}
// Skia fills glyph outlines itself at 256 px and larger, so only edge rounding differs.
function assertSameShape(svg) {
  const before = alpha(svg), after = alpha(convert(svg));
  let changed = 0, ink = 0;
  for (let i = 0; i < before.length; i++) {
    assert.ok(Math.abs(before[i] - after[i]) <= 40, `alpha differs by ${Math.abs(before[i] - after[i])}`);
    if (before[i] !== after[i]) changed++;
    if (before[i]) ink++;
  }
  assert.ok(ink > 1000);
  assert.ok(changed < ink / 20, `${changed} of ${ink} inked pixels changed`);
}

// SHA-256 of the SVG the former build with the four Inter faces embedded produced.
const embeddedInter = [
  ['<svg width="1400" height="320"><text x="10" y="280" font-size="300">A <tspan font-weight="bold">B</tspan><tspan dx="60" dy="-20">C</tspan></text></svg>',
    "3ae588bff2f2053e953b6176deb96edc0f44f7cbb243e700d7417b45c77bf584"],
  ['<svg width="1400" height="800"><defs><path id="p" d="M10 700 Q700 0 1390 700"/></defs><text font-size="300"><textPath xlink:href="#p">Curve</textPath></text></svg>',
    "42be439f743361f97d92375996cb682efa801c56a85c17c95d869cada2b98b26"],
  ['<svg width="300" height="60"><text x="5" y="40" font-size="24" font-weight="700" font-style="italic">Quick fox ÅÉß 123 &amp; →</text></svg>',
    "dfa1b30c6fcb7b385bf56aa90952e780b554f974910e9d3f848088dc990f5fd9"],
  [`<svg width="800" height="400">${Array.from({ length: 40 }, (_, i) => `<text x="${i * 7}" y="${i * 9}" font-size="${6 + i}" font-weight="${100 * (1 + i % 9)}" font-style="${["normal", "italic", "oblique"][i % 3]}" text-anchor="${["start", "middle", "end"][i % 3]}">Label ${i} — ✓ ﬁ ½</text>`).join("")}</svg>`,
    "c87142ad4bed1b0313c42db4da120d6d008bc8f61e75f7d3fd4ddda0f0f55f94"],
];

test("text-to-path declares multipart/related with an SVG root and no imports", () => {
  assert.deepEqual(WebAssembly.Module.imports(module), []);
  const exports = instance();
  assert.equal(Buffer.from(exports.memory.buffer, exports.input_content_type_ptr(), exports.input_content_type_size()).toString(), declaredType);
  assert.equal(exports.memory.buffer.byteLength, 192 * 1024 * 1024);
  assert.equal(exports.input_bytes_cap(), 32 * 1024 * 1024);
  assert.equal(exports.input_utf8_cap, undefined);
  assert.equal(exports.output_utf8_cap(), 16777216);
});

test("Inter passed as related parts produces the same SVG as embedded Inter did", () => {
  const exports = instance();
  for (const [index, [svg, hash]] of embeddedInter.entries()) {
    assert.equal(sha256(convert(svg, exports)), hash, `case ${index}`);
  }
  // Skia matches faces by family and style, not by part order.
  const [svg, hash] = embeddedInter[3];
  assert.equal(sha256(convertBody(svgWith(svg, ...[...interFaces].reverse()), exports)), hash);
});

test("WOFF and WOFF2 fonts produce the same SVG as their TrueType sources", () => {
  const exports = instance();
  for (const [index, [svg, hash]] of embeddedInter.entries()) {
    for (const flavor of ["woff", "woff2"]) {
      const input = body([["image/svg+xml", svg], ...interFaces.map(face => [`font/${flavor}`, packedFonts[flavor][face]])]);
      assert.equal(sha256(convertBody(input, exports)), hash, `${flavor} case ${index}`);
    }
  }
  // Formats mix in one body, and FreeType detects each from its bytes, not its label.
  const [svg, hash] = embeddedInter[3];
  const mixed = body([["image/svg+xml", svg], ["font/ttf", fonts.Regular], ["font/woff", packedFonts.woff.Bold],
    ["font/woff2", packedFonts.woff2.Italic], ["font/otf", packedFonts.woff2.BoldItalic]]);
  assert.equal(sha256(convertBody(mixed, exports)), hash);
});

test("every host builds the related body from -i and -F and matches embedded Inter output", () => {
  const [svg, hash] = embeddedInter[0];
  const parts = interFaces.flatMap(face => ["-F", `${face}=@${fontPaths[face]};type=font/ttf`]);
  for (const [label, command, prefix] of [
    ["Go qip", "./qip", []],
    ["Node qipx", process.execPath, ["npm/qipx/cli.mjs"]],
    ["Rust qipx", resolve("rust/qipx/target/debug/qipx"), []],
  ]) {
    const result = spawnSync(command, [...prefix, "run", "-i", "-", ...parts, component.pathname], { input: svg, maxBuffer: 1 << 24 });
    assert.equal(result.status, 0, `${label}: ${result.stderr}`);
    // Hosts end text output with a newline.
    assert.equal(sha256(result.stdout.toString().replace(/\n$/, "")), hash, label);
  }
});

test("replaces only the text element and keeps the rest of the source", () => {
  const svg = '<?xml version="1.0"?>\n<svg width="200" height="40">\n  <!-- label -->\n  <rect width="5" height="5"/>\n  <text id="t" class="label" x="10" y="30" font-size="20" fill="navy" transform="rotate(2)">Hello<title>Greeting</title></text>\n</svg>\n';
  const output = convert(svg);
  const [before, after] = svg.split(/<text[\s\S]*<\/text>/);
  assert.ok(output.startsWith(before));
  assert.ok(output.endsWith(after));
  const path = output.slice(before.length, output.length - after.length);
  assert.match(path, /^<path id="t" class="label" fill="navy" transform="rotate\(2\)" d="M[^"]+Z"><title>Greeting<\/title><\/path>$/);
  assert.doesNotMatch(path, /font-size|\bx=|\by=/);
});

test("leaves SVG without text byte-identical", () => {
  const svg = '<svg viewBox="0 0 4 4"><![CDATA[ <text> ]]><path d="M0 0H4V4Z"/></svg>';
  assert.equal(convert(svg), svg);
  assert.equal(convertBody(svgWith(svg)), svg);
});

test("outlines match Skia text layout", () => {
  assertSameShape('<svg width="1400" height="320"><text x="10" y="280" font-size="300">A <tspan font-weight="bold">B</tspan><tspan dx="60" dy="-20">C</tspan></text></svg>');
  assertSameShape('<svg width="1400" height="320"><text x="10 400 800" y="280" style="font-size: 300px; font-weight: bold">T&amp;J</text></svg>');
  assertSameShape('<svg viewBox="0 0 1400 320" width="700"><g style="font-size:300px" text-anchor="end"><text x="100%" y="280" transform="rotate(3)">Mid</text></g></svg>');
  assertSameShape('<svg width="1400" height="800"><defs><path id="p" d="M10 700 Q700 0 1390 700"/></defs><text font-size="300"><textPath xlink:href="#p">Curve</textPath></text></svg>');
});

test("uses Inter Display Bold for bold text", () => {
  const regular = convert('<svg><text font-size="20">Hi</text></svg>');
  const bold = convert('<svg><text font-size="20" font-weight="700">Hi</text></svg>');
  assert.notEqual(regular, bold);
  assert.equal(convert('<svg><text font-size="20" font-family="Nope">Hi</text></svg>'), regular);
});

test("uses Inter Display Italic and Bold Italic for italic text", () => {
  const faces = [
    '<text font-size="20">Hi</text>',
    '<text font-size="20" font-weight="700">Hi</text>',
    '<text font-size="20" font-style="italic">Hi</text>',
    '<text font-size="20" style="font-style: italic; font-weight: bold">Hi</text>',
  ].map((text) => convert(`<svg>${text}</svg>`));
  assert.equal(new Set(faces).size, 4);
  assert.equal(convert('<svg><g font-style="italic"><text font-size="20">Hi</text></g></svg>'),
    faces[2].replace("<svg>", '<svg><g font-style="italic">').replace("</svg>", "</g></svg>"));
  assert.equal(convert('<svg><text font-size="20" font-style="oblique">Hi</text></svg>'), faces[2]);
});

test("outlines text only with supplied fonts", () => {
  const exports = instance();
  const svg = '<svg><text font-size="20" font-weight="700">Hi</text></svg>';
  assert.equal(convertBody(svgWith(svg), exports), '<svg><path d=""/></svg>');
  // With only Regular supplied, Bold requests fall back to it.
  const regular = convertBody(svgWith('<svg><text font-size="20">Hi</text></svg>', "Regular"), exports);
  assert.equal(convertBody(svgWith(svg, "Regular"), exports), regular);
  assert.equal(convertBody(svgWith(svg, "Regular", "Bold"), exports), convert(svg, exports));
});

test("rejects malformed bodies, wrong part types, and unreadable fonts", () => {
  const exports = instance();
  const svg = '<svg width="1" height="1"/>';
  const good = svgWith(svg, "Regular");
  const rejected = [
    "",
    svg,
    good.subarray(0, good.length - 4),
    body([["font/ttf", fonts.Regular], ["image/svg+xml", svg]]),
    body([["text/html", svg]]),
    body([["image/svg+xml", svg], ["font/collection", fonts.Regular]]),
    body([["image/svg+xml", svg], ["font/ttf", "not a font"]]),
    body([["image/svg+xml", svg], ["font/woff", packedFonts.woff.Regular.subarray(0, 4096)]]),
    body([["image/svg+xml", svg], ["font/woff2", packedFonts.woff2.Regular.subarray(0, 4096)]]),
    body([["image/svg+xml", svg], ...Array.from({ length: 64 }, () => ["font/ttf", fonts.Regular])]),
    Buffer.from(`--${boundary}\r\nContent-Type: image/svg+xml\r\nContent-Transfer-Encoding: base64\r\n\r\n${svg}\r\n--${boundary}--\r\n`),
    Buffer.concat([good, Buffer.from("x")]),
  ];
  for (const [index, input] of rejected.entries()) assert.equal(convertBody(input, exports), null, `case ${index}`);
  assert.equal(convertBody(good, exports), svg);
  assert.equal(convertBody(Buffer.from(`--${boundary}\r\ncontent-type: Image/SVG+XML; charset=utf-8\r\nContent-ID: <root>\r\n\r\n${svg}\r\n--${boundary}--`), exports), svg);
});

test("escapes attribute values and handles empty text", () => {
  const output = convert('<svg><text aria-label="&quot;a&quot; &amp; &lt;b&gt;"> </text><text/></svg>');
  assert.equal(output, '<svg><path aria-label="&quot;a&quot; &amp; &lt;b&gt;" d=""/><path d=""/></svg>');
});

test("reuses an instance across font sets without leaking arena storage", () => {
  const exports = instance();
  const svg = '<svg><text font-size="12" font-weight="700">Label</text></svg>';
  const first = convert(svg, exports), fallback = convertBody(svgWith(svg, "Regular"), exports);
  const live = exports.arena_live_bytes();
  for (let i = 0; i < 5; i++) {
    assert.equal(convert(svg, exports), first);
    assert.equal(convertBody(svgWith(svg, "Regular"), exports), fallback);
    assert.equal(exports.arena_live_bytes(), live);
  }
});

test("rejects malformed XML, non-SVG roots, and oversized output", () => {
  const exports = instance();
  assert.equal(convert('<svg><text>open</svg>', exports), null);
  assert.equal(convert('<html/>', exports), null);
  assert.equal(convert('<!DOCTYPE svg [<!ENTITY e "x">]><svg>&e;</svg>', exports), null);
  const many = `<svg>${'<text font-size="12">The quick brown fox jumps</text>'.repeat(4000)}</svg>`;
  assert.equal(convert(many, exports), null);
  assert.ok(convert('<svg><text>ok</text></svg>', exports));
});
