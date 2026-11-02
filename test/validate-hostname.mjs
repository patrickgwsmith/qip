import assert from "node:assert/strict";
import { execFile, execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { promisify } from "node:util";
import test from "node:test";

const execFileAsync = promisify(execFile);
const qip = join(process.cwd(), "qip");
const validatorPath = join(process.cwd(), "text/validate-hostname.wasm");
const strictCheckers = [
  "application/wasm/wasm-strict-profile.wasm",
  "application/wasm/wasm-bounded-loops.wasm",
  "application/wasm/wasm-bounded-output.wasm",
].map((path) => join(process.cwd(), path));

// The "Hostname (RFC 1123)" preset on site/regex.md. It has no length limit.
const HOSTNAME_PATTERN =
  "[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*";
const NAME_MAX = 253;

const encoder = new TextEncoder();

function callRender(exports, bytes) {
  assert.ok(bytes.length <= exports.input_utf8_cap());
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), bytes.length).set(bytes);
  const result = BigInt.asUintN(64, exports.render(bytes.length));
  const low = Number(result & 0xffffffffn);
  if (result >> 63n) return { match: false, offset: low };
  const ptr = Number((result >> 32n) & 0x7fffffffn);
  assert.deepEqual(new Uint8Array(exports.memory.buffer, ptr, low), bytes, "a match returns the input unchanged");
  return { match: true };
}

const validator = new WebAssembly.Instance(new WebAssembly.Module(await readFile(validatorPath))).exports;
const check = (text) => callRender(validator, encoder.encode(text));

const compiler = new WebAssembly.Instance(
  new WebAssembly.Module(await readFile(join(process.cwd(), "text/i-regexp-to-wasm.wasm"))),
).exports;
const compiled = (() => {
  const pattern = encoder.encode(HOSTNAME_PATTERN);
  new Uint8Array(compiler.memory.buffer, compiler.input_ptr(), pattern.length).set(pattern);
  const result = BigInt.asUintN(64, compiler.render(pattern.length));
  assert.equal(result >> 63n, 0n, "the regex page hostname pattern compiles");
  const ptr = Number((result >> 32n) & 0x7fffffffn);
  const bytes = new Uint8Array(compiler.memory.buffer, ptr, Number(result & 0xffffffffn)).slice();
  return new WebAssembly.Instance(new WebAssembly.Module(bytes)).exports;
})();
const checkRegex = (text) => callRender(compiled, encoder.encode(text));

// The regex result with the 253-char limit added. Index 252 is the last char a
// name can have, so a dot or hyphen there cannot continue; any char at 253
// cannot either. The earlier of the two rejection points wins.
function expected(text) {
  const r = checkRegex(text);
  let limit = Infinity;
  if (text.length >= NAME_MAX && (text[NAME_MAX - 1] === "." || text[NAME_MAX - 1] === "-")) limit = NAME_MAX - 1;
  else if (text.length > NAME_MAX) limit = NAME_MAX;
  const offset = Math.min(r.match ? Infinity : r.offset, limit);
  return offset === Infinity ? { match: true } : { match: false, offset };
}

test("accepts RFC 1123 host names unchanged", () => {
  for (const name of ["localhost", "example.com", "3com.COM", "a-b.c--d.e", "192.168.0.1", "x", "a".repeat(63)]) {
    assert.deepEqual(check(name), { match: true }, name);
  }
});

test("rejection offsets point at the first byte that cannot continue", () => {
  const cases = [
    ["", 0], ["-a", 0], [".a", 0], ["a..b", 2], ["a-.b", 2], ["a_b", 1], ["café", 3],
    ["example.com.", 12], ["a-", 2], ["a".repeat(64), 63], ["a".repeat(62) + "-a", 62],
  ];
  for (const [text, offset] of cases) assert.deepEqual(check(text), { match: false, offset }, JSON.stringify(text));
});

test("enforces the 253-char name limit and stops reading there", () => {
  const name253 = ("a".repeat(63) + ".").repeat(3) + "a".repeat(61);
  assert.equal(name253.length, 253);
  assert.deepEqual(check(name253), { match: true });
  assert.deepEqual(check(name253 + "a"), { match: false, offset: 253 });
  assert.deepEqual(check(name253.slice(0, 252) + "."), { match: false, offset: 252 });
  // 4 MiB of host name characters still reject at 253.
  assert.deepEqual(check("a.".repeat(2 * 1024 * 1024)), { match: false, offset: 253 });
});

test("agrees with the i-regexp-to-wasm module plus the length limit", () => {
  // Deterministic xorshift so failures reproduce.
  let seed = 0x9e3779b9;
  const rand = (n) => {
    seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5;
    return (seed >>> 0) % n;
  };
  const alphabet = ["a", "Z", "7", "-", ".", "_", "é", " "];
  const weights = [30, 10, 10, 12, 10, 1, 1, 1];
  const total = weights.reduce((a, b) => a + b);
  const pick = () => {
    let r = rand(total);
    for (let i = 0; i < alphabet.length; i++) if ((r -= weights[i]) < 0) return alphabet[i];
  };
  // Labels near the 63-char limit and names near 253 chars exercise both caps.
  const label = () => {
    const len = rand(4) === 0 ? 60 + rand(6) : 1 + rand(8);
    let s = "";
    for (let i = 0; i < len; i++) s += rand(5) === 0 ? pick() : "abc0-"[rand(5)];
    return s;
  };
  let runs = 0;
  for (let n = 0; n < 20000; n++) {
    let text;
    if (n % 2 === 0) {
      text = "";
      const len = rand(40);
      for (let i = 0; i < len; i++) text += pick();
    } else {
      const parts = [];
      const count = 1 + rand(6);
      for (let i = 0; i < count; i++) parts.push(label());
      text = parts.join(".");
    }
    assert.deepEqual(check(text), expected(text), JSON.stringify(text));
    runs++;
  }
  // Valid names that straddle the 253 limit.
  for (let len = 240; len <= 260; len++) {
    for (const tail of ["a", "-", "."]) {
      const text = ("a".repeat(62) + ".").repeat(4).slice(0, len - 1) + tail;
      assert.deepEqual(check(text), expected(text), `length ${len} ending ${tail}`);
      runs++;
    }
  }
  assert.ok(runs > 20000);
});

test("passes the strict profile, loop and output proofs and runs in qip", async () => {
  await execFileAsync(qip, ["run", "-i", validatorPath, "--", ...strictCheckers]);
  assert.equal(execFileSync(qip, ["run", validatorPath], { input: "example.com", encoding: "utf8" }).trimEnd(), "example.com");
  assert.throws(() => execFileSync(qip, ["run", validatorPath], { input: "a-.b", stdio: "pipe" }));
});
