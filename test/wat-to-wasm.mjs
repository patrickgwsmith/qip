import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { promisify } from "node:util";
import nodeTest from "node:test";

import { ContentComponentHost } from "./lib/content-component-host.mjs";

const execFileAsync = promisify(execFile);
const root = new URL("../", import.meta.url);
// The Zig module and its Odin port must behave identically, so every test
// runs against both.
const IMPLEMENTATIONS = ["text/wat/wat-to-wasm.wasm", "text/wat/wat-to-wasm-odin.wasm"];
const validator = await readFile(new URL("application/wasm/wasm-validate-core-2.0.wasm", root));
const MODES = ["syntax", "name", "number", "unsupported", "limit"];

function assemble(source, host) {
  return host.run(Buffer.from(source));
}

for (const path of IMPLEMENTATIONS) {
const assembler = await readFile(new URL(path, root));
const newHost = () => new ContentComponentHost(assembler, { label: path });
const test = (name, fn) => nodeTest(`${path}: ${name}`, fn);

function accepted(source) {
  const result = assemble(source, newHost());
  assert.equal(result.status, "accepted", `rejected: ${JSON.stringify(result)}`);
  return Buffer.from(result.output);
}

test("every tracked .wat file assembles to its checked-in .wasm", async () => {
  // The checked-in modules are built with WABT's wat2wasm, so this compares
  // byte for byte against WABT without needing it installed.
  const { stdout } = await execFileAsync("git", ["ls-files", "--", "*.wat"], { cwd: root });
  const files = stdout.split("\n").filter((f) => f && !f.startsWith("site-static/"));
  assert.ok(files.length >= 80, `expected the repo .wat corpus, found ${files.length}`);
  const host = newHost();
  for (const file of files) {
    const source = await readFile(new URL(file, root));
    const expected = await readFile(new URL(file.replace(/\.wat$/, ".wasm"), root));
    const result = assemble(source, host);
    assert.equal(result.status, "accepted", `${file}: ${JSON.stringify(result)}`);
    assert.ok(Buffer.from(result.output).equals(expected), `${file} differs from its .wasm`);
  }
});

test("assembled module validates and runs", async () => {
  const wasm = accepted(`
    (module
      (func $fib (export "fib") (param $n i32) (result i32)
        (if (result i32) (i32.lt_u (local.get $n) (i32.const 2))
          (then (local.get $n))
          (else (i32.add
            (call $fib (i32.sub (local.get $n) (i32.const 1)))
            (call $fib (i32.sub (local.get $n) (i32.const 2))))))))`);
  const checked = new ContentComponentHost(validator, { label: "validate" }).run(wasm);
  assert.equal(checked.status, "accepted");
  const { instance } = await WebAssembly.instantiate(wasm);
  assert.equal(instance.exports.fib(20), 6765);
});

test("output follows WABT encoding choices", () => {
  // Explicit types come first; an inline signature reuses a later explicit type.
  const types = accepted(`(module (func (param i32) (result i32) local.get 0) (type (func (param i32) (result i32))))`);
  assert.deepEqual([...types.subarray(8, 17)], [0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x03]);

  // An empty else clause is dropped.
  const ifElse = accepted(`(module (func (if (i32.const 1) (then) (else))))`);
  assert.ok(ifElse.includes(Buffer.from([0x41, 0x01, 0x04, 0x40, 0x0b, 0x0b])));

  // Active externref segments name table 0 explicitly (flags 6).
  const elem = accepted(`(module (table 1 externref) (elem (i32.const 0) externref (ref.null extern)))`);
  assert.ok(elem.includes(Buffer.from([0x09, 0x0b, 0x01, 0x06, 0x00, 0x41, 0x00, 0x0b, 0x6f, 0x01, 0xd0, 0x6f, 0x0b])));

  // A data count section appears only when memory.init or data.drop does.
  assert.ok(!accepted(`(module (memory 1) (data "x"))`).includes(Buffer.from([0x0c, 0x01, 0x01])));
  assert.ok(accepted(`(module (memory 1) (data "x") (func data.drop 0))`).includes(Buffer.from([0x0c, 0x01, 0x01])));
});

test("float literals round to nearest, ties to even", () => {
  const f64 = (literal) => accepted(`(module (global f64 (f64.const ${literal})))`).subarray(-9, -1).readBigUInt64LE();
  assert.equal(f64("0x1.00000000000008p0"), 0x3ff0000000000000n);
  assert.equal(f64("0x1.00000000000018p0"), 0x3ff0000000000002n);
  // A nonzero digit past 64 mantissa bits breaks the tie upward.
  assert.equal(f64("0x1.0000000000000800000001p0"), 0x3ff0000000000001n);
  assert.equal(f64("-nan:0x4"), 0xfff0000000000004n);
  assert.equal(f64("1e-400"), 0n);
});

test("malformed text is rejected with an offset and failure mode", () => {
  const cases = [
    ["(module (func i32.frob))", 14, "syntax"],
    ["(module (func call $missing))", 19, "name"],
    ["(module (func i32.const 4294967296 drop))", 24, "number"],
    ["(module (func f32.const 1e39 drop))", 24, "number"],
    // Limits are u64 even for 32-bit memories, as in WABT.
    ["(module (memory 0x1_0000_0000_0000_0000))", 16, "number"],
    ["(module (func (type 5) (param i32)))", 20, "name"],
    ["(module (func try))", 14, "unsupported"],
    ["(module (func (local $x i32) (local $x i32)))", 36, "name"],
    ["(module (func) (import \"m\" \"f\" (func)))", 16, "syntax"],
    ['(module (data"a"))', 13, "syntax"],
    ["(module (func (block (param $x i32))))", 28, "syntax"],
    ["(module (type $t (func (param i32))) (func (type $t) (param i64)))", 53, "syntax"],
    ['(module (func (export "\\80")))', 22, "syntax"],
    ["(module (func (if (i32.const 1))))", 31, "syntax"],
    ["(module (func block end $l))", 24, "name"],
    ["(module", 7, "syntax"],
  ];
  const host = newHost();
  for (const [source, offset, mode] of cases) {
    const result = assemble(source, host);
    assert.equal(result.status, "rejected", source);
    assert.deepEqual([result.inputOffset, MODES[result.failureMode]], [offset, mode], source);
  }
  // The same instance still assembles valid text after rejecting.
  assert.equal(assemble("(module (memory 1))", host).status, "accepted");
});

test("comments end at LF, CR or CRLF", () => {
  for (const eol of ["\n", "\r", "\r\n"]) {
    const wasm = accepted(`(module (func (result i32) (i32.const 1) ;; c${eol} (return (i32.const 2))))`);
    assert.ok(wasm.includes(Buffer.from([0x41, 0x02, 0x0f])), JSON.stringify(eol));
  }
});
}

