import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { createTextRenderer } from "../lib/qip-content.js";

const exampleDir = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const component = await readFile(
  path.join(exampleDir, "..", "..", "components", "text", "e164.wasm"),
);

test("the example wraps the E.164 QIP component", async () => {
  const { instance } = await WebAssembly.instantiate(component, {});
  const normalizeE164 = createTextRenderer(instance.exports);

  assert.equal(normalizeE164("+1 (212) 555-0100"), "+12125550100");
  assert.equal(normalizeE164("not a phone number"), "");
});
