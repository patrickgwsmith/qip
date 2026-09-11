<title>SQLite as a payload</title>

# SQLite as a payload

A SQLite database file is a compact, typed, self-describing payload — often a better wire format than JSON. Serve the `.sqlite` file directly and read it in the browser with QIP components that weigh 10–21 KB, instead of shipping the 849 KB official engine for read-only work.

The same bytes stay compatible with the official `sqlite3.wasm`, so an app can render instantly with a tiny reader and lazily upgrade to the full engine only when someone needs SQL or writes. The [comparison below](#same-result-much-less-to-load) proves both readers return the identical result.

## Browse a database

This lists every table with its columns and declared types. The database arrives like any other asset: a `<source>` element pointing at [/data/countries.sqlite](/data/countries.sqlite) (48 KB).

<form aria-label="SQLite schema preview">
  <qip-edit>
    <source name="input" src="/data/countries.sqlite" type="application/vnd.sqlite3" />
    <source src="/application/vnd.sqlite3/sqlite-schema.wasm" type="application/wasm" />
    <output name="output"><pre><code></code></pre></output>
  </qip-edit>
</form>

```html
<qip-edit>
  <source name="input" src="/data/countries.sqlite" type="application/vnd.sqlite3" />
  <source src="/application/vnd.sqlite3/sqlite-schema.wasm" type="application/wasm" />
  <output name="output"><pre><code></code></pre></output>
</qip-edit>
```

The `<source name="input">` element is the input and the wasm `<source>` is the pipeline. The input's `type` attribute must match the component's declared `application/vnd.sqlite3` input type.

## Any table to CSV

The [Titanic dataset](/data/titanic.sqlite) (68 KB) holds eight tables. Pick one and `sqlite-table-csv.wasm` (19 KB) converts it to CSV, entirely in your browser.

<form aria-label="SQLite table to CSV">
  <qip-edit>
    <source name="input" src="/data/titanic.sqlite" type="application/vnd.sqlite3" />
    <source src="/application/vnd.sqlite3/sqlite-table-csv.wasm" type="application/wasm" data-uniform-table="" />
    <p>
      <label>Table
        <select name="uniform-table">
          <option value="0" selected>Observation</option>
          <option value="1">Sex</option>
          <option value="2">Embarked</option>
          <option value="3">Class</option>
          <option value="4">Who</option>
          <option value="5">Deck</option>
          <option value="6">EmbarkTown</option>
          <option value="7">Alive</option>
        </select>
      </label>
    </p>
    <output name="output" style="display: block; max-height: 20rem; overflow: auto;"><pre><code></code></pre></output>
  </qip-edit>
</form>

Uniforms come from ordinary form controls: the `<select name="uniform-table">` feeds the component's `uniform_set_table` export, exactly like `?table=N` on the CLI.

## Point lookup by rowid

`sqlite-row-lookup.wasm` (21 KB) descends the table's b-tree instead of scanning it — it touches a handful of pages to fetch one row out of 891.

<form aria-label="SQLite row lookup">
  <qip-edit>
    <source name="input" src="/data/titanic.sqlite" type="application/vnd.sqlite3" />
    <source src="/application/vnd.sqlite3/sqlite-row-lookup.wasm" type="application/wasm" data-uniform-table="0" data-uniform-rowid="" />
    <p>
      <label>Passenger rowid
        <input type="number" name="uniform-rowid" value="1" min="1" max="891" />
      </label>
    </p>
    <output name="output"><pre><code></code></pre></output>
  </qip-edit>
</form>

## Bring your own database

Drop any SQLite file here and browse its schema. Nothing is uploaded: the file is read locally into the component's memory. Until you choose a file, the preview falls back to the countries database.

<form aria-label="Inspect your own SQLite database">
  <qip-edit>
    <source name="input" src="/data/countries.sqlite" type="application/vnd.sqlite3" />
    <source src="/application/vnd.sqlite3/sqlite-schema.wasm" type="application/wasm" />
    <p><input type="file" name="input" accept=".sqlite,.sqlite3,.db,application/vnd.sqlite3" /></p>
    <output name="output"><pre><code></code></pre></output>
  </qip-edit>
</form>

Databases should be published with `VACUUM INTO 'payload.sqlite'` — that guarantees a single clean UTF-8 file with no WAL sidecar and no freelist bloat. The readers deliberately reject WAL-mode and UTF-16 files with a clear error rather than risk stale or garbled reads.

## Same result, much less to load

Both readers below convert the Titanic `Observation` table (891 rows) to CSV: the 19 KB QIP component, and the official 849 KB `sqlite3.wasm` running `SELECT *`. The outputs are compared byte for byte.

<style>
#sqlite-compare-table td:nth-child(2),
#sqlite-compare-table td:nth-child(3) {
  text-align: right;
  font-variant-numeric: tabular-nums;
}
</style>

