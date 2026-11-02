#!/usr/bin/env node
// Flattens the vendored JSON-Schema-Test-Suite (draft 2020-12, core tests
// only, no optional/) into two fixtures:
//
//   compliance/json-schema-2020-12.fixtures.txt
//     every group in the suite.
//   compliance/json-schema-2020-12-interoperable-regex.fixtures.txt
//     only the groups whose regexes (every "pattern" value and
//     "patternProperties" key in the schema and its remotes) stay within the
//     interoperable subset of JSON Schema 2020-12 core section 6.4, plus "."
//     and escaped syntax characters (see isInteroperableRegex). This is the
//     suite a validator that rejects every other regex at compile time can
//     pass in full.
//
// The fixture is line based so the Compliance oracle can read it with a few
// mechanical rules and no JSON parser. Every JSON value is minified onto one
// line, which JSON.stringify guarantees because it escapes control characters.
//
//   cases <n>                  total number of valid + invalid lines
//   group <file> <description> starts a test group; clears remotes and schema
//   remote <uri>               next line: a remote schema document
//   schema                     next line: the group's schema
//   valid <description>        next line: an instance that must be accepted
//   invalid <description>      next line: an instance that must be rejected
//
// Remotes come from the suite's remotes/ folder, served by the suite's
// convention at http://localhost:1234/. Each group lists only the remotes its
// schema can reach, followed transitively. The 2020-12 meta-schemas are not
// listed: a 2020-12 validator is expected to know them.
//
// Usage: node tools/gen-json-schema-2020-12-fixtures.mjs [--check]

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const suiteDir = path.join(root, "compliance/json-schema-test-suite");
const testsDir = path.join(suiteDir, "tests/draft2020-12");
const remotesDir = path.join(suiteDir, "remotes");
const outPath = path.join(root, "compliance/json-schema-2020-12.fixtures.txt");
const subsetOutPath = path.join(root, "compliance/json-schema-2020-12-interoperable-regex.fixtures.txt");
const metaSchemaDir = path.join(root, "application/json/lib/json-schema-2020-12");
const REMOTE_ORIGIN = "http://localhost:1234/";
const DEFAULT_BASE = "https://json-schema-test-suite.invalid/schema.json";

function line(value) {
  const text = JSON.stringify(value);
  if (text.includes("\n")) throw new Error("JSON.stringify produced a newline");
  return text;
}

function oneLine(text) {
  if (/[\r\n]/.test(text)) throw new Error(`description contains a newline: ${text}`);
  return text;
}

function resolve(ref, base) {
  try {
    const url = new URL(ref, base);
    url.hash = "";
    return url.href;
  } catch {
    return null;
  }
}

function remoteFile(uri) {
  if (!uri || !uri.startsWith(REMOTE_ORIGIN)) return null;
  const file = path.join(remotesDir, uri.slice(REMOTE_ORIGIN.length));
  if (!file.startsWith(remotesDir + path.sep)) return null;
  return fs.existsSync(file) && fs.statSync(file).isFile() ? file : null;
}

// Collects every URI the schema mentions in $id, $ref, $dynamicRef or
// $schema, resolved against the enclosing $id. It over-approximates (it also
// looks inside enum and const) which only means an unused remote is listed.
function referencedUris(schema, base, out) {
  if (Array.isArray(schema)) {
    for (const item of schema) referencedUris(item, base, out);
    return;
  }
  if (!schema || typeof schema !== "object") return;
  let here = base;
  if (typeof schema.$id === "string") here = resolve(schema.$id, base) ?? base;
  for (const key of ["$ref", "$dynamicRef", "$schema"]) {
    if (typeof schema[key] === "string") {
      const uri = resolve(schema[key], here);
      if (uri) out.add(uri);
    }
  }
  for (const value of Object.values(schema)) referencedUris(value, here, out);
}

