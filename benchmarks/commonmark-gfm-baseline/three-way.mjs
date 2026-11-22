// Three-way check for a change that is meant to alter output: render random
// inputs with an earlier build and the current one, and ask cmark about every
// input where the two disagree. Reports how many of those inputs the change
// fixed (new matches cmark, old did not), how many it broke, and how many
// neither build gets right, with a few examples of the last two.
// usage: node three-way.mjs <old.wasm> <new.wasm> [count] [seed] [lists|angle|general]
// Compare the CommonMark builds: cmark does not render the GFM extensions.
// Requires cmark 0.31.x on PATH.
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

const [oldPath, newPath, countArg, seedArg, modeArg] = process.argv.slice(2);
if (!oldPath || !newPath) {
  throw new Error("usage: node three-way.mjs <old.wasm> <new.wasm> [count] [seed] [lists|angle|general]");
}
async function load(path) {
  const { instance } = await WebAssembly.instantiate(readFileSync(path));
  const ex = instance.exports;
  return (s) => {
    const bytes = Buffer.from(s);
    new Uint8Array(ex.memory.buffer, ex.input_ptr(), bytes.length).set(bytes);
    const r = ex.render(bytes.length);
    return Buffer.from(new Uint8Array(ex.memory.buffer, Number((r >> 32n) & 0x7fff_ffffn), Number(r & 0xffff_ffffn))).toString("utf8");
  };
}
const base = await load(oldPath);
const neu = await load(newPath);
const count = Number(countArg ?? 100000);
let seed = Number(seedArg ?? 1) >>> 0 || 1;
const mode = modeArg ?? "lists";
function rnd(n) { seed ^= seed << 13; seed >>>= 0; seed ^= seed >>> 17; seed ^= seed << 5; seed >>>= 0; return seed % n; }
const pick = (xs) => xs[rnd(xs.length)];
const sets = {
  lists: ["- ", "-\t", "-", "* ", "*\t", "+ ", "1. ", "1.\t", "2)\t", "10. ", "> ", ">\t", ">", " ", "  ", "   ", "    ", "\t", "\t", " \t", "a", "b c", "foo", "===", "---", "--", "=", "```", "~~~", "# h", "[a]: /u", "<div>", "    code", "`x`", "*e*", "", ""],
  angle: ["<", "<", ">", "a", "b", "/", " ", "=", "\"", "'", "!", "--", "-", "?", "[CDATA[", "]]", "http://x.y", "a@b.c", ":", "\n", "<a", "<!--", "<?", "<!A", "x=1", "href=\"u\"", "`", "*", "_", "div", "br/", "\\"],
};
sets.general = [
  "", " ", "  ", "   ", "    ", "\t", " \t", "> ", ">", "- ", "* ", "+ ", "1. ", "2) ", "10. ", "0. ",
  "# ", "## ", "###### ", "####### ", "#", "---", "***", "* * *", "___", "===", "--", "-",
  "```", "~~~", "````", "``` js", "~~~ py", "<div>", "</div>", "<pre>", "</pre>", "<script>", "</script>",
  "<style>", "</style>", "<textarea>", "</textarea>", "<!-- c -->", "<!--", "-->", "<?php", "?>", "<!DOCTYPE html>",
  "<![CDATA[", "]]>", "<table>", "<TD>", "<Section x=1>", "<details/>", "<h7>", "<h3>", "<H6 >", "<a href=\"x\">",
  "</a>", "<custom-el>", "<PRE>", "<Script\t", "<scriptx>", "<styles>", "<textareas>", "<p>", "<param>", "<menuitem>",
  "<menuitems>", "<Blockquote>", "</UL>", "<s", "<t", "<", "<x/>",
  "[foo]: /url", "[foo]: /url \"title\"", "[Bar]:", "  /u", "[foo]", "[foo][]", "[x][foo]", "![img](a.png)",
  "[link](http://a.b \"t\")", "<http://x.y>", "www.example.com", "http://foo.bar/baz)", "a@b.co",
  "&amp;", "&copy;", "&nbsp;", "&ngE;", "&ClockwiseContourIntegral;", "&AElig;", "&zwnj;", "&zwj;", "&Aacute;",
  "&aacute;", "&notanentity;", "&#35;", "&#x1F600;", "&#0;", "&AMP;", "&amp", "&Afr;", "&zscr;", "&acE;",
  "&ThickSpace;", "&NotNestedGreaterGreater;", "&b.;", "&lt;", "&gt;", "&quot;", "&apos;", "&Tab;", "&NewLine;",
  "*em*", "**strong**", "_u_", "__uu__", "~~del~~", "~x~", "`code`", "``a`b``", "\\*", "\\", "|", "| a | b |",
  "|---|:-:|", "--|--", "a | b", "[ ]", "[x]", "[X] task", "foo", "bar baz", "Ünïcødé", " ", "1", "123456789.",
  "1234567890)", "  - ", "    - ", "      ", "\r",
  // Extended-autolink anchors and local-part edge cases.
  "www.", "www", "https://x.y/z", "ftp://", "://", "@", ".", "_", "+", "x_y@z.w", "a+www.b@c.de", "a._b@c.d",
];
const atoms = sets[mode];
function gen() {
  if (mode === "angle") { let s = ""; const n = 1 + rnd(14); for (let i = 0; i < n; i++) s += pick(atoms); return s + "\n"; }
  if (mode === "general") { const lines = []; const n = 1 + rnd(12); for (let i = 0; i < n; i++) { if (rnd(5) === 0) { lines.push(""); continue; } let s = ""; const k = 1 + rnd(4); for (let j = 0; j < k; j++) s += pick(atoms) + (rnd(3) === 0 ? " " : ""); lines.push(s); } return lines.join("\n") + "\n"; }
  const lines = []; const n = 1 + rnd(8);
  for (let i = 0; i < n; i++) { if (rnd(6) === 0) { lines.push(""); continue; } let s = ""; const k = 1 + rnd(5); for (let j = 0; j < k; j++) s += pick(atoms); lines.push(s); }
  return lines.join("\n") + "\n";
}
let diff = 0, fixed = 0, regressed = 0, bothWrong = 0; const regs = [], bw = [];
for (let i = 0; i < count; i++) {
  const s = gen(); const a = base(s), b = neu(s);
  if (a === b) continue;
  diff++;
  const ref = execFileSync("cmark", ["--unsafe"], { input: s }).toString();
  if (b === ref) fixed++; else if (a === ref) { regressed++; if (regs.length < 6) regs.push([s, a, b]); } else { bothWrong++; if (bw.length < 3) bw.push([s, a, b, ref]); }
}
console.log({ count, diff, fixed, regressed, bothWrong });
for (const [s, a, b] of regs) console.log("REGRESSED", JSON.stringify(s), "\n  base=cmark:", JSON.stringify(a), "\n  new:       ", JSON.stringify(b));
for (const [s, a, b, r] of bw) console.log("BOTHWRONG", JSON.stringify(s), "\n  base:", JSON.stringify(a), "\n  new: ", JSON.stringify(b), "\n  cmrk:", JSON.stringify(r));