<p>
  <button id="sqlite-compare-run" type="button">Run comparison</button>
  <span id="sqlite-compare-status" role="status"></span>
</p>

<table id="sqlite-compare-table" hidden>
  <thead>
    <tr><th>Phase</th><th>QIP component</th><th>Official sqlite3.wasm</th></tr>
  </thead>
  <tbody>
    <tr><td>Download (uncompressed)</td><td id="cmp-size-qip"></td><td id="cmp-size-official"></td></tr>
    <tr><td>Compile + instantiate</td><td id="cmp-setup-qip"></td><td id="cmp-setup-official"></td></tr>
    <tr><td>Open database (68 KB)</td><td id="cmp-open-qip"></td><td id="cmp-open-official"></td></tr>
    <tr><td>Read table → CSV (891 rows)</td><td id="cmp-read-qip"></td><td id="cmp-read-official"></td></tr>
    <tr><td><strong>Total</strong></td><td id="cmp-total-qip"></td><td id="cmp-total-official"></td></tr>
  </tbody>
</table>

<p id="sqlite-compare-verdict" role="status"></p>

<script type="module">
const runButton = document.getElementById("sqlite-compare-run");
const status = document.getElementById("sqlite-compare-status");
const table = document.getElementById("sqlite-compare-table");
const verdict = document.getElementById("sqlite-compare-verdict");

const setCell = (id, text) => { document.getElementById(id).textContent = text; };
const fmtMs = (x) => `${x >= 100 ? x.toFixed(0) : x.toFixed(1)} ms`;
const fmtKB = (n) => n >= 1024 * 1024
  ? `${(n / (1024 * 1024)).toFixed(1)} MB`
  : `${(n / 1024).toFixed(0)} KB`;

async function fetchBytes(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`failed to fetch ${url} (${response.status})`);
  return new Uint8Array(await response.arrayBuffer());
}

async function runComponent(dbBytes) {
  let t = performance.now();
  const wasmBytes = await fetchBytes("/application/vnd.sqlite3/sqlite-table-csv.wasm");
  const downloadMs = performance.now() - t;

  t = performance.now();
  const module = await WebAssembly.compile(wasmBytes);
  const { exports } = await WebAssembly.instantiate(module, {});
  const setupMs = performance.now() - t;

  t = performance.now();
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), dbBytes.length).set(dbBytes);
  const openMs = performance.now() - t;

  t = performance.now();
  exports.uniform_set_table(0);
  const packed = BigInt.asUintN(64, exports.render(dbBytes.length));
  if ((packed >> 63n) !== 0n) throw new Error("component rejected database");
  const outputLen = Number(packed & 0xffff_ffffn);
  const outputPtr = Number((packed >> 32n) & 0x7fff_ffffn);
  const csv = new TextDecoder().decode(
    new Uint8Array(exports.memory.buffer, outputPtr, outputLen),
  );
  const readMs = performance.now() - t;

  return { size: wasmBytes.length, downloadMs, setupMs, openMs, readMs, csv };
}