function remotesFor(schema) {
  const seen = new Map();
  const pending = new Set();
  referencedUris(schema, DEFAULT_BASE, pending);
  while (pending.size > 0) {
    const [uri] = pending;
    pending.delete(uri);
    if (seen.has(uri)) continue;
    const file = remoteFile(uri);
    if (!file) continue;
    const doc = JSON.parse(fs.readFileSync(file, "utf8"));
    seen.set(uri, doc);
    referencedUris(doc, uri, pending);
  }
  return [...seen.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
}

// JSON Schema 2020-12 core section 6.4 says schema authors SHOULD limit
// themselves to these regex tokens, and nothing else:
//
//   individual Unicode characters; [abc] and [a-z] classes; [^abc] and [^a-z]
//   classes; + * ? and their lazy forms; {x} {x,y} {x,} and their lazy forms;
//   the ^ and $ anchors; (...) grouping and | alternation.
//
// Two additions, following Understanding JSON Schema's list of the same
// subset: "." (any character but a line terminator) and a backslash before a
// syntax character (\. \* \\ \/ and so on) as that literal character. Without
// them common schemas such as OpenAPI's "^3\.1\.\d+(-.+)?$" pieces could not be
// written. Everything else stays out: class escapes (\d, \w, \s), assertions
// (\b, \B), \p{...}, control and code point escapes, (?:...) and lookaround,
// and an unescaped "[" inside a class. Every accepted pattern is also a valid
// ECMA-262 "u" pattern with the same meaning.
const META = new Set([..."\\.^$|()[]{}*+?"]);
// ECMA-262 SyntaxCharacter plus "/": the identity escapes the "u" flag allows.
const ESCAPABLE = new Set([..."^$\\.*+?()[]{}|/"]);

function isInteroperableRegex(pattern) {
  const cps = [...pattern];
  let i = 0;
  const peek = () => cps[i];
  const fail = () => { throw new Error("outside subset"); };

  function digits() {
    const start = i;
    while (i < cps.length && cps[i] >= "0" && cps[i] <= "9") i += 1;
    if (i === start) fail();
    return Number(cps.slice(start, i).join(""));
  }

  function quantifier() {
    const c = peek();
    if (c === "*" || c === "+" || c === "?") {
      i += 1;
    } else if (c === "{") {
      i += 1;
      const min = digits();
      if (peek() === ",") {
        i += 1;
        if (peek() !== "}") {
          const max = digits();
          if (max < min) fail();
        }
      }
      if (peek() !== "}") fail();
      i += 1;
    } else {
      return;
    }
    if (peek() === "?") i += 1;
  }

  // Consumes "\" and a syntax character, returning that character.
  function escaped(inClass) {
    i += 1; // backslash
    const c = peek();
    // Inside a class the "u" flag also allows \- as a literal hyphen.
    if (c === undefined || !(ESCAPABLE.has(c) || (inClass && c === "-"))) fail();
    i += 1;
    return c;
  }

  function classChar() {
    const c = peek();
    if (c === "\\") return escaped(true);
    if (c === undefined || c === "[" || c === "]") fail();
    i += 1;
    return c;
  }

  function charClass() {
    i += 1; // [
    if (peek() === "^") i += 1;
    if (peek() === "]") fail(); // [] and [^] are not in the list
    while (peek() !== "]") {
      const lo = classChar();
      if (peek() === "-" && cps[i + 1] !== "]" && cps[i + 1] !== undefined) {
        i += 1;
        const hi = classChar();
        if (hi.codePointAt(0) < lo.codePointAt(0)) fail();
      }
    }
    i += 1; // ]
  }

  function disjunction() {
    for (;;) {
      while (i < cps.length && peek() !== "|" && peek() !== ")") {
        const c = peek();
        if (c === "^" || c === "$") {
          i += 1; // anchors cannot be quantified under the "u" flag
          continue;
        }
        if (c === "(") {
          i += 1;
          if (peek() === "?") fail(); // (?:...), lookaround, named groups
          disjunction();
          if (peek() !== ")") fail();
          i += 1;
        } else if (c === "[") {
          charClass();
        } else if (c === "\\") {
          escaped(false);
        } else if (c === ".") {
          i += 1;
        } else if (META.has(c)) {
          fail();
        } else {
          i += 1;
        }
        quantifier();
      }
      if (peek() !== "|") return;
      i += 1;
    }
  }

  try {
    disjunction();
    return i === cps.length;
  } catch {
    return false;
  }
}

// Every regex a schema can compile: "pattern" values and "patternProperties"
// keys. Like referencedUris it over-approximates by also looking inside enum
// and const, which can only drop a group, never keep a bad one.
function regexesIn(schema, out) {
  if (Array.isArray(schema)) {
    for (const item of schema) regexesIn(item, out);
    return;
  }
  if (!schema || typeof schema !== "object") return;
  if (typeof schema.pattern === "string") out.push(schema.pattern);
  const pp = schema.patternProperties;
  if (pp && typeof pp === "object" && !Array.isArray(pp)) out.push(...Object.keys(pp));
  for (const value of Object.values(schema)) regexesIn(value, out);
}

// Self-check of the subset rules, so a mistake in them fails loudly.
for (const ok of ["", "abc", "^a*$", "^á", "[0-9]{2,}", "x{1,3}?", "(a|b)+?", "[^#]*#?", "^[A-Za-z_][-A-Za-z0-9._]*$", "a??", "[a-]",
  ".", "f.o", "^.*bar$", ".+?", "\\.", "^3\\.1\\.[0-9]+(-.+)?$", "\\\\", "\\/", "\\(a\\)", "[\\]]", "[\\-a]", "[a\\-z]", "[\\\\-\\^]"]) {
  if (!isInteroperableRegex(ok)) throw new Error(`subset check rejects ${ok}`);
  new RegExp(ok, "u"); // throws if the subset ever admits a non-ECMA-262 pattern
}
for (const bad of ["\\d", "\\w", "\\s", "\\p{Letter}", "\\b", "\\B", "\\n", "\\u0041", "\\x41", "\\0", "\\1", "\\-", "\\a", "\\", "[\\d]", "[\\b]", "(?:a)", "(?=a)", "[[]", "[]", "a{2,1}", "a**", "^*", "(a", "a)", "[z-a]", "{2}"]) {
  if (isInteroperableRegex(bad)) throw new Error(`subset check accepts ${bad}`);
}

// A validator that only accepts the subset still has to compile the 2020-12
// meta-schemas, so their regexes must stay inside it too.
for (const name of fs.readdirSync(metaSchemaDir).filter((n) => n.endsWith(".json")).sort()) {
  const found = [];
  regexesIn(JSON.parse(fs.readFileSync(path.join(metaSchemaDir, name), "utf8")), found);
  for (const pattern of found) {
    if (!isInteroperableRegex(pattern)) throw new Error(`meta-schema ${name} uses ${pattern}, outside the subset`);
  }
}

function build(keepGroup) {
  const files = fs.readdirSync(testsDir).filter((name) => name.endsWith(".json")).sort();
  const body = [];
  let cases = 0;
  for (const name of files) {
    const groups = JSON.parse(fs.readFileSync(path.join(testsDir, name), "utf8"));
    for (const group of groups) {
      const remotes = remotesFor(group.schema);
      if (!keepGroup(group.schema, remotes)) continue;
      body.push(`group ${name} ${oneLine(group.description)}`);
      for (const [uri, doc] of remotes) {
        body.push(`remote ${uri}`, line(doc));
      }
      body.push("schema", line(group.schema));
      for (const test of group.tests) {
        body.push(`${test.valid ? "valid" : "invalid"} ${oneLine(test.description)}`, line(test.data));
        cases += 1;
      }
    }
  }
  return { cases, output: [`cases ${cases}`, ...body, ""].join("\n") };
}

function interoperable(schema, remotes) {
  const found = [];
  regexesIn(schema, found);
  for (const [, doc] of remotes) regexesIn(doc, found);
  return found.every(isInteroperableRegex);
}

const outputs = [
  [outPath, build(() => true)],
  [subsetOutPath, build(interoperable)],
];

let stale = false;
for (const [file, { cases, output }] of outputs) {
  const rel = path.relative(root, file);
  if (process.argv.includes("--check")) {
    const current = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
    if (current !== output) {
      console.error(`${rel} is out of date; run node tools/gen-json-schema-2020-12-fixtures.mjs`);
      stale = true;
    } else {
      console.log(`${rel} is up to date (${cases} cases)`);
    }
  } else {
    fs.writeFileSync(file, output);
    console.log(`wrote ${rel} (${cases} cases, ${output.length} bytes)`);
  }
}
if (stale) process.exit(1);
