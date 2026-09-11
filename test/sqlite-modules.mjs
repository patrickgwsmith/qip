import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { access, readFile } from "node:fs/promises";
import { constants } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileP = promisify(execFile);

const qip = fileURLToPath(new URL("../qip", import.meta.url));
const tableNames = fileURLToPath(
  new URL("../application/vnd.sqlite3/sqlite-table-names.wasm", import.meta.url),
);
const firstTableDump = fileURLToPath(
  new URL("../application/vnd.sqlite3/sqlite-first-table-dump.wasm", import.meta.url),
);

function module(name) {
  return fileURLToPath(
    new URL(`../application/vnd.sqlite3/${name}.wasm`, import.meta.url),
  );
}

function fixture(name) {
  return fileURLToPath(new URL(`../fixtures/sqlite3/${name}`, import.meta.url));
}

async function ensurePrerequisites(t) {
  try {
    await access(qip, constants.X_OK);
    await access(tableNames, constants.R_OK);
    await access(firstTableDump, constants.R_OK);
  } catch {
    t.skip("build ./qip and components first");
  }
}

async function runQip(modulePath, input, query) {
  const args = ["run", "-i", input, modulePath];
  if (query) args.push(query);
  const { stdout } = await execFileP(qip, args, {
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
  });
  return stdout;
}

async function instantiateWithInput(modulePath, inputPath) {
  const [wasm, input] = await Promise.all([
    readFile(modulePath),
    readFile(inputPath),
  ]);
  const { instance } = await WebAssembly.instantiate(wasm);
  assert.ok(input.length <= instance.exports.input_bytes_cap());
  new Uint8Array(instance.exports.memory.buffer).set(
    input,
    instance.exports.input_ptr(),
  );
  return { instance, inputSize: input.length };
}

function renderUtf8(instance, inputSize) {
  const outputSize = qipRenderSize(instance.exports, inputSize);
  return new TextDecoder("utf-8", { fatal: true }).decode(
    new Uint8Array(
      instance.exports.memory.buffer,
      qipRenderedOutputPointer(instance.exports),
      outputSize,
    ),
  );
}

test("table names lists all user tables in simplefolks", async (t) => {
  await ensurePrerequisites(t);
  const out = await runQip(tableNames, fixture("simplefolks.sqlite"));
  assert.deepEqual(out.trim().split("\n").sort(), [
    "homes",
    "inmates",
    "people",
    "pets",
    "politicians",
  ]);
});

test("first table dump substitutes rowid for INTEGER PRIMARY KEY columns", async (t) => {
  await ensurePrerequisites(t);
  const out = await runQip(firstTableDump, fixture("products.sqlite"));
  assert.equal(
    out.trimEnd(),
    "table\tproducts\n" +
      "columns\tid\tname\tprice\tstock\ticon\n" +
      "types\tINTEGER\tTEXT\tREAL\tINTEGER\tBLOB\n" +
      "rows\n" +
      "1\tWidget\t9.99\t3\tx'C0FFEE'\n" +
      "2\tGadget\t19.5\tNULL\tNULL\n" +
      "100\tSprocket\t3.25\t0\tx'00'",
  );
});

test("first table dump handles table-level PRIMARY KEY constraints", async (t) => {
  await ensurePrerequisites(t);
  const out = await runQip(firstTableDump, fixture("albums-tablepk.sqlite"));
  assert.equal(
    out.trimEnd(),
    "table\talbums\n" +
      "columns\tAlbumId\tTitle\n" +
      "types\tINTEGER\tTEXT\n" +
      "rows\n" +
      "1\tFirst\n" +
      "2\tSecond",
  );
});

test("first table dump reads countries fixture", async (t) => {
  await ensurePrerequisites(t);
  const out = await runQip(firstTableDump, fixture("countries.sqlite"));
  const lines = out.trim().split("\n");
  assert.equal(lines[0], "table\tcountries");
  assert.equal(lines[1], "columns\tiso_3166_code\tname_en\tcurrency");
  assert.equal(lines[3], "rows");
  assert.equal(lines.length - 4, 14);
  assert.ok(lines.includes("AU\tAustralia\tAUD"));
});

test("first table dump walks multi-page tables with floats and NULLs", async (t) => {
  await ensurePrerequisites(t);
  const out = await runQip(firstTableDump, fixture("titanic.sqlite"));
  const lines = out.trim().split("\n");
  assert.equal(lines[0], "table\tObservation");
  const rows = lines.slice(lines.indexOf("rows") + 1);
  assert.equal(rows.length, 891);
  assert.equal(rows[0], "0\t3\t22\t1\t0\t7.25\t1\t0\t1\t2\t2\t1\t-1\t2\t0");
});

test("first table dump rejects WITHOUT ROWID tables", async (t) => {
  await ensurePrerequisites(t);
  const out = await runQip(firstTableDump, fixture("kv-without-rowid.sqlite"));
  assert.equal(out.trimEnd(), "error\tWITHOUT ROWID tables are not supported");
});

