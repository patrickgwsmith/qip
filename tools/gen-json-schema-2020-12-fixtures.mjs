#!/usr/bin/env node
// Flattens the vendored JSON-Schema-Test-Suite (draft 2020-12, core tests
// only, no optional/) into compliance/json-schema-2020-12.fixtures.txt.
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

const files = fs.readdirSync(testsDir).filter((name) => name.endsWith(".json")).sort();
const body = [];
let cases = 0;
for (const name of files) {
  const groups = JSON.parse(fs.readFileSync(path.join(testsDir, name), "utf8"));
  for (const group of groups) {
    body.push(`group ${name} ${oneLine(group.description)}`);
    for (const [uri, doc] of remotesFor(group.schema)) {
      body.push(`remote ${uri}`, line(doc));
    }
    body.push("schema", line(group.schema));
    for (const test of group.tests) {
      body.push(`${test.valid ? "valid" : "invalid"} ${oneLine(test.description)}`, line(test.data));
      cases += 1;
    }
  }
}

const output = [`cases ${cases}`, ...body, ""].join("\n");
if (process.argv.includes("--check")) {
  const current = fs.existsSync(outPath) ? fs.readFileSync(outPath, "utf8") : "";
  if (current !== output) {
    console.error(`${path.relative(root, outPath)} is out of date; run node tools/gen-json-schema-2020-12-fixtures.mjs`);
    process.exit(1);
  }
  console.log(`${path.relative(root, outPath)} is up to date (${cases} cases)`);
} else {
  fs.writeFileSync(outPath, output);
  console.log(`wrote ${path.relative(root, outPath)} (${cases} cases, ${output.length} bytes)`);
}
