import { renderSize, renderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { inflateSync } from "node:zlib";

const componentPath = "application/warc/warc-add-open-graph-image-inter-png.wasm";

async function instantiate() {
  const { instance } = await WebAssembly.instantiate(await readFile(componentPath), {});
  return instance;
}

function warcRecord(targetURI, httpPayload) {
  const payload = Buffer.from(httpPayload);
  return Buffer.concat([
    Buffer.from(
      `WARC/1.1\r\nWARC-Type: response\r\nWARC-Target-URI: ${targetURI}\r\n` +
        `WARC-Date: 2026-01-02T03:04:05Z\r\nWARC-Record-ID: <urn:uuid:00000000-0000-4000-8000-000000000001>\r\n` +
        `Content-Type: application/http; msgtype=response\r\nContent-Length: ${payload.length}\r\n\r\n`,
    ),
    payload,
    Buffer.from("\r\n\r\n"),
  ]);
}

function htmlResponse(html) {
  return `HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n${html}`;
}

function render(instance, input) {
  const { exports } = instance;
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.length).set(input);
  const size = renderSize(exports, input.length);
  return Buffer.from(new Uint8Array(exports.memory.buffer, renderedOutputPointer(exports), size));
}

function parseRecords(archive) {
  const records = [];
  let i = 0;
  while (i < archive.length) {
    const headerEnd = archive.indexOf("\r\n\r\n", i);
    const header = archive.subarray(i, headerEnd).toString("latin1");
    const length = Number(header.match(/\r\nContent-Length: (\d+)/)[1]);
    const payload = archive.subarray(headerEnd + 4, headerEnd + 4 + length);
    const bodyStart = payload.indexOf("\r\n\r\n") + 4;
    records.push({
      header,
      uri: header.match(/WARC-Target-URI: (\S+)/)[1],
      httpHeader: payload.subarray(0, bodyStart).toString("latin1"),
      body: payload.subarray(bodyStart),
    });
    i = headerEnd + 4 + length + 4;
  }
  return records;
}

