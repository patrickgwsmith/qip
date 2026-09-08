import { copyFile, mkdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const exampleDir = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const source = path.resolve(
  exampleDir,
  "..",
  "..",
  "components",
  "text",
  "e164.wasm",
);
const destinationDir = path.join(exampleDir, "public", "qip-components");

await mkdir(destinationDir, { recursive: true });
await copyFile(source, path.join(destinationDir, "e164.wasm"));
