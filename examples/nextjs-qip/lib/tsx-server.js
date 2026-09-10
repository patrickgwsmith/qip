import "server-only";

import { readFileSync } from "node:fs";
import path from "node:path";
import { cacheLife } from "next/cache";

import { createTSXHighlighter } from "./qip-content.js";

const componentPath = path.join(
  process.cwd(),
  "public",
  "qip-components",
  "html-code-syntax-highlight-tsx.wasm",
);
const module = new WebAssembly.Module(readFileSync(componentPath));
const instance = new WebAssembly.Instance(module, {});
const highlight = createTSXHighlighter(instance.exports);

export async function highlightTSX(source) {
  "use cache";
  cacheLife("max");
  return highlight(source);
}
