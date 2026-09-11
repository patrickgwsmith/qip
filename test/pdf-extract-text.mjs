import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { deflateSync } from "node:zlib";
import test from "node:test";

const execFileAsync = promisify(execFile);
const qip = join(process.cwd(), "qip");
const modulePath = join(
  process.cwd(),
  "application/pdf/pdf-extract-text.wasm",
);

function plainObject(number, body) {
  return Buffer.from(`${number} 0 obj\n${body}\nendobj\n`, "latin1");
}

function streamObject(number, dictionary, stream) {
  return Buffer.concat([
    Buffer.from(`${number} 0 obj\n<< ${dictionary} /Length ${stream.length} >>\nstream\n`, "latin1"),
    stream,
    Buffer.from("\nendstream\nendobj\n", "latin1"),
  ]);
}

function buildPdf(objects) {
  return Buffer.concat([
    Buffer.from("%PDF-1.7\n%\x80\x81\x82\x83\n", "latin1"),
    ...objects,
    Buffer.from("trailer\n<< /Size 99 >>\n%%EOF\n", "latin1"),
  ]);
}

async function extract(pdf) {
  const directory = await mkdtemp(join(tmpdir(), "qip-pdf-text-"));
  const input = join(directory, "input.pdf");
  const output = join(directory, "output.txt");
  await writeFile(input, pdf);
  await execFileAsync(qip, ["run", "-i", input, "-o", output, "--", modulePath]);
  return readFile(output, "utf8");
}

test("reconstructs positioned lines, inserts spaces, suppresses duplicate glyphs, and separates pages", async () => {
  const firstPage = Buffer.from([
    "BT",
    "/F1 18 Tf 1 0 0 1 72 720 Tm (Heading) Tj",
    "/F1 12 Tf 1 0 0 1 72 690 Tm (Hello) Tj",
    "1 0 0 1 110 690 Tm (world) Tj",
    "1 0 0 1 110 690 Tm (world) Tj",
    "ET",
  ].join("\n"), "latin1");
  const secondPage = Buffer.from("BT /F1 12 Tf 72 700 Td [(Second) -500 (page)] TJ ET", "latin1");
  const pdf = buildPdf([
    plainObject(1, "<< /Type /Catalog /Pages 2 0 R >>"),
    plainObject(2, "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>"),
    plainObject(3, "<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 4 0 R >> >> /Contents 6 0 R >>"),
    plainObject(4, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
    plainObject(5, "<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 4 0 R >> >> /Contents 7 0 R >>"),
    streamObject(6, "", firstPage),
    streamObject(7, "/Filter /FlateDecode", deflateSync(secondPage)),
  ]);

  assert.equal(await extract(pdf), "Heading\nHello world\n\fSecond page\n");
});

test("uses a simple ToUnicode CMap for composite-font text", async () => {
  const cmap = Buffer.from([
    "begincmap",
    "2 beginbfchar",
    "<0001> <0048>",
    "<0002> <0069>",
    "endbfchar",
    "endcmap",
  ].join("\n"), "ascii");
  const content = Buffer.from("BT /F2 12 Tf 1 0 0 1 72 700 Tm <00010002> Tj ET", "ascii");
  const pdf = buildPdf([
    plainObject(1, "<< /Type /Catalog /Pages 2 0 R >>"),
    plainObject(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
    plainObject(3, "<< /Type /Page /Parent 2 0 R /Resources << /Font << /F2 4 0 R >> >> /Contents 5 0 R >>"),
    plainObject(4, "<< /Type /Font /Subtype /Type0 /BaseFont /Fixture /Encoding /Identity-H /ToUnicode 6 0 R >>"),
    streamObject(5, "", content),
    streamObject(6, "", cmap),
  ]);

  assert.equal(await extract(pdf), "Hi\n");
});