// ---------------------------------------------------------------------------
// The Odin port is checked against the Zig module: the same bytes for accepted
// text, and the same offset and failure mode for rejected text.

const [zigHost, odinHost] = await Promise.all(
  IMPLEMENTATIONS.map(async (path) => new ContentComponentHost(await readFile(new URL(path, root)), { label: path })),
);

function assertSameResult(source, label = source) {
  const shown = label.length > 120 ? `${label.slice(0, 120)}...` : label;
  const zig = assemble(source, zigHost);
  const odin = assemble(source, odinHost);
  assert.equal(odin.status, zig.status, shown);
  if (zig.status === "accepted") {
    assert.ok(Buffer.from(odin.output).equals(Buffer.from(zig.output)), `output differs: ${shown}`);
  } else {
    assert.deepEqual([odin.inputOffset, odin.failureMode], [zig.inputOffset, zig.failureMode], shown);
  }
  return zig;
}

nodeTest("Odin port matches Zig on edge cases", () => {
  const cases = String.raw`
(module)|| ;; nothing
(module $m (; block (; nested ;) ;))|(module (func (i32.add (local.get 0) local.get 1)))
(module (memory 1) (data (i32.const 0) "a\00\t\u{e9}" "\'"))|(module (memory 1) (data (i32.const 0) "\ff\c3"))
(module (func (block)) (import "m" "f" (func)))|(module (memory 1) (func (drop (i32.load align=1 offset=2 (i32.const 0)))))
(module (import "a" "b" (func (param $x i32) (param $x i32))))|(module (func (import "a" "b") (param $x i32) (param $x i32)))
(module (func (param $x i32)) (global i32 (local.get $x)))
(module (data "\u{1_0}"))|(module (data "\u{110000}"))|(module (data "\u{d800}"))|(module (data "\u{10ffff}\u{7ff}\u{800}\u{ffff}\u{10000}\u{0}"))
(module (data "\u{"))|(module (data "\u{}"))|(module (data "\u41"))|(module (data "\4"))|(module (data "\4g"))|(module (data "\q"))
(module (memory 1) (memory 1) (func (memory.copy 1 (i32.const 0) (i32.const 0) (i32.const 0))))
(module (memory 0 0x1_0000_0000))|(module (func (type 42)))|(module (func (block (type 9))))|(module (func (type 5) (param i32)))
(module (func (block (type 9) (result i32) (i32.const 0)) drop))
(module (memory i64 1 2 shared))|(module (memory $m (export "a") (export "b") (import "x" "y") 1))|(module (memory (data "abc" "def")))|(module (memory i64 (data)))
(module (table 1 2 funcref))|(module (table i64 1 externref))|(module (table $t funcref (elem $f $f)) (func $f))
(module (table externref (elem (ref.null extern) (item ref.null extern))))
(module (table funcref (elem (ref.func $f) (item (ref.func 0)) (item ref.func $f))) (func $f))
(module (elem declare func 0) (func))|(module (elem (i32.const 0) $f) (table 1 funcref) (func $f))
(module (table 2 funcref) (table 2 funcref) (elem (table 1) (offset (i32.const 0)) funcref (ref.func 0) (ref.null func)) (func))
(module (elem funcref) (elem func) (elem 1 (i32.const 0) func))|(module (elem $e externref (ref.null extern)))|(module (elem (item ref.func 0)))
(module (data (memory 1) (offset (i32.const 0)) "a") (memory 1) (memory 1))|(module (data 1 (i32.const 0) "a"))|(module (data $d (i32.add (i32.const 1) (global.get 0))))
(module (start 0) (func))|(module (start 0) (start 0) (func))|(module (start $f) (func $f))
(module (global $g (export "g") (mut f64) (f64.const 0x1.8p3)))|(module (global (import "a" "b") (mut i32)))
(module (import "a" "b" (global $g i32)) (export "g" (global $g)))
(module (import "a" "b" (table 1 funcref)) (import "a" "c" (memory 1 2)) (import "a" "d" (func $f (type 0))) (type (func)))
(module (type $t (func (param $a i32) (param $a i32))) (func (type $t) (param i32 i32)))|(module (type (struct)))|(module (rec))|(module (tag))|(module (import "a" "b" (tag)))
(module (func i32.const 1 if else end))|(module (func i32.const 1 if $a nop else $a nop end $a))|(module (func i32.const 1 if $a else $b end))
(module (func (if (then) (else) (nop))))|(module (func (result i32 i32) (block (result i32 i32) (i32.const 1) (i32.const 2))))
(module (func (param i32) (loop $l (param i32) (result i32) br $l)))|(module (func (local i32 i32 i64 i32) (local $x f32) (local.get $x)))
(module (func (select) (select (result i32)) (select (result)) (select (result i32) (result i64 f32))))
(module (table 2 funcref) (type $t (func (param i32))) (func (call_indirect 1 (type $t)) (call_indirect (param i32) (result i64)) (return_call_indirect (type 0))))
(module (memory 1) (memory $m 1) (func (v128.load8_lane 1 0 (i32.const 0)) (v128.store64_lane $m offset=1 align=1 1) (v128.load32_lane 3) (i64.atomic.rmw16.cmpxchg_u $m align=2) (i32.atomic.rmw.xchg offset=4)))
(module (func (v128.const i8x16 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 -1) (v128.const i16x8 0 1 2 3 4 5 6 -32768) (v128.const i64x2 0 -1) (v128.const f32x4 0 1.5 nan inf) (v128.const f64x2 -0 1e-400) (i8x16.shuffle 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)))
(module (func (v128.const i32x4 0 1 2)))|(module (func (v128.const bogus 1)))|(module (func (i8x16.extract_lane_s 256)))|(module (func (ref.null any)))|(module (func (ref.null 0)))
(module (memory 1) (data $d "x") (elem $e func) (table $t 1 funcref) (func (memory.init $d) (memory.init 0 $d) (table.init $t $e) (table.init $e) (table.copy $t 0) (table.copy) (elem.drop $e) (data.drop $d) (memory.fill) (table.grow $t)))
(module (memory 1) (func (i32.load align=3) (i32.load align=0)))|(module (memory 1) (func (i32.load offset=)))|(module (memory 1) (func (i32.load align=0x100000000)))
(module binary "\00asm")|(module quote "x")|(@custom "a")|(module (@name "x"))|(module (func) garbage)|(module) (module)|(func) (func)|(module|)|"x"|$x|(module (func $)))|(module (data"a"))|(module (data "a"x))
(module (func call $missing))|(module (func i32.frob))|(module (func try))|(module (func (br 0x)))|(module (func (i32.const 1_)))|(module (func (i32.const 1__0)))
(module (func (i32.const -0x8000_0000) (i32.const 0xffff_ffff) (i64.const -9223372036854775808) (i64.const 0xffffffffffffffff)))
(module (func (i32.const -2147483649)))|(module (func (i64.const 18446744073709551616)))|(module (func (i64.const -9223372036854775809)))
(module (func (f32.const 1.e)))|(module (func (f32.const .5)))|(module (func (f32.const 0x.8p1)))|(module (func (f32.const 0x1.p)))|(module (func (f32.const nan:0x800000)))|(module (func (f32.const -nan:0x1) (f64.const nan:0x8000000000000) (f64.const -inf) (f64.const 1_0.0_1e1_0)))
(module (func (f64.const 0x1p1024)))|(module (func (f64.const 0x1.fffffffffffff8p1023)))|(module (func (f64.const 0x1.fffffffffffff7p1023) (f64.const 0x1p-1074) (f64.const 0x1p-1075) (f64.const 0x1.8p-1075)))
(module (func (f32.const 0x1p-150) (f32.const 0x1.8p-150) (f32.const 0x1.000001p-149) (f32.const 0x0.0p99999999999999999999) (f32.const 0x1p-99999999999999999999)))|(module (func (f32.const 0x1p99999999999999999999)))
(module (func (f64.const 0x123456789abcdef0123456789p-40) (f64.const 0x8000000000000000p-1140) (f64.const 0x8000000000000001p-1138) (f64.const 0x1p-1138)))
(module (func (f64.const 1e99999999999999)))|(module (func (f64.const 1e-99999999999999) (f64.const 0e99999999999) (f64.const 0.0) (f64.const 000.000e-0)))
(module (func (f64.const 4.9406564584124654e-324) (f64.const 2.4703282292062327e-324) (f64.const 2.4703282292062328e-324) (f64.const 1.7976931348623157e308) (f64.const 1.7976931348623158e308)))
(module (func (f64.const 1.7976931348623159e308)))|(module (func (f32.const 3.4028236e38)))|(module (func (f32.const 3.40282357e38)))|(module (func (f32.const 1e39)))
(module (func (f32.const 3.4028235e38) (f32.const 3.40282356e38) (f32.const 1.401298464324817e-45) (f32.const 7.006492321624085e-46) (f32.const 7.006492321624086e-46) (f32.const 16777217) (f32.const 16777219)))
`.trim().split("\n").flatMap((line) => line.split("|"));
  for (const source of cases) assertSameResult(source);
  assertSameResult('(module (data "a\nb"))');
  assertSameResult('(module (func (export "é✓😀")) (data "é✓😀"))');
});

