// Differential check: render the same inputs with two builds of a Markdown
// component and report any byte difference in the output.
// usage: node differential.mjs <base.wasm> <new.wasm> [count] [seed] [extra input files...]
// Inputs: each extra file, every HTML5 entity name (plus near misses), and
// `count` random Markdown-like documents built from block and inline atoms.
import { readFileSync } from "node:fs";

const [basePath, newPath, countArg, seedArg, ...extra] = process.argv.slice(2);
if (!basePath || !newPath) {
  throw new Error("usage: node differential.mjs <base.wasm> <new.wasm> [count] [seed] [files...]");
}

async function load(path) {
  const { instance } = await WebAssembly.instantiate(readFileSync(path));
  const ex = instance.exports;
  return (bytes) => {
    new Uint8Array(ex.memory.buffer, ex.input_ptr(), bytes.length).set(bytes);
    const r = ex.render(bytes.length);
    const len = Number(r & 0xffff_ffffn);
    const ptr = Number((r >> 32n) & 0x7fff_ffffn);
    const failed = Number(r >> 63n);
    return failed + ":" + Buffer.from(new Uint8Array(ex.memory.buffer, ptr, len)).toString("latin1");
  };
}
const a = await load(basePath);
const b = await load(newPath);

let seed = Number(seedArg ?? 1) >>> 0 || 1;
function rnd(n) {
  seed ^= seed << 13; seed >>>= 0;
  seed ^= seed >>> 17;
  seed ^= seed << 5; seed >>>= 0;
  return seed % n;
}
const pick = (xs) => xs[rnd(xs.length)];
const atoms = [
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
function genLine() {
  let s = "";
  const n = 1 + rnd(4);
  for (let i = 0; i < n; i++) s += pick(atoms) + (rnd(3) === 0 ? " " : "");
  return s;
}
function gen() {
  const lines = [];
  const n = 1 + rnd(12);
  for (let i = 0; i < n; i++) lines.push(rnd(5) === 0 ? "" : genLine());
  return lines.join(rnd(8) === 0 ? "\r\n" : "\n") + (rnd(2) ? "\n" : "");
}

let checked = 0;
let mismatches = 0;
function check(bytes, label) {
  checked++;
  const x = a(bytes);
  const y = b(bytes);
  if (x === y) return;
  mismatches++;
  if (mismatches <= 5) {
    console.log("MISMATCH", label, JSON.stringify(bytes.toString("utf8")));
    console.log("  base:", JSON.stringify(x));
    console.log("  new: ", JSON.stringify(y));
  }
}

for (const p of extra) check(readFileSync(p), p);

const entities = JSON.parse(readFileSync(new URL("../../tools/html5-entities.json", import.meta.url), "utf8"));
for (const name of Object.keys(entities)) {
  const bare = name.endsWith(";") ? name.slice(0, -1) : name;
  // The name itself, a longer and a shorter near miss, and a case flip.
  const flipped = bare[0] + bare.slice(1, 2).toUpperCase() + bare.slice(2);
  check(Buffer.from(`${name} ${bare}x; ${bare.slice(0, -1)}; ${flipped}; [${name}](/u "${name}")\n`), name);
}

const count = Number(countArg ?? 1000);
for (let i = 0; i < count; i++) check(Buffer.from(gen(), "utf8"), `random#${i}`);
console.log(`${checked} inputs, ${mismatches} mismatches`);
process.exit(mismatches ? 1 : 0);
