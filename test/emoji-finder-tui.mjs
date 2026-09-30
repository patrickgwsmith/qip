import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { ContentComponentHost } from "./lib/content-component-host.mjs";
import { validateTerminalFrame, validateTUIBinary } from "../npm/qiptui/qiptui.mjs";

const wasm = await readFile("tui/emoji-finder.wasm");
const decoder = new TextDecoder("utf-8", { fatal: true });

function finder() {
  const host = new ContentComponentHost(wasm);
  function render(query = "", uniforms = {}) {
    const result = host.run(query, { uniforms });
    assert.equal(result.status, "accepted");
    validateTerminalFrame(result.output);
    return decoder.decode(result.output);
  }
  return { host, render, get exports() { return host.instance.exports; } };
}

test("finder is a plain-text Content transform with no event lifecycle", () => {
  validateTUIBinary(wasm);
  const f = finder();
  assert.match(f.render(), /EMOJI FINDER  3972 \/ 3972/);
  const frame = f.render("woman technologist");
  assert.match(frame, /^> 👩‍💻  woman technologist$/m);
  assert.doesNotMatch(frame.split("ACTIVE EMOJI")[0], /Code points|1F469/);
  assert.match(frame, /Code points\s+1F469 200D 1F4BB/);
  assert.match(f.render("1F469 200D 1F4BB"), /woman technologist/);
  assert.match(f.render("👩"), /woman/);
  assert.equal(f.exports.input_utf8_cap(), 1024);
  for (const name of ["key_event", "begin_update_at", "finish_update"]) assert.equal(f.exports[name], undefined);
  for (const direction of ["input", "output"]) {
    const ptr = f.exports[`${direction}_content_type_ptr`]();
    const size = f.exports[`${direction}_content_type_size`]();
    assert.equal(decoder.decode(new Uint8Array(f.exports.memory.buffer, ptr, size)), "text/plain");
  }
  assert.doesNotMatch(f.render(), /Find:|Enter|Esc|Tab combine/);
});

test("active_index moves through ranked matches and shows details without Enter", () => {
  const f = finder();
  assert.match(f.render("woman technologist"), /ACTIVE EMOJI  👩‍💻  woman technologist/);
  assert.equal(f.exports.active_count(), 6);
  assert.match(f.render("woman technologist", { active_index: 3 }), /ACTIVE EMOJI  👩🏽‍💻  woman technologist: medium skin tone/);
  assert.match(f.render("woman technologist", { active_index: 0xffffffff }), /ACTIVE EMOJI  👩🏿‍💻  woman technologist: dark skin tone/);
  const narrow = f.render("1F600", { active_index: 10 });
  assert.equal(f.exports.active_count(), 1);
  assert.match(narrow, /^> 😀  grinning face$/m);
  assert.match(f.render("no such emoji qzx", { active_index: 10 }), /No matches/);
  assert.equal(f.exports.active_count(), 0);
});

test("reused and fresh instances produce identical output and uniforms reset", () => {
  const f = finder();
  const defaults = f.render("bear");
  f.render("woman technologist", { active_index: 5, columns: 40, lines: 8 });
  assert.equal(f.render("bear"), defaults);
  assert.equal(f.render(""), finder().render(""));
  assert.equal(f.render("  bear  "), defaults);
  assert.equal(f.render("bear", { active_index: 1 }), finder().render("bear", { active_index: 1 }));
});

test("name prefixes rank ahead of substrings and Emoji 18 entries stay last", () => {
  const f = finder();
  const partial = f.render("bea");
  assert.ok(partial.indexOf("🐻  bear\n") < partial.indexOf("person: light skin tone, beard"));
  assert.match(f.render("bear"), /^> 🐻  bear$/m);
  f.render("face");
  const last = f.render("face", { active_index: f.exports.active_count() - 1 });
  assert.match(last, /^> 🫫  cracking face$/m);
  assert.match(last, /Added in Emoji\s+18\.0/);
});

test("exact name words rank before prefixes, including later words and punctuation boundaries", () => {
  const f = finder();
  for (const query of ["poo", "POO", "  poo  "]) {
    const frame = f.render(query);
    assert.match(frame, /^> 💩  pile of poo$/m);
    assert.ok(frame.indexOf("pile of poo\n") < frame.indexOf("poodle\n"));
    assert.ok(f.exports.active_count() >= 2);
    assert.match(f.render(query, { active_index: 1 }), /^> 🐩  poodle$/m);
  }
  assert.match(f.render("pood"), /^> 🐩  poodle$/m);
  assert.match(f.render("man"), /^> 👨  man$/m);
  assert.match(f.render("technologist woman"), /^> 👩‍💻  woman technologist$/m);
  const bear = f.render("bear");
  assert.ok(bear.indexOf("polar bear\n") < bear.indexOf("person: beard\n"));
  assert.match(f.render("beard"), /^> 🧔  person: beard$/m);
});

test("input capacity, control text, and screen dimensions stay bounded", () => {
  const f = finder();
  assert.match(f.render("x".repeat(1024)), /No matches/);
  assert.match(f.render("\x1b]52;c;YQ==\x07"), /No matches/);
  for (const columns of [1, 20, 40, 160]) {
    for (const lines of [1, 8, 11, 24, 60]) {
      const frame = f.render("", { columns, lines, active_index: 3971 });
      assert.ok(frame.trimEnd().split("\n").length <= lines);
      const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });
      assert.ok(frame.trimEnd().split("\n").every((line) => [...segmenter.segment(line)].reduce(
        (width, { segment }) => width + (/\p{Extended_Pictographic}|\p{Regional_Indicator}/u.test(segment) ? 2 : 1), 0,
      ) <= columns));
    }
  }
  assert.throws(() => f.exports.render(f.exports.input_utf8_cap() + 1), WebAssembly.RuntimeError);
});
