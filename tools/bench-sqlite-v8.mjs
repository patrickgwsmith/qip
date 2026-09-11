// Benchmarks the vnd.sqlite3 QIP components against the official sqlite3.wasm
// build (tools/sqlite-jswasm) inside V8, breaking out compile, instantiate,
// and execution time separately.
//
// Usage: node tools/bench-sqlite-v8.mjs [db-path]
//
// Without an argument it benchmarks the 5 MB USGS earthquakes database,
// downloading it to the OS temp dir on first run.

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const USGS_URL =
  "http://2016.padjo.org/files/data/starterpack/usgs/usgs-lower-us.sqlite";

const moduleDir = fileURLToPath(
  new URL("../application/vnd.sqlite3/", import.meta.url),
);
const jswasmDir = fileURLToPath(new URL("./sqlite-jswasm/", import.meta.url));

function fmtMs(x) {
  return `${x >= 100 ? x.toFixed(0) : x.toFixed(2)} ms`;
}

function fmtBytes(n) {
  if (n >= 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MB`;
  return `${(n / 1024).toFixed(1)} KB`;
}

function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.floor(s.length / 2)];
}

async function loadDb() {
  const arg = process.argv[2];
  if (arg) return { path: arg, bytes: new Uint8Array(readFileSync(arg)) };
  const cached = join(tmpdir(), "qip-bench-usgs.sqlite");
  if (!existsSync(cached)) {
    console.error(`downloading ${USGS_URL} ...`);
    const res = await fetch(USGS_URL);
    if (!res.ok) throw new Error(`download failed: ${res.status}`);
    writeFileSync(cached, Buffer.from(await res.arrayBuffer()));
  }
  // A plain Uint8Array (not a Node Buffer): the sqlite3 glue's
  // allocFromTypedArray rejects Buffer subclasses.
  return { path: cached, bytes: new Uint8Array(readFileSync(cached)) };
}

async function instantiateComponent(wasmBytes) {
  let t = performance.now();
  const module = await WebAssembly.compile(wasmBytes);
  const compileMs = performance.now() - t;

  t = performance.now();
  const instance = await WebAssembly.instantiate(module);
  const instantiateMs = performance.now() - t;

  return { instance, compileMs, instantiateMs };
}

function writeInput(instance, dbBytes) {
  const { memory, input_ptr, input_bytes_cap } = instance.exports;
  if (dbBytes.length > input_bytes_cap()) {
    throw new Error("database exceeds component input cap");
  }
  const t = performance.now();
  new Uint8Array(memory.buffer, input_ptr(), dbBytes.length).set(dbBytes);
  return performance.now() - t;
}

function renderOnce(instance, inputLen) {
  const t = performance.now();
  const result = BigInt.asUintN(64, instance.exports.render(inputLen));
  const renderMs = performance.now() - t;
  if ((result >> 63n) !== 0n) throw new Error("component rejected database");
  const outLen = Number(result & 0xffff_ffffn);
  const outPtr = Number((result >> 32n) & 0x7fff_ffffn);
  const out = new Uint8Array(
    instance.exports.memory.buffer,
    outPtr,
    outLen,
  );
  return { renderMs, out };
}

async function benchComponent(name, dbBytes, { uniforms = {}, warmRuns = 7 } = {}) {
  const wasmBytes = readFileSync(join(moduleDir, name));
  const { instance, compileMs, instantiateMs } = await instantiateComponent(wasmBytes);
  for (const [key, value] of Object.entries(uniforms)) {
    instance.exports[`uniform_set_${key}`](value);
  }
  const copyMs = writeInput(instance, dbBytes);

  const cold = renderOnce(instance, dbBytes.length);
  const warm = [];
  for (let i = 0; i < warmRuns; i += 1) {
    warm.push(renderOnce(instance, dbBytes.length).renderMs);
  }

  const text = new TextDecoder().decode(cold.out);
  const lines = text.length === 0 ? 0 : text.trimEnd().split("\n").length;

  console.log(`${name} (${fmtBytes(wasmBytes.length)})`);
  console.log(`  compile          ${fmtMs(compileMs)}`);
  console.log(`  instantiate      ${fmtMs(instantiateMs)}`);
  console.log(`  input copy       ${fmtMs(copyMs)}`);
  console.log(
    `  render (cold)    ${fmtMs(cold.renderMs)}  -> ${fmtBytes(cold.out.length)} output, ${lines} lines`,
  );
  console.log(`  render (warm)    ${fmtMs(median(warm))}  median of ${warmRuns}`);
  console.log();
  return { instance, text };
}

async function benchOfficial(dbBytes) {
  let t = performance.now();
  const { default: sqlite3InitModule } = await import(
    join(jswasmDir, "sqlite3.mjs")
  );
  const importMs = performance.now() - t;

  // Node's fetch cannot load file:// URLs, so instantiate the wasm ourselves
  // through the glue's sqlite3InitModuleState hook. This also lets us time
  // compile and instantiate the same way as for the QIP components.
  const wasmBinary = readFileSync(join(jswasmDir, "sqlite3.wasm"));
  let compileMs = 0;
  let instantiateMs = 0;
  globalThis.sqlite3InitModuleState = {
    debugModule: () => {},
    emscriptenInstantiateWasm: (imports, onSuccess) => {
      (async () => {
        let t2 = performance.now();
        const module = await WebAssembly.compile(wasmBinary);
        compileMs = performance.now() - t2;
        t2 = performance.now();
        const instance = await WebAssembly.instantiate(module, imports);
        instantiateMs = performance.now() - t2;
        onSuccess(instance, module);
      })();
      return {};
    },
  };

  t = performance.now();
  const sqlite3 = await sqlite3InitModule({
    print: () => {},
    printErr: () => {},
  });
  const initMs = performance.now() - t;

  t = performance.now();
  const db = new sqlite3.oo1.DB();
  const p = sqlite3.wasm.allocFromTypedArray(dbBytes);
  const rc = sqlite3.capi.sqlite3_deserialize(
    db.pointer,
    "main",
    p,
    dbBytes.length,
    dbBytes.length,
    sqlite3.capi.SQLITE_DESERIALIZE_FREEONCLOSE |
      sqlite3.capi.SQLITE_DESERIALIZE_READONLY,
  );
  db.checkRc(rc);
  const deserializeMs = performance.now() - t;

  const tableName = db.selectValue(
    "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' LIMIT 1",
  );

  // Full scan formatted to TSV text, matching what the QIP dump component
  // produces, so execution time compares like for like.
  const scan = () => {
    const rows = [];
    db.exec({
      sql: `SELECT * FROM "${tableName}"`,
      rowMode: "array",
      callback: (row) => {
        rows.push(row.map((v) => (v === null ? "NULL" : String(v))).join("\t"));
      },
    });
    return rows;
  };

  t = performance.now();
  const rows = scan();
  const scanColdMs = performance.now() - t;

  const warm = [];
  for (let i = 0; i < 7; i += 1) {
    t = performance.now();
    scan();
    warm.push(performance.now() - t);
  }

  const wasmSize = readFileSync(join(jswasmDir, "sqlite3.wasm")).length;
  console.log(`official sqlite3.wasm (${fmtBytes(wasmSize)} + JS glue)`);
  console.log(`  import js glue   ${fmtMs(importMs)}`);
  console.log(`  compile          ${fmtMs(compileMs)}`);
  console.log(`  instantiate      ${fmtMs(instantiateMs)}`);
  console.log(`  init total       ${fmtMs(initMs)}  (compile+instantiate+glue setup)`);
  console.log(`  deserialize db   ${fmtMs(deserializeMs)}`);
  console.log(`  full scan (cold) ${fmtMs(scanColdMs)}  -> ${rows.length} rows as TSV`);
  console.log(`  full scan (warm) ${fmtMs(median(warm))}  median of 7`);

  // Point lookups by rowid through a prepared statement, for comparison with
  // the sqlite-row-lookup component.
  const maxRowid = db.selectValue(`SELECT max(rowid) FROM "${tableName}"`);
  const stmt = db.prepare(`SELECT * FROM "${tableName}" WHERE rowid=?`);
  const lookups = 1000;
  t = performance.now();
  for (let i = 0; i < lookups; i += 1) {
    stmt.bind([1 + ((i * 7919) % maxRowid)]);
    while (stmt.step()) stmt.get([]);
    stmt.reset();
  }
  const lookupUs = ((performance.now() - t) / lookups) * 1000;
  stmt.finalize();
  console.log(`  rowid lookup     ${lookupUs.toFixed(1)} µs/lookup (${lookups} prepared-stmt lookups)`);
  console.log();

  db.close();
  return { rows, tableName, maxRowid };
}

async function benchComponentLookups(dbBytes, maxRowid) {
  const name = "sqlite-row-lookup.wasm";
  const wasmBytes = readFileSync(join(moduleDir, name));
  const { instance } = await instantiateComponent(wasmBytes);
  writeInput(instance, dbBytes);
  instance.exports.uniform_set_table(0);

  const lookups = 1000;
  const t = performance.now();
  for (let i = 0; i < lookups; i += 1) {
    instance.exports.uniform_set_rowid(BigInt(1 + ((i * 7919) % maxRowid)));
    instance.exports.render(dbBytes.length);
  }
  const lookupUs = ((performance.now() - t) / lookups) * 1000;
  console.log(`${name}`);
  console.log(
    `  rowid lookup     ${lookupUs.toFixed(1)} µs/render (${lookups} renders, header+descent each time)`,
  );
  console.log();
}

const { path, bytes } = await loadDb();
console.log(`database: ${path} (${fmtBytes(bytes.length)})`);
console.log(`node ${process.version}, v8 ${process.versions.v8}`);
console.log();

const dump = await benchComponent("sqlite-first-table-dump.wasm", bytes);
await benchComponent("sqlite-table-count.wasm", bytes);
await benchComponent("sqlite-schema.wasm", bytes);

const official = await benchOfficial(bytes);
await benchComponentLookups(bytes, official.maxRowid);

// Sanity: both scans should agree on row count.
const dumpRows = dump.text.trimEnd().split("\n").length - 4; // table/columns/types/rows header lines
if (dumpRows !== official.rows.length) {
  console.error(
    `row count mismatch: component ${dumpRows} vs official ${official.rows.length}`,
  );
  process.exitCode = 1;
} else {
  console.log(`row counts agree: ${dumpRows}`);
}