function decodeIndexedPNG(png) {
  assert.deepEqual([...png.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
  const chunks = {};
  const idat = [];
  let p = 8;
  while (p < png.length) {
    const length = png.readUInt32BE(p);
    const type = png.subarray(p + 4, p + 8).toString("latin1");
    const data = png.subarray(p + 8, p + 8 + length);
    if (type === "IDAT") idat.push(data);
    else chunks[type] = data;
    p += 12 + length;
  }
  const width = chunks.IHDR.readUInt32BE(0);
  const height = chunks.IHDR.readUInt32BE(4);
  // inflateSync checks the Adler-32 trailer and rejects malformed blocks.
  const filtered = inflateSync(Buffer.concat(idat));
  return { chunks, width, height, bitDepth: chunks.IHDR[8], colorType: chunks.IHDR[9], filtered };
}

test("adds an Inter title card PNG record and absolute og:image tags", async () => {
  const instance = await instantiate();
  const input = Buffer.concat([
    warcRecord(
      "https://qip.dev/docs/formats",
      htmlResponse("<!doctype html><html><head><title>Formats &amp; Encodings</title></head><body><h1>Formats</h1></body></html>"),
    ),
    warcRecord("https://qip.dev/style.css", "HTTP/1.1 200 OK\r\nContent-Type: text/css\r\n\r\nbody{}"),
  ]);
  const records = parseRecords(render(instance, input));
  assert.deepEqual(
    records.map((record) => record.uri),
    ["https://qip.dev/docs/formats", "https://qip.dev/_og/docs/formats.png", "https://qip.dev/style.css"],
  );

  const page = records[0].body.toString("utf8");
  assert.match(page, /<\/title><meta property="og:image" content="https:\/\/qip\.dev\/_og\/docs\/formats\.png" \/>\n/);
  assert.match(page, /<meta name="twitter:card" content="summary_large_image" \/>/);
  assert.match(page, /<meta name="twitter:image" content="https:\/\/qip\.dev\/_og\/docs\/formats\.png" \/>\n<\/head>/);
  assert.match(records[0].httpHeader, new RegExp(`Content-Length: ${records[0].body.length}\\r\\n`));

  const image = records[1];
  assert.match(image.header, /WARC-Date: 2026-01-02T03:04:05Z\r\n/);
  assert.match(image.httpHeader, /^HTTP\/1\.1 200 OK\r\nContent-Type: image\/png\r\n/);
  assert.match(image.httpHeader, new RegExp(`Content-Length: ${image.body.length}\\r\\n`));

  const png = decodeIndexedPNG(image.body);
  assert.equal(png.width, 1200);
  assert.equal(png.height, 630);
  assert.equal(png.bitDepth, 8);
  assert.equal(png.colorType, 3);
  assert.equal(png.chunks.tRNS, undefined);
  assert.deepEqual([...png.chunks.PLTE.subarray(0, 3)], [0xee, 0xcc, 0x33]);
  assert.deepEqual([...png.chunks.PLTE.subarray(255 * 3, 256 * 3)], [0x10, 0x10, 0x10]);
  assert.equal(png.filtered.length, 630 * 1201);

  // Text starts at the 96px margin: rows through the title have ink at or
  // after x = 96 and only background before it.
  let inkRows = 0;
  for (let y = 0; y < 630; y++) {
    const row = png.filtered.subarray(y * 1201 + 1, (y + 1) * 1201);
    assert.equal(png.filtered[y * 1201], 0);
    assert.ok(row.subarray(0, 96).every((index) => index === 0));
    if (row.includes(255)) inkRows++;
  }
  assert.ok(inkRows > 40, `expected solid ink in many rows, found ${inkRows}`);
});

test("uniforms set the card colors", async () => {
  const instance = await instantiate();
  instance.exports.uniform_set_text_color_rgba(0xffffffff);
  instance.exports.uniform_set_background_color_rgba(0x4b2e83ff);
  const input = warcRecord("https://qip.dev/", htmlResponse("<html><head><title>QIP</title></head><body></body></html>"));
  const png = decodeIndexedPNG(parseRecords(render(instance, input))[1].body);
  assert.deepEqual([...png.chunks.PLTE.subarray(0, 3)], [0x4b, 0x2e, 0x83]);
  assert.deepEqual([...png.chunks.PLTE.subarray(255 * 3, 256 * 3)], [0xff, 0xff, 0xff]);

  // Uniforms reset after each render.
  const again = decodeIndexedPNG(parseRecords(render(instance, input))[1].body);
  assert.deepEqual([...again.chunks.PLTE.subarray(0, 3)], [0xee, 0xcc, 0x33]);
});

test("leaves pages that already declare an image unchanged", async () => {
  const instance = await instantiate();
  const input = warcRecord(
    "https://qip.dev/",
    htmlResponse('<html><head><title>QIP</title><meta property="og:image" content="/card.png"></head><body></body></html>'),
  );
  assert.deepEqual(render(instance, input), input);
});

test("a template og:image URL sets the card text and colors for its page", async () => {
  const instance = await instantiate();
  instance.exports.uniform_set_text_color_rgba(0xffffffff);
  const template =
    "/_og/index.png?primary=A+new+way+to+render&amp;secondary=qip.dev+WebAssembly+everywhere&amp;background_color_rgba=0x4b2e83ff";
  const input = Buffer.concat([
    warcRecord("https://qip.dev/", htmlResponse(`<html><head><title>QIP</title><meta property="og:image" content="${template}"></head><body></body></html>`)),
    warcRecord("https://qip.dev/forms", htmlResponse("<html><head><title>Forms</title></head><body></body></html>")),
  ]);
  const records = parseRecords(render(instance, input));
  assert.deepEqual(
    records.map((record) => record.uri),
    ["https://qip.dev/", "https://qip.dev/_og/index.png", "https://qip.dev/forms", "https://qip.dev/_og/forms.png"],
  );
  const page = records[0].body.toString("utf8");
  assert.ok(!page.includes("?primary="));
  assert.match(page, /<\/title><meta property="og:image" content="https:\/\/qip\.dev\/_og\/index\.png" \/>\n/);

  // The query's background applies to its page; the call's text color
  // applies to both, and the next page gets the default background.
  const home = decodeIndexedPNG(records[1].body);
  assert.deepEqual([...home.chunks.PLTE.subarray(0, 3)], [0x4b, 0x2e, 0x83]);
  assert.deepEqual([...home.chunks.PLTE.subarray(255 * 3, 256 * 3)], [0xff, 0xff, 0xff]);
  const forms = decodeIndexedPNG(records[3].body);
  assert.deepEqual([...forms.chunks.PLTE.subarray(0, 3)], [0xee, 0xcc, 0x33]);
  assert.deepEqual([...forms.chunks.PLTE.subarray(255 * 3, 256 * 3)], [0xff, 0xff, 0xff]);

  // Two separate runs of ink rows: the primary block, then the secondary.
  let runs = 0;
  let inInk = false;
  for (let y = 0; y < 630; y++) {
    const ink = home.filtered.subarray(y * 1201 + 1, (y + 1) * 1201).some((index) => index !== 0);
    if (ink && !inInk) runs++;
    inInk = ink;
  }
  assert.ok(runs >= 2, `expected primary and secondary text bands, found ${runs}`);
});
