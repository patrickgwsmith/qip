#!/usr/bin/env node

import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const scriptPath = fileURLToPath(import.meta.url);
const root = resolve(dirname(scriptPath), "..");

const recipeNames = new Map([
  ["05-text-uri-list-to-redirect", "Add redirects"],
  ["10-add-open-graph-image-meta", "Add Open Graph metadata"],
  ["15-add-html-data-path", "Add HTML data paths"],
  ["20-add-docs-sidebar", "Add docs sidebar"],
  ["25-add-content-size", "Add content sizes"],
  ["30-add-sitemap-xml", "Add sitemap"],
  ["35-add-search-index", "Add search index"],
  ["99-add-custom-element-scripts", "Add custom-element scripts"],
]);

export function parseWarcRecipeTrace(stderr) {
  const samples = new Map();
  const pattern = /recipe\[\d+\](?:=|\s+)(\S*application\/warc\/([^/]+)\.wasm).*?duration=(\d+(?:\.\d+)?)ms/g;
  for (const match of stderr.matchAll(pattern)) {
    const [, , recipe, duration] = match;
    samples.set(recipe, Number(duration));
  }
  return samples;
}

export function summarizeWarcRecipeRuns(runs) {
  if (runs.length === 0) throw new Error("at least one run is required");
  const byRecipe = new Map();
  for (const run of runs) {
    for (const [recipe, duration] of run) {
      const values = byRecipe.get(recipe) ?? [];
      values.push(duration);
      byRecipe.set(recipe, values);
    }
  }
  if (byRecipe.size === 0) throw new Error("no WARC recipe trace samples found");
  for (const [recipe, values] of byRecipe) {
    if (values.length !== runs.length) {
      throw new Error(`missing trace samples for ${recipe}.wasm`);
    }
  }
  return [...byRecipe].map(([recipe, values]) => ({
    recipe,
    name: recipeNames.get(recipe) ?? recipe.replace(/^\d+-/, "").replaceAll("-", " "),
    mean: values.reduce((sum, value) => sum + value, 0) / values.length,
    min: Math.min(...values),
    max: Math.max(...values),
  })).sort((a, b) => b.mean - a.mean || a.name.localeCompare(b.name));
}

function formatMilliseconds(value) {
  return `${Math.round(value)} ms`;
}

export function formatWarcRecipeReport(summary) {
  const rows = summary.map((item) => [
    item.name,
    formatMilliseconds(item.mean),
    `${formatMilliseconds(item.min).replace(" ms", "")}–${formatMilliseconds(item.max)}`,
  ]);
  const widths = [
    Math.max("WARC recipe".length, ...rows.map(([name]) => name.length)),
    Math.max("Mean per build".length, ...rows.map(([, mean]) => mean.length)),
    Math.max("Range".length, ...rows.map(([, , range]) => range.length)),
  ];
  const header = ["WARC recipe", "Mean per build", "Range"];
  const separator = "  ";
  const formatRow = (cells) => cells.map((cell, index) => (
    index === 0 ? cell.padEnd(widths[index]) : cell.padStart(widths[index])
  )).join(separator);
  const divider = widths.map((width) => "━".repeat(width)).join(separator);
  const rowDivider = widths.map((width) => "─".repeat(width)).join(separator);
  return [
    formatRow(header),
    divider,
    ...rows.flatMap((row, index) => index === 0 ? [formatRow(row)] : [rowDivider, formatRow(row)]),
  ].join("\n");
}

function parseArgs(argv) {
  const options = {
    content: "site",
    host: "https://qip.dev",
    runs: 5,
    viewSource: true,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--runs") options.runs = Number(argv[++index]);
    else if (arg === "--content") options.content = argv[++index];
    else if (arg === "--host") options.host = argv[++index];
    else if (arg === "--no-view-source") options.viewSource = false;
    else if (arg === "-h" || arg === "--help") {
      console.log("Usage: benchmark-site-warc-recipes.mjs [--runs <count>] [--content <dir>] [--host <url>] [--no-view-source]");
      process.exit(0);
    } else {
      throw new Error(`unknown option ${arg}`);
    }
  }
  if (!Number.isSafeInteger(options.runs) || options.runs < 1) {
    throw new Error("--runs must be a positive integer");
  }
  if (!options.content) throw new Error("--content must not be empty");
  if (!options.host) throw new Error("--host must not be empty");
  return options;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const qip = join(root, "qip");
  const content = resolve(root, options.content);
  const args = ["router", "warc", content, "--host", options.host, "-v", "-o", "/dev/null"];
  if (options.viewSource) args.push("--view-source");

  const runs = [];
  for (let index = 0; index < options.runs; index += 1) {
    const { stderr } = await execFileAsync(qip, args, {
      cwd: root,
      encoding: "utf8",
      maxBuffer: 16 * 1024 * 1024,
    });
    runs.push(parseWarcRecipeTrace(stderr));
  }
  process.stdout.write(`${formatWarcRecipeReport(summarizeWarcRecipeRuns(runs))}\n`);
}

if (process.argv[1] && resolve(process.argv[1]) === scriptPath) {
  main().catch((error) => {
    console.error(error.message ?? error);
    process.exitCode = 1;
  });
}