nodeTest("Odin port matches Zig on decimal floats, and both match JavaScript for f64", () => {
  let seed = 0x5eed;
  const random = (n) => {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    return Math.floor((seed / 4294967296) * n);
  };
  const digits = (n) => Array.from({ length: n }, () => random(10)).join("");
  const literals = [];
  for (let i = 0; i < 4000; i++) {
    switch (i % 5) {
      case 0: literals.push(`${digits(1 + random(20))}.${digits(random(20))}e${random(2) ? "-" : ""}${random(400)}`); break;
      case 1: literals.push(digits(1 + random(40))); break;
      case 2: literals.push(`${random(10)}.${digits(random(30))}e${random(90) - 45}`); break;
      case 3: literals.push(`0.${"0".repeat(random(350))}${digits(1 + random(25))}`); break;
      default: literals.push(`${digits(1 + random(8))}${"0".repeat(random(320))}`);
    }
  }
  // Halfway points between adjacent f32 values need every digit to round.
  const f32 = new Float32Array(2);
  const bits = new Uint32Array(f32.buffer);
  for (let i = 0; i < 1000; i++) {
    bits[0] = random(0x7f7fffff);
    bits[1] = bits[0] + 1;
    literals.push(((f32[0] + f32[1]) / 2).toPrecision(60).replace("+", ""));
  }
  // The longest literals: FLOAT_TEXT_CAP is 4096 characters.
  const long = (n) => Array.from({ length: n }, (_, i) => (i * 7 + 3) % 10).join("");
  literals.push(long(4096), `0.${long(4094)}`, `${long(4000)}e-3990`, `${long(4000)}e-4320`);
  literals.push(`9007199254740993.${"0".repeat(3000)}1`, `0.${"0".repeat(323)}5${"0".repeat(3000)}1`, `1${"0".repeat(308)}`);

  for (const literal of literals) {
    assertSameResult(`(global f32 (f32.const ${literal}))`);
    const result = assertSameResult(`(global f64 (f64.const ${literal}))`);
    const expected = Number(literal);
    if (Number.isFinite(expected)) {
      assert.equal(result.status, "accepted", literal);
      assert.equal(Buffer.from(result.output).subarray(-9, -1).readDoubleLE(), expected, literal);
    } else {
      assert.equal(result.status, "rejected", literal);
    }
  }
  // One character past the cap is a limit failure in both.
  assert.equal(MODES[assertSameResult(`(global f64 (f64.const ${long(4097)}))`).failureMode], "limit");
});

