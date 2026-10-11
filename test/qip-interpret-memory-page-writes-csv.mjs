import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { ContentComponentHost } from "./lib/content-component-host.mjs";

const runnerPath = "application/wasm/qip-interpret-memory-page-writes-csv.wasm";
const boundary = "uuid-00000000-0000-0000-0000-000000000000";
const encoder = new TextEncoder();
const decoder = new TextDecoder();
const header = "page,region,initialized_bytes,reads,bytes_read,writes,bytes_written,distinct_bytes_written,rewrite_ratio";

function multipart(parts) {
  const chunks = [];
  for (const [name, body] of parts) {
    chunks.push(
      Buffer.from(
        `--${boundary}\r\n` +
        `Content-Disposition: form-data; name="${name}"\r\n\r\n`,
      ),
      Buffer.from(body),
      Buffer.from("\r\n"),
    );
  }
  chunks.push(Buffer.from(`--${boundary}--\r\n`));
  return Buffer.concat(chunks);
}

function parseRows(csv) {
  const lines = csv.trimEnd().split("\n");
  assert.equal(lines[0], header);
  return lines.slice(1).map((line) => {
    const [page, region, initializedBytes, reads, bytesRead, writes, bytesWritten, distinctBytes, ratio] = line.split(",");
    return {
      page: Number(page),
      regions: region.split("+"),
      initializedBytes: Number(initializedBytes),
      reads: Number(reads),
      bytesRead: Number(bytesRead),
      writes: Number(writes),
      bytesWritten: Number(bytesWritten),
      distinctBytes: Number(distinctBytes),
      ratio,
    };
  });
}

test("reports one consistent row per initialized, read, or written page", async () => {
  const [runner, target] = await Promise.all([
    readFile(runnerPath),
    readFile("text/markdown/commonmark.0.31.2.wasm"),
  ]);
  const host = new ContentComponentHost(runner, { label: "memory page writes" });
  const result = host.run(multipart([
    ["component", target],
    ["input", encoder.encode("# Hello\n\nSome *text* with [a link](https://example.com).\n")],
  ]));
  assert.equal(result.status, "accepted");

  const rows = parseRows(decoder.decode(result.output));
  assert.ok(rows.length > 0);
  let previousPage = -1;
  for (const row of rows) {
    assert.ok(row.page > previousPage, "pages ascend without duplicates");
    previousPage = row.page;
    assert.ok(row.initializedBytes > 0 || row.reads > 0 || row.writes > 0, "untouched pages are skipped");
    assert.ok(row.bytesRead >= row.reads);
    assert.ok(row.distinctBytes <= 65536);
    assert.ok(row.bytesWritten >= row.distinctBytes);
    assert.equal(row.writes > 0, row.distinctBytes > 0);
    assert.equal(row.ratio, row.writes > 0 ? (row.bytesWritten / row.distinctBytes).toFixed(2) : "");
    for (const region of row.regions) assert.ok(["data", "input", "stack", "output", "other"].includes(region));
  }
  assert.ok(rows.some((row) => row.regions.includes("output")));
  assert.ok(rows.some((row) => row.regions.includes("data") && row.initializedBytes > 0));
  assert.ok(rows.some((row) => row.reads > 0));
});

test("rejects a missing or invalid target", async () => {
  const runner = await readFile(runnerPath);
  const host = new ContentComponentHost(runner, { label: "memory page writes" });
  assert.equal(host.run(multipart([["input", encoder.encode("rgb(1, 2, 3)")]])).status, "rejected");
  assert.equal(host.run(multipart([["component", encoder.encode("not wasm")]])).status, "rejected");
});

test("declares CSV output", async () => {
  const runner = await readFile(runnerPath);
  const { instance } = await WebAssembly.instantiate(runner);
  const pointer = instance.exports.output_content_type_ptr();
  const size = instance.exports.output_content_type_size();
  assert.equal(decoder.decode(new Uint8Array(instance.exports.memory.buffer, pointer, size)), "text/csv");
});
