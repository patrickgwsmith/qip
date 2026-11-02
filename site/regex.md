<title>Regular expression validators</title>

# Regular expression validators

Type an [RFC 9485 I-Regexp](https://www.rfc-editor.org/rfc/rfc9485) pattern
and get a WebAssembly validator for it. The validator accepts text unchanged
when the pattern matches all of it. Otherwise it reports the offset where
matching stopped. Everything runs in this page with
[`i-regexp-to-wasm.wasm`](/text/i-regexp-to-wasm.wasm).

<style>
.regex-tool { display: grid; gap: 0.75rem; margin: 1rem 0 1.5rem; }
.regex-tool label { display: grid; gap: 0.25rem; font-weight: 600; }
.regex-tool input, .regex-tool textarea, .regex-tool select { font: inherit; font-family: var(--font-mono, ui-monospace, monospace); font-weight: 400; padding: 0.4rem 0.5rem; }
.regex-tool textarea { min-height: 4.5rem; resize: vertical; }
.regex-row { display: flex; flex-wrap: wrap; gap: 0.5rem 1.25rem; align-items: center; }
.regex-verdict { font-family: var(--font-mono, ui-monospace, monospace); white-space: pre-wrap; overflow-wrap: anywhere; }
.regex-verdict mark { background: #ffd6d6; color: #8a0000; outline: 1px solid #c00; }
.regex-ok { color: #11632b; font-weight: 600; }
.regex-bad { color: #a40000; font-weight: 600; }
.regex-bench-controls { display: flex; flex-wrap: wrap; gap: 0.75rem 1.25rem; align-items: center; margin: 1rem 0; }
.regex-table { width: 100%; margin: 1.5rem 0; font-variant-numeric: tabular-nums; }
.regex-table caption { text-align: left; font-weight: 600; padding-bottom: 0.5rem; }
.regex-table td:not(:first-child), .regex-table th:not(:first-child) { text-align: right; }
td code { overflow-wrap: anywhere; }
</style>

<div class="regex-tool">
  <label>Start from a ready-made pattern
    <select id="regex-preset"></select>
  </label>
  <label>I-Regexp pattern
    <input id="regex-pattern" type="text" spellcheck="false" autocomplete="off" aria-describedby="regex-compile-status">
  </label>
  <output id="regex-compile-status" class="regex-row" aria-live="polite">Loading the compiler…</output>
  <label>Text to check
    <textarea id="regex-text" spellcheck="false" aria-describedby="regex-verdict"></textarea>
  </label>
  <output id="regex-verdict" class="regex-verdict" aria-live="polite"></output>
</div>

The pattern must match the whole text, so you do not write `^` or `$` anchors.
In I-Regexp, `^` and `$` are ordinary characters. A dot matches any character
except `\n` and `\r`. I-Regexp has no capture groups, lookaround,
backreferences, lazy quantifiers or flags, and it has no shorthand classes
such as `\d`. Write `[0-9]` instead.

## Ready-made patterns

These patterns check the shape of common identifiers. Pick one in the menu
above to try it, then download the validator. Sizes are for the generated
`.wasm` module.

<table id="regex-patterns">
<thead><tr><th scope="col">Pattern for</th><th scope="col">I-Regexp</th><th scope="col">Module size</th><th scope="col">Does not check</th></tr></thead>
<tbody>
<tr><td>UUID</td><td><code>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}</code></td><td>1.2 KB</td><td>Version and variant bits</td></tr>
<tr><td>Semantic version 2.0.0</td><td><code>(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)(\.(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*))*)?(\+[0-9a-zA-Z-]+(\.[0-9a-zA-Z-]+)*)?</code></td><td>1.3 KB</td><td>—</td></tr>
<tr><td>URL slug</td><td><code>[a-z0-9]+(-[a-z0-9]+)*</code></td><td>1.0 KB</td><td>Length</td></tr>
<tr><td>Hex color</td><td><code>#([0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})</code></td><td>1.1 KB</td><td>—</td></tr>
<tr><td>ISO 8601 calendar date</td><td><code>[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])</code></td><td>1.1 KB</td><td>Days per month, so <code>2025-02-31</code> passes</td></tr>
<tr><td>IPv4 address</td><td><code>((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])</code></td><td>1.3 KB</td><td>—</td></tr>
<tr><td>Hostname (RFC 1123)</td><td><code>[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*</code></td><td>2.1 KB</td><td>253-character total length</td></tr>
<tr><td>Email address (HTML <code>type=email</code>)</td><td><code>[A-Za-z0-9.!#$%&amp;'*+/=?^_`{|}~-]+@[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*</code></td><td>2.6 KB</td><td>Whether the mailbox exists</td></tr>
<tr><td>Kubernetes label name (DNS-1123 label)</td><td><code>[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?</code></td><td>1.8 KB</td><td>—</td></tr>
<tr><td>Kubernetes resource name (DNS-1123 subdomain)</td><td><code>[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*</code></td><td>1.0 KB</td><td>253-character total length</td></tr>
<tr><td>Environment variable name</td><td><code>[A-Za-z_][A-Za-z0-9_]*</code></td><td>1.0 KB</td><td>—</td></tr>
<tr><td>Git object ID (SHA-1 or SHA-256)</td><td><code>[0-9a-f]{40}([0-9a-f]{24})?</code></td><td>1.1 KB</td><td>That the object exists</td></tr>
<tr><td>Docker image tag</td><td><code>[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}</code></td><td>1.8 KB</td><td>—</td></tr>
<tr><td>Unicode username</td><td><code>\p{L}(\p{L}|\p{Nd}|[_.-])*</code></td><td>147 KB</td><td>Length, confusable characters</td></tr>
</tbody>
</table>

The HTML email and Kubernetes patterns are the ones those specifications
publish. The HTML pattern accepts `a@b` and rejects quoted local parts and
internationalized domain names, as browsers do.

The Unicode username module is more than 100 times the size of the others.
The generated table works on UTF-8 bytes, so it needs states for the partly
read bytes of every letter and digit in Unicode 17. Use `\p{..}` only when you
need it.

## Speed compared with the browser's RegExp

The benchmark checks the same text with the generated validator and with the
browser's built-in `RegExp`. Each I-Regexp becomes `new RegExp("^(?:…)$", "u")`
with the [RFC 9485 §5.3](https://www.rfc-editor.org/rfc/rfc9485#section-5.3)
mapping. Before it times anything, the page confirms that both engines agree
on every sample.

It has three parts:

- **Short strings** are form-field values: each call checks one value from the
  ready-made patterns' samples. "String in" includes copying the JavaScript
  string into WebAssembly memory as UTF-8 with `TextEncoder.encodeInto`.
  "Bytes in" starts from UTF-8 bytes, such as a request body, and copies them
  in with `Uint8Array.set`.
- **Long text** checks 1 MiB inputs and reports megabytes per second of UTF-8.
- **Backtracking** checks `([a-z0-9]+-?)*[a-z0-9]` against `aaa…a!` of
  growing length. A backtracking engine tries each way of splitting the `a`s
  between the two loops before it fails, so its time doubles with about every
  extra character. The generated validator reads each byte once.

### Recorded results

<p id="regex-recorded-note">One run in headless Chrome 156 on an Apple M5. Each value is the median of five rounds. In a second run, short-string and long-text values moved by up to 17%, and the order of the columns did not change.</p>

<div id="regex-recorded"></div>

### Run the benchmark

The benchmark takes about 20 seconds. The backtracking part runs `RegExp` in
a worker and stops it after 2 seconds per input.

<div class="regex-bench-controls">
  <button id="regex-bench-run" type="button" disabled>Run benchmark</button>
  <output id="regex-bench-status" aria-live="polite">Loading the compiler…</output>
</div>

<div id="regex-bench-results"></div>

### What the numbers show

In the recorded Chrome run, the input format decides most of the result:

- **From a JavaScript string, `RegExp` is faster.** Copying the string into
  WebAssembly memory with `encodeInto` costs about 55 ns per call. That is
  more than a whole short match takes in either engine. If you validate form
  fields in a browser with trusted patterns, use `RegExp`.
- **From UTF-8 bytes, the validator is level or faster.** A call costs 13 to
  25 ns. That includes the JavaScript-to-Wasm call and the `BigInt` for the
  64-bit result. `RegExp` is level on simple patterns and faster on the
  environment-variable name. It is 1.5 to 2 times slower on patterns with
  counted repeats, such as the UUID's `{8}`, the hex color and the Git object
  ID.
- **On long text the validator does one table lookup and one branch per
  byte**, at about 3 GB/s for ASCII patterns. `RegExp` is level on lowercase
  words and 1.6 times slower on Kubernetes names. It is 4.5 times slower on
  Base64, where a counted group sits inside a loop, and 4 times slower on
  Unicode categories. From a JavaScript string the
  validator spends about half of its time on the UTF-8 copy.

Backtracking is the largest difference. A `RegExp` that rejects a short
string in microseconds takes more than a second on 29 characters, and each
extra character doubles the time. In the main thread, that call freezes the
page (a ReDoS). The generated validator has no slow input, because it reads
every byte at most once, whatever the pattern. So you can compile patterns
that users or configuration files supply.

Other browsers have different regular expression engines, so run the
benchmark in the browsers you support.

## Use a validator outside the browser

Compile a pattern with the `qip` CLI, then run the validator on text. The
second command prints `en-gb`, because it matches. The third fails and reports
input offset 3, where `G` breaks the pattern.

```sh
printf '[a-z]{2,8}(-[a-z0-9]+)*' | qip run -o lang.wasm text/i-regexp-to-wasm.wasm
printf 'en-gb' | qip run lang.wasm
printf 'en-GB' | qip run lang.wasm
```

The same `lang.wasm` runs in any QIP host: the browser, Node, Go with
wazero, Rust with qipx, and Swift. Each host gets the same accept and reject
results, including offsets. A JavaScript `RegExp`, a Go `regexp` and a
Python `re` can disagree on the same pattern. RFC 9485 exists to give one
pattern one meaning.

Each validator also keeps its source pattern in a custom section named
`qip.i-regexp`, so you can see which pattern a `.wasm` file checks.

## When not to use this

- **To search, extract, or replace text.** A validator answers whether the
  whole text matches. It does not find matches inside text or return groups.
- **For short trusted patterns in JavaScript.** `RegExp` is faster per call
  and needs no extra file.
- **For patterns that need lookaround or backreferences.** I-Regexp leaves
  them out on purpose, because they need backtracking.
- **For large counted repeats.** The compiler rejects patterns whose table
  needs more than 30,000 states or 4 MiB, for example `(a|b)*a(a|b){20}`. It
  reports the failure as "too large" and gives the offset.
- **For checks that are not about shape.** A pattern cannot check that a date
  exists, that a checksum is correct, or that a hostname is at most 253
  characters long. Combine the validator with a component made for that
  check, such as [`luhn.wasm`](/text/luhn.wasm) for card numbers.

See [text components](/text) for other validators, such as
[BCP 47 language tags](/text/bcp47-must-be-well-formed.wasm).

<script type="module">
const encoder = new TextEncoder();
const decoder = new TextDecoder();

// samples: values that should match, then values that should not.
const PRESETS = [
  { id: "uuid", name: "UUID", pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
    good: ["123e4567-e89b-12d3-a456-426614174000", "6F9619FF-8B86-D011-B42D-00C04FC964FF"], bad: ["123e4567-e89b-12d3-a456-42661417400Z", "123e4567e89b12d3a456426614174000"] },
  { id: "semver", name: "Semantic version", pattern: "(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)(\\.(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*))*)?(\\+[0-9a-zA-Z-]+(\\.[0-9a-zA-Z-]+)*)?",
    good: ["1.2.3", "10.20.30-rc.1+build.5"], bad: ["01.2.3", "1.2"] },
  { id: "slug", name: "URL slug", pattern: "[a-z0-9]+(-[a-z0-9]+)*",
    good: ["hello-world", "2026-release-notes"], bad: ["Hello-World", "trailing-"] },
  { id: "hex-color", name: "Hex color", pattern: "#([0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})",
    good: ["#0af", "#11223380"], bad: ["#12345", "0af"] },
  { id: "date", name: "ISO 8601 calendar date", pattern: "[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])",
    good: ["2026-11-02", "1999-12-31"], bad: ["2026-13-01", "2026-1-2"] },
  { id: "ipv4", name: "IPv4 address", pattern: "((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])",
    good: ["192.168.1.254", "10.0.0.1"], bad: ["256.1.1.1", "01.2.3.4"] },
  { id: "hostname", name: "Hostname (RFC 1123)", pattern: "[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*",
    good: ["qip.dev", "api-2.eu-west-1.example.com"], bad: ["-bad.example", "a..b"] },
  { id: "email", name: "Email address (HTML type=email)", pattern: "[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*",
    good: ["ada@example.com", "first.last+tag@mail.example.co.uk"], bad: ["ada@", "ada@-example.com"] },
  { id: "k8s-label", name: "Kubernetes label name", pattern: "[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?",
    good: ["web", "api-gateway-v2"], bad: ["Web", "api-"] },
  { id: "k8s-name", name: "Kubernetes resource name", pattern: "[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*",
    good: ["my-app.v1", "cert-manager.io"], bad: ["My-App", "app..v1"] },
  { id: "env-name", name: "Environment variable name", pattern: "[A-Za-z_][A-Za-z0-9_]*",
    good: ["DATABASE_URL", "_private"], bad: ["9LIVES", "MY-VAR"] },
  { id: "git-oid", name: "Git object ID", pattern: "[0-9a-f]{40}([0-9a-f]{24})?",
    good: ["89111a16d1b7c0a3e4f5a6b7c8d9e0f1a2b3c4d5"], bad: ["89111a16", "89111A16D1B7C0A3E4F5A6B7C8D9E0F1A2B3C4D5"] },
  { id: "docker-tag", name: "Docker image tag", pattern: "[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}",
    good: ["latest", "1.27.3-alpine"], bad: [".hidden", "v1:2"] },
  { id: "unicode-username", name: "Unicode username", pattern: "\\p{L}(\\p{L}|\\p{Nd}|[_.-])*",
    good: ["Zoë_93", "名前"], bad: ["9lives", "space name"] },
];

const LONG_TEXT = [
  { name: "Lowercase words", pattern: "[a-z ]*", unit: "lorem ipsum dolor sit amet " },
  { name: "Base64", pattern: "([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?", unit: "UVVJUCBjb21wb25lbnRz" },
  { name: "Kubernetes resource name", pattern: "[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*", unit: "service-a.namespace-b." , tail: "z" },
  { name: "Unicode letters and spaces", pattern: "(\\p{L}|\\p{Zs})*", unit: "Grüße aus Zürich 東京 Αθήνα " },
];

const BACKTRACK = { pattern: "([a-z0-9]+-?)*[a-z0-9]", char: "a", tail: "!", lengths: [16, 18, 20, 22, 24, 26, 28, 30], budgetMs: 2000 };

// Recorded in headless Chrome 156 on an Apple M5; see the note above the tables.
const RECORDED = {
  short: [
    { name: "UUID", regexp: 48.7, string: 88.9, bytes: 23.1 },
    { name: "Semantic version", regexp: 18.8, string: 71.3, bytes: 14.9 },
    { name: "URL slug", regexp: 15.5, string: 71.6, bytes: 14.3 },
    { name: "Hex color", regexp: 28.6, string: 68.6, bytes: 13.3 },
    { name: "ISO 8601 calendar date", regexp: 15.8, string: 74.2, bytes: 14.1 },
    { name: "IPv4 address", regexp: 14.7, string: 71.4, bytes: 13.4 },
    { name: "Hostname (RFC 1123)", regexp: 24.6, string: 73.0, bytes: 16.1 },
    { name: "Email address (HTML type=email)", regexp: 26.0, string: 77.1, bytes: 19.2 },
    { name: "Kubernetes label name", regexp: 24.5, string: 68.7, bytes: 13.5 },
    { name: "Kubernetes resource name", regexp: 14.8, string: 69.7, bytes: 15.4 },
    { name: "Environment variable name", regexp: 10.0, string: 72.9, bytes: 14.2 },
    { name: "Git object ID", regexp: 27.0, string: 85.6, bytes: 20.7 },
    { name: "Docker image tag", regexp: 15.2, string: 69.1, bytes: 16.2 },
    { name: "Unicode username", regexp: 19.3, string: 67.1, bytes: 16.4 },
  ],
  long: [
    { name: "Lowercase words", regexp: 3033, string: 1618, bytes: 3288 },
    { name: "Base64", regexp: 733, string: 1687, bytes: 3282 },
    { name: "Kubernetes resource name", regexp: 1813, string: 1514, bytes: 2950 },
    { name: "Unicode letters and spaces", regexp: 169, string: 463, bytes: 689 },
  ],
  backtrack: [
    { chars: 17, regexp: { ms: 0.3 }, wasm: 0.000072 },
    { chars: 19, regexp: { ms: 2.2 }, wasm: 0.000074 },
    { chars: 21, regexp: { ms: 4.6 }, wasm: 0.000075 },
    { chars: 23, regexp: { ms: 17.7 }, wasm: 0.000077 },
    { chars: 25, regexp: { ms: 67 }, wasm: 0.000080 },
    { chars: 27, regexp: { ms: 270 }, wasm: 0.000079 },
    { chars: 29, regexp: { ms: 1069 }, wasm: 0.000092 },
    { chars: 31, regexp: { timedOut: true }, wasm: 0.000083 },
  ],
};

const compiler = (await WebAssembly.instantiateStreaming(fetch("/text/i-regexp-to-wasm.wasm"))).instance.exports;

function callRender(exports, bytes) {
  const cap = exports.input_utf8_cap() >>> 0;
  if (bytes.length > cap) throw Error(`Input is ${bytes.length} bytes; the limit is ${cap}.`);
  new Uint8Array(exports.memory.buffer, exports.input_ptr() >>> 0, bytes.length).set(bytes);
  const result = BigInt.asUintN(64, exports.render(bytes.length));
  const low = Number(result & 0xffffffffn);
  if (result >> 63n) return { failed: true, detail: low };
  const ptr = Number((result >> 32n) & 0x7fffffffn);
  return { failed: false, bytes: new Uint8Array(exports.memory.buffer, ptr, low) };
}

// Returns { bytes } or { offset, mode } where mode is "syntax" or "too large".
function compile(pattern) {
  const r = callRender(compiler, encoder.encode(pattern));
  if (r.failed) return { offset: r.detail >> 1, mode: r.detail & 1 ? "too large" : "syntax" };
  return { bytes: r.bytes.slice() };
}

function validator(bytes) {
  const exports = new WebAssembly.Instance(new WebAssembly.Module(bytes), {}).exports;
  const ptr = exports.input_ptr() >>> 0;
  const cap = exports.input_utf8_cap() >>> 0;
  const input = new Uint8Array(exports.memory.buffer, ptr, cap);
  const render = exports.render;
  return {
    // Hot paths: true when the whole text matches.
    testString(text) {
      const { read, written } = encoder.encodeInto(text, input);
      return read === text.length && render(written) >= 0n;
    },
    testBytes(bytes) {
      if (bytes.length > cap) return false;
      input.set(bytes);
      return render(bytes.length) >= 0n;
    },
    // Slow path for the tool: the rejection offset in bytes, or -1 on a match.
    rejectOffset(bytes) {
      const r = callRender(exports, bytes);
      return r.failed ? r.detail : -1;
    },
  };
}

// RFC 9485 §5.3: wrap in ^(?:…)$, turn "." into [^\n\r], and escape the
// characters that are literals in I-Regexp but syntax in JavaScript.
function toJsRegExp(pattern) {
  let out = "";
  let inClass = false;
  for (let i = 0; i < pattern.length; i++) {
    const c = pattern[i];
    if (c === "\\") {
      const next = pattern[i + 1];
      if (next === "p" || next === "P") {
        const end = pattern.indexOf("}", i);
        out += pattern.slice(i, end + 1);
        i = end;
      } else {
        out += next === "-" && !inClass ? "-" : c + next;
        i++;
      }
    } else if (inClass) {
      if (c === "]") inClass = false;
      out += c;
    } else if (c === "[") {
      inClass = true;
      out += c;
    } else if (c === ".") {
      out += "[^\\n\\r]";
    } else if (c === "^" || c === "$") {
      out += "\\" + c;
    } else {
      out += c;
    }
  }
  return new RegExp(`^(?:${out})$`, "u");
}

function formatBytes(n) {
  return n < 1000 ? `${n} B` : `${(n / 1000).toFixed(n < 10000 ? 2 : 1)} KB`;
}

function escapeHTML(text) {
  return text.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
}

// Tool

const presetSelect = document.querySelector("#regex-preset");
const patternInput = document.querySelector("#regex-pattern");
const textInput = document.querySelector("#regex-text");
const compileStatus = document.querySelector("#regex-compile-status");
const verdict = document.querySelector("#regex-verdict");

presetSelect.append(new Option("Custom pattern", ""));
for (const preset of PRESETS) presetSelect.append(new Option(preset.name, preset.id));

let current = null;
let downloadURL = null;

function compilePattern() {
  const pattern = patternInput.value;
  current = null;
  if (downloadURL) URL.revokeObjectURL(downloadURL);
  downloadURL = null;
  const result = compile(pattern);
  if (!result.bytes) {
    const at = decoder.decode(encoder.encode(pattern).subarray(0, result.offset)).length;
    compileStatus.innerHTML = result.mode === "syntax"
      ? `<span class="regex-bad">Syntax error at character ${at + 1}.</span>`
      : `<span class="regex-bad">The pattern is valid but too large to compile (offset ${result.offset}).</span>`;
    checkText();
    return;
  }
  let js = null;
  try { js = toJsRegExp(pattern); } catch {}
  current = { validator: validator(result.bytes), js };
  downloadURL = URL.createObjectURL(new Blob([result.bytes], { type: "application/wasm" }));
  const name = (presetSelect.value || "i-regexp") + ".wasm";
  compileStatus.innerHTML = `<span>Compiled to ${formatBytes(result.bytes.length)}.</span> <a href="${downloadURL}" download="${name}">Download ${name}</a>`;
  checkText();
}

function checkText() {
  if (!current) {
    verdict.textContent = "";
    return;
  }
  const bytes = encoder.encode(textInput.value);
  let offset;
  try {
    offset = current.validator.rejectOffset(bytes);
  } catch (error) {
    verdict.innerHTML = `<span class="regex-bad">${escapeHTML(error.message)}</span>`;
    return;
  }
  const jsNote = current.js
    ? ` RegExp: ${current.js.test(textInput.value) ? "matches" : "no match"}.`
    : " This browser's RegExp cannot express the pattern.";
  if (offset < 0) {
    verdict.innerHTML = `<span class="regex-ok">Matches.</span>${escapeHTML(jsNote)}`;
    return;
  }
  const before = decoder.decode(bytes.subarray(0, offset));
  const rest = decoder.decode(bytes.subarray(offset));
  const stopChar = [...rest][0] ?? "";
  const where = offset === bytes.length ? "The text ended before the pattern did." : `Matching stopped at character ${before.length + 1} (byte offset ${offset}).`;
  verdict.innerHTML = `<span class="regex-bad">No match.</span> ${escapeHTML(where)}${escapeHTML(jsNote)}\n` +
    `${escapeHTML(before)}<mark>${stopChar ? escapeHTML(stopChar) : "&nbsp;"}</mark>${escapeHTML(rest.slice(stopChar.length))}`;
}

function choosePreset() {
  const preset = PRESETS.find((p) => p.id === presetSelect.value);
  if (!preset) return;
  patternInput.value = preset.pattern;
  textInput.value = preset.good[0];
  compilePattern();
}

presetSelect.addEventListener("change", choosePreset);
patternInput.addEventListener("input", () => {
  presetSelect.value = PRESETS.find((p) => p.pattern === patternInput.value)?.id ?? "";
  compilePattern();
});
textInput.addEventListener("input", checkText);
presetSelect.value = "semver";
choosePreset();

// Benchmark

const runButton = document.querySelector("#regex-bench-run");
const benchStatus = document.querySelector("#regex-bench-status");
const benchResults = document.querySelector("#regex-bench-results");

const median = (values) => values.slice().sort((a, b) => a - b)[values.length >> 1];
const nextFrame = () => new Promise((resolve) => setTimeout(resolve, 0));

// Runs fn(count) with a count that takes at least targetMs, five times, and
// returns the median milliseconds per call.
async function timeCalls(fn, targetMs = 40) {
  let count = 64;
  for (;;) {
    const started = performance.now();
    fn(count);
    if (performance.now() - started >= targetMs) break;
    count *= 2;
  }
  const rounds = [];
  for (let round = 0; round < 5; round++) {
    const started = performance.now();
    fn(count);
    rounds.push((performance.now() - started) / count);
    await nextFrame();
  }
  return median(rounds);
}

let sink = 0;

async function benchShort(progress) {
  const rows = [];
  for (const preset of PRESETS) {
    progress(`Short strings: ${preset.name}`);
    const v = validator(compile(preset.pattern).bytes);
    const re = toJsRegExp(preset.pattern);
    const samples = [...preset.good, ...preset.bad];
    const sampleBytes = samples.map((s) => encoder.encode(s));
    for (const [i, s] of samples.entries()) {
      const expected = i < preset.good.length;
      if (v.testString(s) !== expected || v.testBytes(sampleBytes[i]) !== expected || re.test(s) !== expected) {
        throw Error(`${preset.name}: the engines disagree on ${JSON.stringify(s)}.`);
      }
    }
    const n = samples.length;
    const regexp = await timeCalls((count) => { for (let i = 0; i < count; i++) if (re.test(samples[i % n])) sink++; });
    const string = await timeCalls((count) => { for (let i = 0; i < count; i++) if (v.testString(samples[i % n])) sink++; });
    const bytes = await timeCalls((count) => { for (let i = 0; i < count; i++) if (v.testBytes(sampleBytes[i % n])) sink++; });
    rows.push({ name: preset.name, regexp: regexp * 1e6, string: string * 1e6, bytes: bytes * 1e6 });
  }
  return rows;
}

async function benchLong(progress) {
  const rows = [];
  for (const test of LONG_TEXT) {
    progress(`Long text: ${test.name}`);
    const unitBytes = encoder.encode(test.unit).length;
    const text = test.unit.repeat(Math.floor((1 << 20) / unitBytes)) + (test.tail ?? "");
    const bytes = encoder.encode(text);
    const v = validator(compile(test.pattern).bytes);
    const re = toJsRegExp(test.pattern);
    if (!v.testString(text) || !v.testBytes(bytes) || !re.test(text)) throw Error(`${test.name}: an engine rejected the long text.`);
    const mbps = (ms) => bytes.length / 1e6 / (ms / 1000);
    const regexp = await timeCalls((count) => { for (let i = 0; i < count; i++) if (re.test(text)) sink++; }, 100);
    const string = await timeCalls((count) => { for (let i = 0; i < count; i++) if (v.testString(text)) sink++; }, 100);
    const viaBytes = await timeCalls((count) => { for (let i = 0; i < count; i++) if (v.testBytes(bytes)) sink++; }, 100);
    rows.push({ name: test.name, regexp: mbps(regexp), string: mbps(string), bytes: mbps(viaBytes) });
  }
  return rows;
}

function benchBacktrackRegExp(progress) {
  return new Promise((resolve) => {
    const results = new Map();
    const worker = new Worker("/regex-backtrack-worker.js");
    let timer = 0;
    let pending = [...BACKTRACK.lengths];
    const finish = () => { clearTimeout(timer); worker.terminate(); resolve(results); };
    const arm = () => {
      clearTimeout(timer);
      timer = setTimeout(() => {
        if (pending.length) results.set(pending[0], { timedOut: true });
        finish();
      }, BACKTRACK.budgetMs);
    };
    worker.onmessage = (event) => {
      const msg = event.data;
      if (msg.done) return finish();
      results.set(msg.n, msg);
      pending = pending.filter((n) => n !== msg.n);
      if (msg.error) return finish();
      progress(`Backtracking: RegExp took ${msg.ms.toFixed(1)} ms for ${msg.n + 1} characters`);
      arm();
    };
    worker.onerror = (event) => { results.set(pending[0], { error: event.message }); finish(); };
    worker.postMessage({ source: toJsRegExp(BACKTRACK.pattern).source, char: BACKTRACK.char, tail: BACKTRACK.tail, lengths: BACKTRACK.lengths });
    arm();
  });
}

async function benchBacktrack(progress) {
  const v = validator(compile(BACKTRACK.pattern).bytes);
  const wasm = new Map();
  for (const n of BACKTRACK.lengths) {
    const text = BACKTRACK.char.repeat(n) + BACKTRACK.tail;
    if (v.testString(text)) throw Error("The validator accepted a text it should reject.");
    wasm.set(n, await timeCalls((count) => { for (let i = 0; i < count; i++) if (v.testString(text)) sink++; }, 20));
  }
  const regexp = await benchBacktrackRegExp(progress);
  return BACKTRACK.lengths.map((n) => ({ chars: n + BACKTRACK.tail.length, wasm: wasm.get(n), regexp: regexp.get(n) ?? null }));
}

function fmt(value, digits) {
  return value.toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

function renderTables(target, result) {
  const shortRows = result.short.map((r) => `<tr><td>${escapeHTML(r.name)}</td><td>${fmt(r.regexp, 0)}</td><td>${fmt(r.string, 0)}</td><td>${fmt(r.bytes, 0)}</td></tr>`).join("");
  const longRows = result.long.map((r) => `<tr><td>${escapeHTML(r.name)}</td><td>${fmt(r.regexp, 0)}</td><td>${fmt(r.string, 0)}</td><td>${fmt(r.bytes, 0)}</td></tr>`).join("");
  const regexpCell = (r) => {
    if (!r) return "not run";
    if (r.timedOut) return `over ${fmt(BACKTRACK.budgetMs, 0)} ms, stopped`;
    if (r.error) return escapeHTML(r.error);
    return fmt(r.ms, r.ms < 10 ? 2 : 0);
  };
  const backRows = result.backtrack.map((r) => `<tr><td>${r.chars}</td><td>${regexpCell(r.regexp)}</td><td>${fmt(r.wasm * 1e6, 0)}</td></tr>`).join("");
  target.innerHTML = `
<table class="regex-table"><caption>Short strings, nanoseconds per call (lower is faster)</caption>
<thead><tr><th scope="col">Pattern</th><th scope="col">RegExp.test</th><th scope="col">Wasm, string in</th><th scope="col">Wasm, bytes in</th></tr></thead>
<tbody>${shortRows}</tbody></table>
<table class="regex-table"><caption>1 MiB of text, MB/s (higher is faster)</caption>
<thead><tr><th scope="col">Pattern</th><th scope="col">RegExp.test</th><th scope="col">Wasm, string in</th><th scope="col">Wasm, bytes in</th></tr></thead>
<tbody>${longRows}</tbody></table>
<table class="regex-table"><caption>Backtracking: <code>${escapeHTML(BACKTRACK.pattern)}</code> on <code>aaa…a!</code></caption>
<thead><tr><th scope="col">Characters</th><th scope="col">RegExp.test, ms</th><th scope="col">Wasm, string in, ns</th></tr></thead>
<tbody>${backRows}</tbody></table>`;
}

if (RECORDED) {
  renderTables(document.querySelector("#regex-recorded"), RECORDED);
} else {
  document.querySelector("#regex-recorded-note").textContent = "No results are recorded yet. Run the benchmark below.";
}

runButton.disabled = false;
benchStatus.textContent = "Ready.";
runButton.addEventListener("click", async () => {
  runButton.disabled = true;
  benchResults.textContent = "";
  const progress = (text) => { benchStatus.textContent = text + "…"; };
  try {
    const result = { short: await benchShort(progress), long: await benchLong(progress), backtrack: await benchBacktrack(progress) };
    renderTables(benchResults, result);
    window.regexBenchmarkResult = result;
    benchStatus.textContent = `Done. ${navigator.userAgent}`;
  } catch (error) {
    benchStatus.textContent = "The benchmark stopped: " + (error?.message ?? error);
  } finally {
    runButton.disabled = false;
  }
});
</script>