test("first table dump rejects WAL-mode databases", async (t) => {
  await ensurePrerequisites(t);
  const out = await runQip(firstTableDump, fixture("wal-mode.sqlite"));
  assert.equal(
    out.trimEnd(),
    "error\tWAL-mode database not supported; rewrite with VACUUM INTO before serving",
  );
});

test("first table dump rejects UTF-16 databases", async (t) => {
  await ensurePrerequisites(t);
  const out = await runQip(firstTableDump, fixture("utf16.sqlite"));
  assert.equal(
    out.trimEnd(),
    "error\tunsupported text encoding; only UTF-8 databases are supported",
  );
});

test("schema lists every table with columns and root pages", async (t) => {
  await ensurePrerequisites(t);
  const out = await runQip(module("sqlite-schema"), fixture("products.sqlite"));
  assert.equal(
    out.trimEnd(),
    "table\tproducts\n" +
      "rootpage\t2\n" +
      "columns\tid\tname\tprice\tstock\ticon\n" +
      "types\tINTEGER\tTEXT\tREAL\tINTEGER\tBLOB",
  );
});

test("schema lists multiple tables separated by blank lines", async (t) => {
  await ensurePrerequisites(t);
  const out = await runQip(module("sqlite-schema"), fixture("simplefolks.sqlite"));
  const blocks = out.trimEnd().split("\n\n");
  assert.equal(blocks.length, 5);
  assert.match(blocks[0], /^table\thomes\n/);
  assert.match(blocks[1], /^table\tpeople\n/);
});

test("table dump selects table by ordinal with limit and offset", async (t) => {
  await ensurePrerequisites(t);
  const out = await runQip(
    module("sqlite-table-dump"),
    fixture("simplefolks.sqlite"),
    "?table=1&limit=2&offset=1",
  );
  assert.equal(
    out.trimEnd(),
    "table\tpeople\n" +
      "columns\tname\tsex\tage\n" +
      "types\tTEXT\tTEXT\tINTEGER\n" +
      "rows\n" +
      "Blair\tM\t90\n" +
      "Carolina\tF\t28",
  );
});

test("table dump errors on out-of-range table ordinal", async (t) => {
  await ensurePrerequisites(t);
  const out = await runQip(
    module("sqlite-table-dump"),
    fixture("products.sqlite"),
    "?table=9",
  );
  assert.equal(out.trimEnd(), "error\ttable index out of range");
});

test("table csv escapes commas and renders IPK, NULL, and blobs", async (t) => {
  await ensurePrerequisites(t);
  const out = await runQip(module("sqlite-table-csv"), fixture("products.sqlite"));
  assert.equal(
    out.trimEnd(),
    "id,name,price,stock,icon\n" +
      "1,Widget,9.99,3,x'C0FFEE'\n" +
      "2,Gadget,19.5,,\n" +
      "100,Sprocket,3.25,0,x'00'",
  );

  const deathrow = await runQip(
    module("sqlite-table-csv"),
    fixture("florida-deathrow.sqlite"),
  );
  assert.match(deathrow, /^"Hall, Freddie",022762,BM/m);
});

test("row lookup fetches one row by rowid via b-tree descent", async (t) => {
  await ensurePrerequisites(t);
  const out = await runQip(
    module("sqlite-row-lookup"),
    fixture("products.sqlite"),
    "?rowid=100",
  );
  assert.equal(
    out.trimEnd(),
    "table\tproducts\n" +
      "columns\tid\tname\tprice\tstock\ticon\n" +
      "types\tINTEGER\tTEXT\tREAL\tINTEGER\tBLOB\n" +
      "rows\n" +
      "100\tSprocket\t3.25\t0\tx'00'",
  );
});

test("row lookup reports missing rowids", async (t) => {
  await ensurePrerequisites(t);
  const out = await runQip(
    module("sqlite-row-lookup"),
    fixture("products.sqlite"),
    "?rowid=99",
  );
  assert.equal(out.trimEnd(), "error\trowid not found");
});

test("table count walks multi-page tables", async (t) => {
  await ensurePrerequisites(t);
  const out = await runQip(module("sqlite-table-count"), fixture("titanic.sqlite"));
  assert.equal(out.trimEnd(), "891");

  const worowid = await runQip(
    module("sqlite-table-count"),
    fixture("kv-without-rowid.sqlite"),
  );
  assert.equal(worowid.trimEnd(), "error\tWITHOUT ROWID tables are not supported");
});

test("table count resets its table uniform after counts and diagnostics", async () => {
  const { instance, inputSize } = await instantiateWithInput(
    module("sqlite-table-count"),
    fixture("simplefolks.sqlite"),
  );

  instance.exports.uniform_set_table(1);
  assert.equal(renderUtf8(instance, inputSize), "15\n");
  assert.equal(renderUtf8(instance, inputSize), "20\n");

  instance.exports.uniform_set_table(99);
  assert.equal(
    renderUtf8(instance, inputSize),
    "error\ttable index out of range\n",
  );
  assert.equal(renderUtf8(instance, inputSize), "20\n");
});