nodeTest("Odin port matches Zig at the capacity limits", () => {
  const big = [
    ["deep flat blocks", `(module (func ${"block ".repeat(20000)}${"end ".repeat(20000)}))`, "accepted"],
    ["deep folded blocks", `(module (func ${"(block ".repeat(100000)}${")".repeat(100000)}))`, "accepted"],
    ["unclosed folded instructions", `(module (func ${"(br ".repeat(260000)}0`, "rejected"],
    ["65536 functions", `(module ${"(func)".repeat(65536)})`, "accepted"],
    ["65537 functions", `(module ${"(func)".repeat(65537)})`, "rejected"],
    ["65537 types", `(module ${"(type (func))".repeat(65537)})`, "rejected"],
    ["too many names", `(module ${Array.from({ length: 66000 }, (_, i) => `(func $${i.toString(36)})`).join("")})`, "rejected"],
    ["many globals", `(module ${Array.from({ length: 25000 }, (_, i) => `(global $g${i} i32 (i32.const ${i}))`).join("")})`, "accepted"],
    ["many signatures", `(module ${Array.from({ length: 20000 }, (_, i) => `(type (func (param ${["i32", "i64", "f32", "f64"][i % 4]} ${"i32 ".repeat(i % 11)})))`).join("")})`, "accepted"],
    ["many named locals", `(module (func ${Array.from({ length: 50000 }, (_, i) => `(local $l${i} i32)`).join("")}))`, "accepted"],
    ["many unnamed locals", `(module (func (local ${"i32 ".repeat(200000)})))`, "accepted"],
    ["large escaped data", `(module (memory 1) (data "${"\\00".repeat(340000)}"))`, "accepted"],
    ["large raw data", `(module (memory 1) (data "${"a".repeat(1000000)}"))`, "accepted"],
    ["large function", `(module (func ${"i32.const 0 drop ".repeat(60000)}))`, "accepted"],
  ];
  for (const [label, source, status] of big) {
    assert.ok(source.length <= 1 << 20, label);
    assert.equal(assertSameResult(source, label).status, status, label);
  }
  // Names from earlier inputs must not leak into later ones.
  for (let i = 0; i < 300; i++) assertSameResult(`(module (func $f${i} (param $p${i} i32) (call $f${i - 1})))`);
});
