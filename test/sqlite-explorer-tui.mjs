import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

import { validateTerminalFrame } from "../npm/qiptui/qiptui.mjs";

const module = new WebAssembly.Module(readFileSync("tui/sqlite-explorer.wasm"));
const fixture = (name) => readFileSync(`application/vnd.sqlite3/fixtures/${name}.sqlite`);
const decoder = new TextDecoder("utf-8", { fatal: true });

const XK_TAB = 0xff09;
const XK_DOWN = 0xff54;
const XK_RIGHT = 0xff53;
const XK_END = 0xff57;
const XK_PAGE_DOWN = 0xff56;
const XK_ESCAPE = 0xff1b;

const plain = (frame) => frame.replace(/\x1b\[[0-9;]*m/g, "");

function explorer(bytes, columns = 100, lines = 20) {
  const api = new WebAssembly.Instance(module).exports;
  api.uniform_set_columns(columns);
  api.uniform_set_lines(lines);
  new Uint8Array(api.memory.buffer).set(bytes, api.input_ptr());
  const frame = (size) => {
    const packed = api.render(size);
    assert.equal(packed >> 63n, 0n);
    const length = Number(packed & 0xffffffffn);
    const pointer = Number((packed >> 32n) & 0x7fffffffn);
    return decoder.decode(validateTerminalFrame(new Uint8Array(api.memory.buffer, pointer, length)));
  };
  let clock = 0n;
  const key = (code) => {
    clock += 1n;
    api.begin_update_at(clock);
    const accepted = api.key_event(typeof code === "string" ? code.codePointAt(0) : code, 1);
    assert.equal(api.finish_update(), clock);
    return { accepted, frame: plain(frame(0)) };
  };
  return { api, initial: plain(frame(bytes.length)), key };
}

function frameWidths(frame) {
  return frame.split("\n").map((line) => [...line].length);
}

test("SQLite Explorer TUI lists tables and shows the first table's rows", () => {
  const view = explorer(fixture("titanic"));
  assert.match(view.initial, /SQLITE EXPLORER {2}8 tables · 17 pages of 4,096 bytes/);
  assert.match(view.initial, />Observation +891│/);
  assert.match(view.initial, /Observation {2}15 columns, 891 rows/);
  assert.match(view.initial, /rowid │ survived │ pclass │ age/);
  assert.match(view.initial, / 1 │ +0 │ +3 │ 22\.0 │/);
  assert.match(view.initial, /Row 1 of 891/);
  for (const width of frameWidths(view.initial)) assert.ok(width <= 100);
});

test("SQLite Explorer TUI moves between tables, the grid, and the schema", () => {
  const view = explorer(fixture("titanic"));
  let step = view.key(XK_DOWN);
  assert.equal(step.accepted, 1);
  assert.match(step.frame, />Sex +2│/);

  step = view.key(XK_TAB);
  assert.match(step.frame, /Arrows move/);
  view.key(XK_RIGHT);
  step = view.key(XK_DOWN);
  assert.match(step.frame, /Row 2 of 2/);
  assert.equal(view.key(XK_DOWN).accepted, 0, "the cursor stops at the last row");

  step = view.key("s");
  assert.match(step.frame, /\[Schema\]/);
  assert.match(step.frame, /CREATE STATEMENT/);
  step = view.key(XK_ESCAPE);
  assert.match(step.frame, /\[Rows\]/);

  let steps = 0;
  while (view.key("]").accepted === 1) steps += 1;
  assert.equal(steps, 6);
});

test("SQLite Explorer TUI pages and scrolls columns into view", () => {
  const view = explorer(fixture("titanic"), 80, 12);
  view.key(XK_TAB);
  let step = view.key(XK_PAGE_DOWN);
  assert.match(step.frame, /Row 6 of 891/);
  step = view.key("G");
  assert.match(step.frame, /Row 891 of 891/);
  assert.match(step.frame, / 891 │/);
  step = view.key(XK_END);
  assert.match(step.frame, /alive_id │/);
  assert.doesNotMatch(step.frame, /survived/);
});

test("SQLite Explorer TUI shows reals, blobs, NULLs, and rowid aliases", () => {
  const view = explorer(fixture("products"));
  assert.match(view.initial, /100 │ Sprocket │ +3\.25 │ +0 │ x'00' +│/);
  assert.match(view.initial, /Gadget +│ +19\.5 │ NULL +│ NULL/);
  view.key(XK_TAB);
  assert.match(view.key("s").frame, /id +INTEGER +rowid alias/);
});

test("SQLite Explorer TUI explains empty input and unreadable files", () => {
  assert.match(explorer(new Uint8Array()).initial, /No database loaded/);
  assert.match(explorer(new TextEncoder().encode("not a database")).initial, /not a SQLite database/);
  assert.match(explorer(fixture("wal-mode")).initial, /uses WAL mode/);
  assert.match(explorer(fixture("utf16")).initial, /UTF-16/);
});

test("SQLite Explorer TUI keeps WITHOUT ROWID tables in the list", () => {
  const view = explorer(fixture("kv-without-rowid"));
  assert.match(view.initial, />kv +—│/);
  assert.match(view.initial, /WITHOUT ROWID tables are not readable yet/);
});

test("SQLite Explorer TUI fits narrow and short terminals", () => {
  for (const [columns, lines] of [[20, 6], [40, 8], [47, 10], [48, 10], [240, 100]]) {
    const view = explorer(fixture("titanic"), columns, lines);
    for (const width of frameWidths(view.initial)) assert.ok(width <= columns, `${columns}x${lines}`);
    assert.ok(view.initial.split("\n").length <= lines);
    view.key(XK_TAB);
    for (const width of frameWidths(view.key("s").frame)) assert.ok(width <= columns);
  }
});

test("SQLite Explorer TUI keeps rows usable in a six-line terminal", () => {
  const view = explorer(fixture("products"), 40, 6);
  assert.match(view.initial, /1.*Widget/);
  assert.equal(view.key(XK_TAB).accepted, 0, "there is no visible sidebar to focus");
  assert.match(view.key(XK_DOWN).frame, /Row 2 of 3/);
  assert.equal(view.key(XK_ESCAPE).accepted, 0);
});

test("SQLite Explorer TUI cannot inject terminal controls and measures wide text", () => {
  const dir = mkdtempSync(join(tmpdir(), "sqlite-explorer-tui-"));
  try {
    const path = join(dir, "notes.sqlite");
    const db = new DatabaseSync(path);
    db.exec("CREATE TABLE notes (body TEXT, tag TEXT)");
    const insert = db.prepare("INSERT INTO notes VALUES (?, ?)");
    insert.run("one\u001b[2J‮two\u009bthree", "日本語");
    insert.run("line\nbreak", "ok");
    db.close();
    const view = explorer(readFileSync(path));
    const raw = view.initial;
    assert.ok(!/[‮\u009b]/.test(raw));
    assert.match(raw, /one \[2J\?two\?three/);
    assert.match(raw, /line¶break/);
    const row = raw.split("\n").find((line) => line.includes("日本語"));
    assert.match(row, /│ 日本語 │$/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("SQLite Explorer TUI traps events outside an update", () => {
  const view = explorer(fixture("countries"));
  assert.throws(() => view.api.key_event(XK_DOWN, 1), WebAssembly.RuntimeError);
});
