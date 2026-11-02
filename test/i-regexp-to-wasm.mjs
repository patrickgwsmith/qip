import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import test from "node:test";

const execFileAsync = promisify(execFile);
const qip = join(process.cwd(), "qip");
const compilerPath = join(process.cwd(), "text/i-regexp-to-wasm.wasm");
const strictCheckers = [
  "application/wasm/wasm-strict-profile.wasm",
  "application/wasm/wasm-bounded-loops.wasm",
  "application/wasm/wasm-bounded-output.wasm",
].map((path) => join(process.cwd(), path));

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });
const compiler = new WebAssembly.Instance(new WebAssembly.Module(await readFile(compilerPath))).exports;

function callRender(exports, bytes) {
  const cap = (exports.input_utf8_cap ?? exports.input_bytes_cap)();
  assert.ok(bytes.length <= cap);
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), bytes.length).set(bytes);
  const result = BigInt.asUintN(64, exports.render(bytes.length));
  const low = Number(result & 0xffffffffn);
  if (result >> 63n) return { failed: true, detail: low };
  const ptr = Number((result >> 32n) & 0x7fffffffn);
  return { failed: false, bytes: new Uint8Array(exports.memory.buffer, ptr, low).slice() };
}

// Compiles a pattern; returns the module bytes, or { offset, mode } on rejection.
function compile(pattern) {
  const r = callRender(compiler, encoder.encode(pattern));
  if (r.failed) return { offset: r.detail >> 1, mode: r.detail & 1 ? "too_large" : "syntax" };
  return { bytes: r.bytes };
}

function matcher(pattern) {
  const c = compile(pattern);
  assert.ok(c.bytes, `${JSON.stringify(pattern)} should compile, got ${JSON.stringify(c)}`);
  const exports = new WebAssembly.Instance(new WebAssembly.Module(c.bytes)).exports;
  return (text) => {
    const input = encoder.encode(text);
    const r = callRender(exports, input);
    if (r.failed) return { match: false, offset: r.detail };
    assert.deepEqual(r.bytes, input, "a match returns the input unchanged");
    return { match: true };
  };
}

async function checkStrict(bytes) {
  const dir = await mkdtemp(join(tmpdir(), "i-regexp-"));
  const path = join(dir, "matcher.wasm");
  await writeFile(path, bytes);
  await execFileAsync(qip, ["run", "-i", path, "--", ...strictCheckers]);
}

test("generated modules match the whole text and return it unchanged", () => {
  const m = matcher("[a-z]{2,8}(-[a-z0-9]+)*");
  assert.deepEqual(m("en"), { match: true });
  assert.deepEqual(m("en-gb-oed"), { match: true });
  assert.deepEqual(m("en-GB"), { match: false, offset: 3 });
  assert.deepEqual(m("e"), { match: false, offset: 1 });
  assert.deepEqual(m(""), { match: false, offset: 0 });
  assert.deepEqual(m("abcdefghi"), { match: false, offset: 8 });
});

test("rejection offsets point at the first byte of the code point", () => {
  const m = matcher("a\\p{Ll}*b");
  // U+00C9 is uppercase and two bytes; U+1F600 is four bytes.
  assert.deepEqual(m("aéÉb"), { match: false, offset: 3 });
  assert.deepEqual(m("aé\u{1F600}"), { match: false, offset: 3 });
  assert.deepEqual(m("aéé"), { match: false, offset: 5 });
  const four = matcher("\u{1F600}\u{1F601}");
  assert.deepEqual(four("\u{1F600}\u{1F602}"), { match: false, offset: 4 });
});

test("generated modules pass the strict profile, loop and output proofs", async () => {
  // u8 rows, u16 rows with a u8 class map, and u32 rows with a u16 class map.
  for (const pattern of ["", "a", ".*", "[a-z]{2,8}(-[a-z0-9]+)*", "(.{0,5}x){3}", "[^ab]{300}", "\\p{L}+\\P{N}"]) {
    const c = compile(pattern);
    assert.ok(c.bytes, pattern);
    await checkStrict(c.bytes);
  }
});