async function runOfficial(dbBytes) {
  let t = performance.now();
  const wasmHead = await fetch("/sqlite-jswasm/sqlite3.wasm", { method: "HEAD" });
  const size = Number(wasmHead.headers.get("content-length")) || 868996;
  const { default: sqlite3InitModule } = await import("/sqlite-jswasm/sqlite3.mjs");
  const downloadMs = performance.now() - t;

  t = performance.now();
  const sqlite3 = await sqlite3InitModule({ print: () => {}, printErr: () => {} });
  const setupMs = performance.now() - t;

  t = performance.now();
  const db = new sqlite3.oo1.DB();
  const p = sqlite3.wasm.allocFromTypedArray(dbBytes);
  db.checkRc(sqlite3.capi.sqlite3_deserialize(
    db.pointer, "main", p, dbBytes.length, dbBytes.length,
    sqlite3.capi.SQLITE_DESERIALIZE_FREEONCLOSE | sqlite3.capi.SQLITE_DESERIALIZE_READONLY,
  ));
  const openMs = performance.now() - t;

  t = performance.now();
  const columnNames = [];
  const lines = [];
  db.exec({
    sql: "SELECT * FROM \"Observation\"",
    rowMode: "array",
    columnNames,
    callback: (row) => {
      lines.push(row.map((v) => (v === null ? "" : String(v))).join(","));
    },
  });
  const csv = `${columnNames.join(",")}\n${lines.join("\n")}\n`;
  const readMs = performance.now() - t;

  db.close();
  return { size, downloadMs, setupMs, openMs, readMs, csv };
}

async function runComparison() {
  runButton.disabled = true;
  status.textContent = "Running…";
  verdict.textContent = "";
  try {
    const dbBytes = await fetchBytes("/data/titanic.sqlite");
    const qip = await runComponent(dbBytes);
    const official = await runOfficial(new Uint8Array(dbBytes));

    setCell("cmp-size-qip", fmtKB(qip.size));
    setCell("cmp-size-official", `${fmtKB(official.size)} + JS glue`);
    setCell("cmp-setup-qip", fmtMs(qip.setupMs));
    setCell("cmp-setup-official", fmtMs(official.setupMs));
    setCell("cmp-open-qip", fmtMs(qip.openMs));
    setCell("cmp-open-official", fmtMs(official.openMs));
    setCell("cmp-read-qip", fmtMs(qip.readMs));
    setCell("cmp-read-official", fmtMs(official.readMs));
    setCell("cmp-total-qip", fmtMs(qip.downloadMs + qip.setupMs + qip.openMs + qip.readMs));
    setCell("cmp-total-official", fmtMs(official.downloadMs + official.setupMs + official.openMs + official.readMs));
    table.hidden = false;

    const rows = qip.csv.trimEnd().split("\n").length - 1;
    verdict.textContent = qip.csv === official.csv
      ? `✓ Both readers produced the identical ${rows}-row CSV (${qip.csv.length.toLocaleString()} bytes).`
      : "✗ Outputs differ — this is a bug worth reporting.";
    status.textContent = "Done. Run again for warm-cache numbers.";
  } catch (error) {
    status.textContent = error instanceof Error ? error.message : String(error);
  } finally {
    runButton.disabled = false;
  }
}

runButton.addEventListener("click", runComparison);
</script>

The official engine remains the right tool for SQL queries, joins, and writes. The point is sequencing: readers this small make it practical to treat `.sqlite` as a first-class response format, then load the full engine only for the minority of sessions that edit.

## CLI equivalent

```bash
go install github.com/royalicing/qip@latest

# List tables, columns, and types
qip run application/vnd.sqlite3/sqlite-schema.wasm -i mydb.sqlite

# Convert the second table to CSV
qip run application/vnd.sqlite3/sqlite-table-csv.wasm -u table=1 -i mydb.sqlite > table.csv

# Fetch one row by rowid
qip run application/vnd.sqlite3/sqlite-row-lookup.wasm -u table=0 -u rowid=42 -i mydb.sqlite

# Count rows
qip run application/vnd.sqlite3/sqlite-table-count.wasm -i mydb.sqlite
```

These modules expect `application/vnd.sqlite3` input. The CSV converter outputs `text/csv`, so it composes with any downstream CSV component.
