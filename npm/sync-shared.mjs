#!/usr/bin/env node

// Copies the single source of code shared between npm packages into each package that uses
// it, so every package stays self-contained when published. Run with --check to fail,
// without writing, when any copy differs from its source.
//
//   node npm/sync-shared.mjs          # make npm-shared
//   node npm/sync-shared.mjs --check  # make check-npm-shared

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const npm = dirname(fileURLToPath(import.meta.url));
const root = dirname(npm);

const copies = [
  { source: "shared/qip-host.mjs", targets: ["qiptui/qip-host.mjs", "qipgui/qip-host.mjs"] },
];

const check = process.argv.includes("--check");
const stale = [];
for (const { source, targets } of copies) {
  const sourcePath = join(npm, source);
  const banner = `// GENERATED from ${relative(root, sourcePath)} by npm/sync-shared.mjs; do not edit.\n` +
    `// Edit the source, then run \`make npm-shared\`.\n\n`;
  const expected = banner + readFileSync(sourcePath, "utf8");
  for (const target of targets) {
    const targetPath = join(npm, target);
    let current = null;
    try {
      current = readFileSync(targetPath, "utf8");
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    if (current === expected) continue;
    const name = relative(root, targetPath);
    if (check) stale.push(name);
    else {
      writeFileSync(targetPath, expected);
      console.log(`updated ${name}`);
    }
  }
}
if (stale.length) {
  console.error(`out of date with npm/shared: ${stale.join(", ")}\nrun \`make npm-shared\``);
  process.exitCode = 1;
}
