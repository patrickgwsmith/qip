// Times the three validators on two workloads. Each measurement runs in its
// own Node process, so one library's garbage or JIT state cannot slow down
// the next measurement.
//
// 1. The 2020-12 suite (1,298 small cases).
//    cold: bytes in, schema compiled for every case. This is what the QIP
//          component does on every render. JS validators get JSON text and
//          pay JSON.parse + compile + validate; QIP gets the TAR and pays TAR
//          + JSON parsing + schema indexing + validation.
//    warm: JS only. Schemas compiled once per group up front, then each
//          parsed instance validated. QIP has no cross-render schema cache,
//          so it has no warm number.
//
// 2. One large document (an order book of ORDERS records, ~0.75 MB at the
//    default) against the schema in orders.mjs.
//    cold: bytes in → verdict, including JSON parsing and schema compile.
//    warm: JS only, compiled validator on an already-parsed object.
//    isValid(Buffer): ata's bytes API, which parses the bytes itself.
//
// Usage: node bench.mjs [--rounds 21] [--orders 4000]
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { performance } from "node:perf_hooks";
import { ataValidator, caseTar, cfworkerValidator, qipValidator, readFixture, writeTar } from "./lib.mjs";
import { makeOrders, orderSchema } from "./orders.mjs";

const arg = (name, fallback) => {
  const i = process.argv.indexOf(`--${name}`);
  return i < 0 ? fallback : process.argv[i + 1];
};
const ROUNDS = Number(arg("rounds", 21));
const ORDERS = Number(arg("orders", 4000));
const WARMUP = 5;

const validators = { qip: qipValidator, cfworker: cfworkerValidator, ata: ataValidator };

// Each task returns { label, validator, run } where run() is timed.
const remotesOf = (group) => Object.fromEntries(group.remotes.map((r) => [r.uri, r.json]));

function suiteCold(key) {
  const { cases } = readFixture();
  const v = validators[key]();
  if (key === "qip") {
    const tars = cases.map(({ group, test }) => caseTar(group, test.data));
    return { label: "suite cold (1,298 cases)", validator: v.name, run: () => {
      for (const tar of tars) {
        try {
          v.render(tar);
        } catch {}
      }
    } };
  }
  return { label: "suite cold (1,298 cases)", validator: v.name, run: () => {
    for (const { group, test } of cases) {
      try {
        v.compile(group.schema, remotesOf(group))(JSON.parse(test.data));
      } catch {
        // A schema the library cannot compile still cost the attempt.
      }
    }
  } };
}

function suiteWarm(key) {
  const { groups } = readFixture();
  const v = validators[key]();
  const compiled = groups.map((group) => {
    let check = null;
    try {
      check = v.compile(group.schema, remotesOf(group));
    } catch {}
    return { check, instances: group.tests.map((t) => JSON.parse(t.data)) };
  });
  return { label: "suite warm (validate only)", validator: v.name, run: () => {
    for (const { check, instances } of compiled) {
      if (!check) continue;
      for (const instance of instances) {
        try {
          check(instance);
        } catch {}
      }
    }
  } };
}

function largeDoc() {
  const doc = makeOrders(ORDERS);
  const text = JSON.stringify(doc);
  return { doc, text, bytes: Buffer.from(text), schemaText: JSON.stringify(orderSchema), label: `${ORDERS} orders, ${(text.length / 1e6).toFixed(2)} MB` };
}

function largeCold(key) {
  const d = largeDoc();
  const v = validators[key]();
  if (key === "qip") {
    const tar = writeTar([["schema.json", d.schemaText], ["instance.json", d.text]]);
    return { label: `large cold (${d.label})`, validator: v.name, run: () => v.render(tar) };
  }
  return { label: `large cold (${d.label})`, validator: v.name, run: () => v.compile(d.schemaText)(JSON.parse(d.text)) };
}

function largeColdAtaBytes() {
  const d = largeDoc();
  const v = ataValidator();
  return { label: `large cold (${d.label})`, validator: `${v.name} isValid(Buffer)`, run: () => v.compile(d.schemaText).bytes(d.bytes) };
}