test("output is deterministic and records the pattern", () => {
  const pattern = "(\\p{L}|[0-9_])+";
  const a = compile(pattern).bytes;
  const b = compile(pattern).bytes;
  assert.deepEqual(a, b);
  const sections = WebAssembly.Module.customSections(new WebAssembly.Module(a), "qip.i-regexp");
  assert.equal(sections.length, 1);
  assert.equal(decoder.decode(sections[0]), pattern);
});

test("the qip CLI runs the compiler and the generated component", async () => {
  const dir = await mkdtemp(join(tmpdir(), "i-regexp-"));
  const patternPath = join(dir, "pattern.txt");
  const modulePath = join(dir, "matcher.wasm");
  const textPath = join(dir, "text.txt");
  await writeFile(patternPath, "\\p{Lu}\\p{Ll}+");
  await execFileAsync(qip, ["run", "-i", patternPath, "-o", modulePath, compilerPath]);
  const outPath = join(dir, "out.txt");
  await writeFile(textPath, "Ωmega");
  await execFileAsync(qip, ["run", "-i", textPath, "-o", outPath, modulePath]);
  assert.equal(await readFile(outPath, "utf8"), "Ωmega");
  await writeFile(textPath, "omega");
  await assert.rejects(execFileAsync(qip, ["run", "-i", textPath, modulePath]), /offset 0/);
});

test("the compiler follows the RFC 9485 grammar", () => {
  const valid = [
    "", "|", "a||b", "()", "(|a)", "a{0}", "a{0,}", "a{2,2}", "a{007}", "$^", "-", ",", "a-b",
    "[-]", "[--]", "[-a]", "[a-]", "[-a-]", "[^-]", "[^^]", "[a^]", "[\\^]", "[\\-a]", "[!-\\-]",
    "[\\p{L}-]", "[\\p{L}\\P{Nd}]", "[.]", "[*+?(){}|]", "\\p{L}", "\\P{Cn}", "\\p{Pi}", "\\p{Pf}",
    "\\.", "\\\\", "\\n\\r\\t", "\\{\\}\\[\\]\\(\\)\\|\\*\\+\\?\\-\\^", "\u0000", "\u{10FFFF}",
  ];
  for (const pattern of valid) assert.ok(compile(pattern).bytes, JSON.stringify(pattern));
  const invalid = [
    ["[^]", 2], ["[]", 1], ["[", 1], ["[a", 2], ["]", 0], ["}", 0], ["{", 0], ["{1}", 0],
    ["a**", 2], ["a*?", 2], ["a+*", 2], ["*", 0], ["?", 0], ["(", 1], [")", 0], ["a)", 1],
    ["a{", 2], ["a{1", 3], ["a{1,", 4], ["a{,1}", 2], ["a{2,1}", 4], ["a{x}", 2],
    ["\\d", 0], ["\\s", 0], ["\\w", 0], ["\\b", 0], ["\\u0041", 0], ["\\", 0], ["\\/", 0],
    ["\\p{Lc}", 3], ["\\p{IsBasicLatin}", 3], ["\\p{Cs}", 3], ["\\p{l}", 3], ["\\pL", 2], ["\\p{L", 4],
    ["[z-a]", 3], ["[a-c-e]", 4], ["[--a]", 2], ["[a--]", 3], ["[a[]", 2], ["[a-\\p{L}]", 3],
    ["[\\d]", 1], ["[[a]]", 1], ["a{100001}", 2],
  ];
  for (const [pattern, offset] of invalid) {
    assert.deepEqual(compile(pattern), { offset, mode: pattern === "a{100001}" ? "too_large" : "syntax" }, JSON.stringify(pattern));
  }
});

test("patterns whose DFA is too large are rejected as too large", () => {
  assert.deepEqual(compile("(a|b)*a(a|b){20}"), { offset: 0, mode: "too_large" });
  assert.equal(compile("((a{100}){100}){100}").mode, "too_large");
  assert.equal(compile("(".repeat(65) + ")".repeat(65)).mode, "too_large");
  assert.ok(compile("(".repeat(64) + ")".repeat(64)).bytes);
  // The compiler recovers after a rejection.
  assert.deepEqual(matcher("ab")("ab"), { match: true });
});

