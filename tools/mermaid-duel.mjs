#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { runComplianceComponent } from "../test/lib/compliance-harness.mjs";

const root = new URL("../", import.meta.url);
const simonPath = resolve(process.argv[2] ?? "/tmp/qip-grok-mermaid.wasm");
const [checkerBytes, qipBytes, simonBytes] = await Promise.all([
  readFile(new URL("compliance/mermaid-to-unicode-html.comply.wasm", root)),
  readFile(new URL("text/vnd.mermaid/mermaid-to-unicode-html.wasm", root)),
  readFile(simonPath),
]);

const { cases } = await runComplianceComponent(checkerBytes);
const qip = (await WebAssembly.instantiate(qipBytes)).instance.exports;
const simon = (await WebAssembly.instantiate(simonBytes)).instance.exports;

function renderQip(input) {
  new Uint8Array(qip.memory.buffer, qip.input_ptr(), input.length).set(input);
  const result = BigInt.asUintN(64, qip.render(input.length));
  if ((result >> 63n) !== 0n) throw new Error("QIP renderer rejected input");
  const size = Number(result & 0xffff_ffffn);
  const ptr = Number((result >> 32n) & 0x7fff_ffffn);
  return Buffer.from(qip.memory.buffer, ptr, size);
}

function renderSimon(input) {
  const ptr = simon.wasm_alloc(input.length);
  new Uint8Array(simon.memory.buffer, ptr, input.length).set(input);
  const size = simon.wasm_render_html(ptr, input.length, 0);
  return Buffer.from(simon.memory.buffer, simon.wasm_result_ptr(), size);
}

function isSimonFallback(output) {
  return output.includes(Buffer.from('<span class="t"> mermaid: '));
}

function duel(name, render, acceptsFallback) {
  const failures = [];
  let passed = 0;
  for (const entry of cases) {
    try {
      const output = render(entry.input);
      const ok = entry.expected === null
        ? acceptsFallback && isSimonFallback(output)
        : output.equals(entry.expected);
      if (ok) passed++;
      else failures.push({
        ordinal: entry.ordinal,
        requirement: entry.expected === null ? "reject" : "equal",
        outcome: entry.expected === null ? `returned ${output.length} non-fallback bytes` : "output mismatch",
      });
    } catch {
      if (entry.expected === null) passed++;
      else failures.push({ ordinal: entry.ordinal, requirement: "equal", outcome: "trapped" });
    }
  }
  console.log(`${name}: ${passed}/${cases.length}`);
  for (const failure of failures) console.log(`  case ${failure.ordinal}: ${failure.requirement}; ${failure.outcome}`);
  return failures.length === 0;
}

const qipPass = duel("QIP", renderQip, false);
const simonPass = duel("Simon", renderSimon, true);
if (!qipPass || !simonPass) process.exitCode = 1;
