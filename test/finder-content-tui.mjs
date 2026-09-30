import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { ContentComponentHost } from "./lib/content-component-host.mjs";
import { textInputMode, validateTerminalFrame, validateTUIBinary } from "../npm/qiptui/qiptui.mjs";

const cases = [
  ["country-finder", "australia", /Capital: Canberra/, 249],
  ["tld-finder", "中国", /ASCII \/ IDNA: .xn--fiqs8s/, 1438],
  ["iana-media-type-finder", "application/json", /RFC 8259/, 2361],
  ["iana-service-port-finder", "53 udp", /53\/udp.*domain/, 11723],
  ["browser-compat-finder", "api.AbortController", /Safari: 12.1\+ history/, 13603],
  ["caniuse-finder", "css-grid", /CSS Grid Layout/, 554],
];
function finder(bytes) {
  const host = new ContentComponentHost(bytes);
  return { get exports() { return (host.instance ?? host.instantiate()).exports; }, render(query = "", uniforms = {}) {
    const result = host.run(query, { uniforms });
    assert.equal(result.status, "accepted");
    validateTerminalFrame(result.output);
    return new TextDecoder("utf-8", { fatal: true }).decode(result.output);
  } };
}
for (const [name, query, expected, count] of cases) {
  const bytes = await readFile(`tui/${name}.wasm`);
  test(`${name}: plain text search, bounded navigation, and repeatable Content renders`, () => {
    validateTUIBinary(bytes);
    const f = finder(bytes);
    assert.equal(textInputMode(f.exports), true);
    const baseline = f.render();
    assert.equal(f.exports.active_count(), count);
    for (const exportName of ["key_event", "begin_update_at", "finish_update"]) assert.equal(f.exports[exportName], undefined);
    const frame = f.render(query);
    assert.match(frame, expected);
    assert.ok(f.exports.active_count() > 0);
    assert.doesNotMatch(frame, /Enter|Escape|Find:/);
    assert.equal(f.render(`  ${query}  `), frame);
    f.render(query, { active_index: 0xffffffff, detail_offset: 0xffffffff, columns: 35, lines: 12 });
    assert.equal(f.render(), baseline);
    assert.equal(f.render(query, { active_index: 1 }), finder(bytes).render(query, { active_index: 1 }));
    assert.match(f.render("unlikely-to-match-qzxv", { active_index: 100 }), /No matches/);
    assert.equal(f.exports.active_count(), 0);
    assert.equal(f.exports.detail_count(), 0);
    for (const columns of [1, 20, 80, 160]) for (const lines of [1, 8, 10, 24, 60]) {
      const output = f.render(query, { columns, lines, active_index: 0xffffffff, detail_offset: 0xffffffff });
      assert.ok(output.trimEnd().split("\n").length <= lines);
      assert.ok(output.trimEnd().split("\n").every(line => [...line].length <= columns));
    }
    assert.throws(() => f.exports.render(1025), WebAssembly.RuntimeError);
  });
  if (name === "browser-compat-finder" || name === "caniuse-finder") {
    test(`${name}: each result is one feature, all browser summaries precede paged notes`, () => {
      const f = finder(bytes);
      const frame = f.render(query);
      assert.match(frame, /Chrome:/);
      assert.match(frame, /Firefox:/);
      assert.match(frame, /Safari:/);
      assert.match(frame, /Edge:/);
      const count = f.exports.active_count();
      const total = f.exports.detail_count();
      const page = f.exports.detail_page_size();
      assert.ok(total > page);
      const next = f.render(query, { detail_offset: page });
      assert.notEqual(next, frame);
      assert.equal(f.exports.active_count(), count);
      assert.equal(next.split("DETAILS")[0], frame.split("DETAILS")[0]);
      const last = f.render(query, { detail_offset: 0xffffffff });
      assert.match(last, /Snapshot:/);
      assert.equal(f.render(query), frame);
    });
  }
}
test("service ports preserve numeric range matching and transport filtering", async () => {
  const f = finder(await readFile("tui/iana-service-port-finder.wasm"));
  assert.match(f.render("6003 tcp"), /6000-6063\/tcp/);
  assert.doesNotMatch(f.render("53 tcp"), /^> .*\/udp/m);
});

test("service port assignment notes remain reachable through detail pages", async () => {
  const f = finder(await readFile("tui/iana-service-port-finder.wasm"));
  const query = "www-http 80 tcp";
  f.render(query, { columns: 48, lines: 12 });
  const total = f.exports.detail_count();
  const page = f.exports.detail_page_size();
  assert.ok(total > page);
  let notes = "";
  for (let offset = 0; offset < total; offset += page) {
    notes += f.render(query, { columns: 48, lines: 12, detail_offset: offset }).split(/DETAILS[^\n]*\n/)[1];
    assert.equal(f.exports.active_count(), 1);
  }
  assert.match(notes, /duplicate of the "http" service/);
  assert.match(notes, /IANA updated: 2026-09-11/);
});