test("Unicode categories agree with the JavaScript engine", () => {
  const names = ["L", "Lu", "Ll", "Lt", "Lm", "Lo", "M", "Mn", "Mc", "Me", "N", "Nd", "Nl", "No",
    "P", "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po", "Z", "Zs", "Zl", "Zp", "S", "Sm", "Sc", "Sk", "So",
    "C", "Cc", "Cf", "Co", "Cn"];
  const samples = [];
  for (let cp = 0; cp < 0x110000; cp += cp < 0x3000 ? 1 : 61) {
    if (cp < 0xd800 || cp > 0xdfff) samples.push(String.fromCodePoint(cp));
  }
  for (const name of names) {
    for (const negate of [false, true]) {
      const escape = `\\${negate ? "P" : "p"}{${name}}`;
      const m = matcher(escape);
      const oracle = new RegExp(`^${escape}$`, "u");
      for (const s of samples) {
        assert.equal(m(s).match, oracle.test(s), `${escape} U+${s.codePointAt(0).toString(16)}`);
      }
    }
  }
});

// Differential test: random I-Regexps and the ECMAScript regexps that
// RFC 9485 section 5.3 maps them to. `^` and `$` are ordinary characters in
// I-Regexp, so the ECMAScript form escapes them too.
function rng(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const literalPool = ["a", "b", "c", "-", ",", "^", "$", "é", "Ω", "٣", " ", "\u{1F600}", "\n", ".", "[", "]", "\\", "*", "{", "|", "\t", "\u0000"];
const categoryPool = ["L", "Lu", "Ll", "Nd", "N", "P", "Pd", "Zs", "S", "So", "C", "Cc", "M"];
const extraText = ["a", "b", "A", "é", "É", "1", "٣", "-", " ", "\n", "\r", "\u{1F600}", "^", "$", ".", "́", " ", "x"];

const IREGEXP_ESCAPE = new Set([..."()*+-.?[\\]^{|}"]);
const JS_ESCAPE = new Set([..."()*+.?[\\]^${|}/"]);

function charIRegexp(c, inClass) {
  if (c === "\n") return "\\n";
  if (c === "\r") return "\\r";
  if (c === "\t") return "\\t";
  if (inClass ? "-[\\]^".includes(c) : IREGEXP_ESCAPE.has(c) && c !== "-" && c !== "^") return "\\" + c;
  return c;
}

function charJs(c, inClass) {
  if (c === "\n") return "\\n";
  if (c === "\r") return "\\r";
  if (c === "\t") return "\\t";
  if (c === "\u0000") return "\\0";
  if (inClass ? "-[\\]^/".includes(c) : JS_ESCAPE.has(c)) return "\\" + c;
  return c;
}

function genNode(r, depth) {
  const k = r();
  if (depth > 3 || k < 0.35) {
    const c = literalPool[Math.floor(r() * literalPool.length)];
    return { kind: "char", c };
  }
  if (k < 0.42) return { kind: "dot" };
  if (k < 0.47) return { kind: "cat", name: categoryPool[Math.floor(r() * categoryPool.length)], negate: r() < 0.3 };
  if (k < 0.62) {
    const items = [];
    const n = 1 + Math.floor(r() * 3);
    for (let i = 0; i < n; i++) {
      const j = r();
      if (j < 0.2) items.push({ kind: "cat", name: categoryPool[Math.floor(r() * categoryPool.length)], negate: r() < 0.3 });
      else if (j < 0.5) {
        const a = literalPool[Math.floor(r() * literalPool.length)].codePointAt(0);
        const b = literalPool[Math.floor(r() * literalPool.length)].codePointAt(0);
        items.push({ kind: "range", lo: String.fromCodePoint(Math.min(a, b)), hi: String.fromCodePoint(Math.max(a, b)) });
      } else items.push({ kind: "char", c: literalPool[Math.floor(r() * literalPool.length)] });
    }
    return { kind: "class", negate: r() < 0.3, items };
  }
  if (k < 0.75) {
    const parts = [];
    const n = Math.floor(r() * 4);
    for (let i = 0; i < n; i++) parts.push(genNode(r, depth + 1));
    return { kind: "seq", parts };
  }
  if (k < 0.85) {
    const parts = [];
    const n = 2 + Math.floor(r() * 2);
    for (let i = 0; i < n; i++) parts.push(genNode(r, depth + 1));
    return { kind: "alt", parts };
  }
  const q = r();
  const min = Math.floor(r() * 3);
  const quant = q < 0.2 ? "*" : q < 0.4 ? "+" : q < 0.6 ? "?" : q < 0.75 ? `{${min}}` : q < 0.88 ? `{${min},}` : `{${min},${min + Math.floor(r() * 3)}}`;
  return { kind: "repeat", child: genNode(r, depth + 1), quant };
}

function render(node, js) {
  const ch = js ? charJs : charIRegexp;
  switch (node.kind) {
    case "char": return ch(node.c, false);
    case "dot": return js ? "[^\\n\\r]" : ".";
    case "cat": return `\\${node.negate ? "P" : "p"}{${node.name}}`;
    case "class": {
      const body = node.items.map((it) =>
        it.kind === "cat" ? render(it, js) : it.kind === "range" ? `${ch(it.lo, true)}-${ch(it.hi, true)}` : ch(it.c, true)).join("");
      return `[${node.negate ? "^" : ""}${body}]`;
    }
    case "seq": return js ? `(?:${node.parts.map((p) => render(p, js)).join("")})` : `(${node.parts.map((p) => render(p, js)).join("")})`;
    case "alt": return js ? `(?:${node.parts.map((p) => render(p, js)).join("|")})` : `(${node.parts.map((p) => render(p, js)).join("|")})`;
    case "repeat": return (js ? `(?:${render(node.child, js)})` : `(${render(node.child, js)})`) + node.quant;
  }
}

// A random string the node likely matches, so the test sees both outcomes.
function sample(node, r) {
  switch (node.kind) {
    case "char": return node.c;
    case "dot":
    case "cat":
    case "class": {
      const re = new RegExp(`^${render(node, true)}$`, "u");
      const pool = [...extraText, ...literalPool];
      for (let i = 0; i < 8; i++) {
        const c = pool[Math.floor(r() * pool.length)];
        if (re.test(c)) return c;
      }
      return pool[Math.floor(r() * pool.length)];
    }
    case "seq": return node.parts.map((p) => sample(p, r)).join("");
    case "alt": return sample(node.parts[Math.floor(r() * node.parts.length)], r);
    case "repeat": {
      const n = Math.floor(r() * 4);
      let s = "";
      for (let i = 0; i < n; i++) s += sample(node.child, r);
      return s;
    }
  }
}

test("random patterns agree with ECMAScript regexps", () => {
  const r = rng(9485);
  let matches = 0;
  let checks = 0;
  for (let i = 0; i < 400; i++) {
    const node = genNode(r, 0);
    const pattern = render(node, false);
    const c = compile(pattern);
    if (c.mode === "too_large") continue;
    assert.ok(c.bytes, `${JSON.stringify(pattern)} should compile, got ${JSON.stringify(c)}`);
    const m = matcher(pattern);
    const oracle = new RegExp(`^(?:${render(node, true)})$`, "u");
    const texts = new Set([""]);
    for (let j = 0; j < 12; j++) texts.add(sample(node, r));
    for (let j = 0; j < 12; j++) {
      let s = "";
      const n = Math.floor(r() * 6);
      for (let k = 0; k < n; k++) s += extraText[Math.floor(r() * extraText.length)];
      texts.add(s);
    }
    for (const text of texts) {
      const expected = oracle.test(text);
      assert.equal(m(text).match, expected, `${JSON.stringify(pattern)} on ${JSON.stringify(text)}`);
      matches += expected ? 1 : 0;
      checks += 1;
    }
  }
  assert.ok(matches > checks / 5, `only ${matches} of ${checks} texts matched`);
});