function largeWarm(key) {
  const d = largeDoc();
  const v = validators[key]();
  const check = v.compile(d.schemaText);
  return { label: "large warm (validate only)", validator: v.name, run: () => check(d.doc) };
}

function largeWarmAtaBytes() {
  const d = largeDoc();
  const v = ataValidator();
  const check = v.compile(d.schemaText).bytes;
  return { label: "large warm (validate only)", validator: `${v.name} isValid(Buffer)`, run: () => check(d.bytes) };
}

function jsonParse() {
  const d = largeDoc();
  return { label: "large: JSON.parse alone (reference)", validator: "V8", run: () => JSON.parse(d.text) };
}

const tasks = {
  "suite-cold-qip": () => suiteCold("qip"),
  "suite-cold-cfworker": () => suiteCold("cfworker"),
  "suite-cold-ata": () => suiteCold("ata"),
  "suite-warm-cfworker": () => suiteWarm("cfworker"),
  "suite-warm-ata": () => suiteWarm("ata"),
  "large-cold-qip": () => largeCold("qip"),
  "large-cold-cfworker": () => largeCold("cfworker"),
  "large-cold-ata": () => largeCold("ata"),
  "large-cold-ata-bytes": largeColdAtaBytes,
  "large-warm-cfworker": () => largeWarm("cfworker"),
  "large-warm-ata": () => largeWarm("ata"),
  "large-warm-ata-bytes": largeWarmAtaBytes,
  "json-parse": jsonParse,
};

function measure(name) {
  const task = tasks[name]();
  for (let i = 0; i < WARMUP; i++) task.run();
  const samples = [];
  for (let i = 0; i < ROUNDS; i++) {
    const start = performance.now();
    task.run();
    samples.push(performance.now() - start);
  }
  samples.sort((a, b) => a - b);
  return { label: task.label, validator: task.validator, median: samples[Math.floor(samples.length / 2)], min: samples[0] };
}

function checkVerdicts() {
  const d = largeDoc();
  const bad = structuredClone(d.doc);
  bad.orders[bad.orders.length - 1].lines[0].sku = "bad-sku";
  const badText = JSON.stringify(bad);
  const qip = qipValidator();
  const out = {
    [qip.name]: [
      qip.render(writeTar([["schema.json", d.schemaText], ["instance.json", d.text]])).accepted,
      qip.render(writeTar([["schema.json", d.schemaText], ["instance.json", badText]])).accepted,
    ],
  };
  for (const v of [cfworkerValidator(), ataValidator()]) out[v.name] = [v.compile(d.schemaText)(d.doc), v.compile(d.schemaText)(bad)];
  return { label: d.label, out };
}

const only = arg("only", null);
if (only) {
  process.stdout.write(JSON.stringify(measure(only)));
} else {
  const { label, out } = checkVerdicts();
  console.log(`Large document (${label}). Verdicts for [valid document, document with one bad sku]:`);
  for (const [name, v] of Object.entries(out)) {
    console.log(`  ${name.padEnd(24)} ${JSON.stringify(v)}${v[0] === true && v[1] === false ? "" : "  <- expected [true,false]"}`);
  }
  const self = fileURLToPath(import.meta.url);
  const fmt = (ms) => (ms < 1 ? `${(ms * 1000).toFixed(0)} µs` : `${ms.toFixed(2)} ms`);
  const rows = [];
  for (const name of Object.keys(tasks)) {
    const out = execFileSync(process.execPath, [self, "--only", name, "--rounds", String(ROUNDS), "--orders", String(ORDERS)], { encoding: "utf8" });
    rows.push(JSON.parse(out));
  }
  console.log(`\nNode ${process.version}, ${process.platform}-${process.arch}. Each row in a fresh process; ${WARMUP} warm-up runs, then median and fastest of ${ROUNDS}.\n`);
  console.log("| Workload | Validator | Median | Fastest |");
  console.log("| --- | --- | ---: | ---: |");
  for (const r of rows) console.log(`| ${r.label} | ${r.validator} | ${fmt(r.median)} | ${fmt(r.min)} |`);
}
