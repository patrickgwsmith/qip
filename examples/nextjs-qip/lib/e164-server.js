import "server-only";

import { readFileSync } from "node:fs";
import path from "node:path";

import { createTextRenderer } from "./qip-content.js";

const componentPath = path.join(
  process.cwd(),
  "public",
  "qip-components",
  "e164.wasm",
);
const module = new WebAssembly.Module(readFileSync(componentPath));
const instance = new WebAssembly.Instance(module, {});

export const normalizeE164 = createTextRenderer(instance.exports);
