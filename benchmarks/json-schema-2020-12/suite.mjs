// Runs the JSON-Schema-Test-Suite (draft 2020-12, core) against every
// validator through the same Compliance oracle that `qip comply` uses.
//
//   node suite.mjs            summary and failures per validator
//   node suite.mjs --json     machine-readable results
import { allValidators, readFixture, runOracle } from "./lib.mjs";

const { cases } = readFixture();
const results = [];
for (const validator of allValidators()) {
  const { total, failures } = runOracle(validator);
  results.push({
    validator: validator.name,
    total,
    passed: total - failures.length,
    failures: failures.map(({ ordinal, detail }) => {
      const { group, test } = cases[ordinal];
      return { ordinal, file: group.file, group: group.description, test: test.description, valid: test.valid, detail };
    }),
  });
}

if (process.argv.includes("--json")) {
  console.log(JSON.stringify(results, null, 2));
} else {
  for (const r of results) {
    const pct = ((100 * r.passed) / r.total).toFixed(2);
    console.log(`${r.validator.padEnd(24)} ${String(r.passed).padStart(4)}/${r.total}  ${pct}%`);
  }
  for (const r of results) {
    if (r.failures.length === 0) continue;
    console.log(`\n${r.validator} failures:`);
    for (const f of r.failures) console.log(`  #${f.ordinal} ${f.file} — ${f.group} — ${f.test}: ${f.detail}`);
  }
}
process.exitCode = results.some((r) => r.failures.length > 0) ? 1 : 0;
