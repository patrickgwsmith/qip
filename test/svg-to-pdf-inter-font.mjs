import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const converterPath = "image/svg+xml/svg-to-pdf-inter-font.wasm";
const extractorPath = "application/pdf/pdf-extract-text.wasm";

function decodeResult(result) {
  const bits = BigInt.asUintN(64, result);
  return {
    size: Number(bits & 0xffff_ffffn),
    pointer: Number((bits >> 32n) & 0x7fff_ffffn),
    failed: Number(bits >> 63n),
  };
}

function render(exports, input) {
  assert.ok(input.length <= exports.input_utf8_cap());
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.length).set(input);
  const result = decodeResult(exports.render(input.length));
  if (result.failed) return result;
  return {
    ...result,
    bytes: Buffer.from(new Uint8Array(exports.memory.buffer, result.pointer, result.size)),
  };
}

test("SVG to PDF embeds Inter and retains vector text", async () => {
  const converter = new WebAssembly.Instance(new WebAssembly.Module(await readFile(converterPath))).exports;
  const svg = encoder.encode('<svg width="160" height="96"><defs><linearGradient id="sunset" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="160" y2="0"><stop offset="20%" stop-color="#f00"/><stop offset="0.5" stop-color="#f0f"/><stop offset="80%" stop-color="#00f"/></linearGradient><radialGradient id="glow" gradientUnits="userSpaceOnUse" cx="80" cy="48" r="32"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#0ff"/></radialGradient></defs><g transform="translate(4 0)" fill="url(#sunset)"><rect x="0" y="0" width="160" height="96"/><g transform="rotate(10 80 48)"><circle cx="80" cy="48" r="32" fill="url(#glow)"/></g></g><g transform="matrix(1 0 0 1 0 0) scale(1 1)" fill="#123"><path d="M 10 10 L 40 30 Z"/><text x="10" y="24" font-size="12" font-family="Inter">Regular</text></g><text x="10" y="42" font-size="12" font-family="Inter" font-weight="bold">Bold</text><text x="10" y="60" font-size="12" font-family="Inter" font-style="italic">Italic</text><text x="10" y="78" font-size="12" font-family="Inter" font-weight="700" font-style="italic">Bold Italic</text></svg>');
  const pdf = render(converter, svg);

  assert.equal(pdf.failed, 0);
  assert.match(pdf.bytes.subarray(0, 8).toString("ascii"), /^%PDF-1.7/);
  assert.ok(pdf.bytes.includes(Buffer.from("/Metadata 5 0 R")));
  assert.ok(pdf.bytes.includes(Buffer.from("/S /GTS_PDFA1")));
  assert.ok(pdf.bytes.includes(Buffer.from("/DestOutputProfile 6 0 R")));
  assert.ok(pdf.bytes.includes(Buffer.from("pdfaid:part=\"2\" pdfaid:conformance=\"B\"")));
  assert.ok(pdf.bytes.includes(Buffer.from("/ICCBased 6 0 R")));
  assert.ok(pdf.bytes.includes(Buffer.from("/ID [<5149502D5356472D504446412D3242>")));
  assert.ok(pdf.bytes.includes(Buffer.from("/W [")));
  assert.ok(!pdf.bytes.includes(Buffer.from("/DeviceRGB")));
  assert.ok(pdf.bytes.includes(Buffer.from("/FontFile2")));
  assert.ok(pdf.bytes.includes(Buffer.from("/CIDFontType2")));
  assert.ok(pdf.bytes.includes(Buffer.from("/InterDisplay-Bold")));
  assert.ok(pdf.bytes.includes(Buffer.from("/InterDisplay-Italic")));
  assert.ok(pdf.bytes.includes(Buffer.from("/InterDisplay-BoldItalic")));
  assert.ok(pdf.bytes.includes(Buffer.from("/ShadingType 2")));
  assert.ok(pdf.bytes.includes(Buffer.from("/ShadingType 3")));
  assert.ok(pdf.bytes.includes(Buffer.from("/FunctionType 3")));
  assert.ok(pdf.bytes.includes(Buffer.from("/G1")));
  assert.ok(!pdf.bytes.includes(Buffer.from("/Image")));
  assert.equal(
    Buffer.from(new Uint8Array(converter.memory.buffer, converter.output_content_type_ptr(), converter.output_content_type_size())).toString("ascii"),
    "application/pdf",
  );

  const extractor = new WebAssembly.Instance(new WebAssembly.Module(await readFile(extractorPath))).exports;
  new Uint8Array(extractor.memory.buffer, extractor.input_ptr(), pdf.bytes.length).set(pdf.bytes);
  const text = decodeResult(extractor.render(pdf.bytes.length));
  assert.equal(text.failed, 0);
  assert.equal(decoder.decode(new Uint8Array(extractor.memory.buffer, text.pointer, text.size)), "Regular\nBold\nItalic\nBold Italic\n");
});

test("SVG to PDF rejects unsupported SVG instead of rasterizing", async () => {
  const converter = new WebAssembly.Instance(new WebAssembly.Module(await readFile(converterPath))).exports;
  const result = render(converter, encoder.encode('<svg width="1" height="1"><filter/></svg>'));
  assert.deepEqual(result, { size: 0, pointer: 0, failed: 1 });
});

test("SVG to PDF keeps element and group opacity as native PDF transparency", async () => {
  const converter = new WebAssembly.Instance(new WebAssembly.Module(await readFile(converterPath))).exports;
  const svg = encoder.encode('<svg width="96" height="48"><rect x="0" y="0" width="96" height="48" fill="#fff"/><g opacity="0.5"><rect x="8" y="8" width="32" height="32" fill="#f00"/><circle cx="32" cy="24" r="16" fill="#00f"/></g><rect x="48" y="8" width="32" height="32" fill="#0f0" stroke="#000" fill-opacity="0.4" stroke-opacity="0.7" opacity="0.6"/></svg>');
  const pdf = render(converter, svg);

  assert.equal(pdf.failed, 0);
  assert.ok(pdf.bytes.includes(Buffer.from("/Type /ExtGState /ca 0.500 /CA 0.500")));
  assert.ok(pdf.bytes.includes(Buffer.from("/Type /ExtGState /ca 0.400 /CA 0.700")));
  assert.ok(pdf.bytes.includes(Buffer.from("/Subtype /Form")));
  assert.ok(pdf.bytes.includes(Buffer.from("/Group << /S /Transparency /CS [/ICCBased 6 0 R] /I true /K false >>")));
  assert.ok(pdf.bytes.includes(Buffer.from("/XObject <<")));
  assert.ok(!pdf.bytes.includes(Buffer.from("/Image")));
});
