import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { ContentComponentHost } from "./lib/content-component-host.mjs";

const componentPath = new URL(
  "../text/html/html-to-svg-inter-paths.wasm",
  import.meta.url,
);
const fixturePath = new URL(
  "./fixtures/html-to-svg-inter-paths/daring-fireball-mobile.html",
  import.meta.url,
);

test("HTML-to-SVG renders a self-contained mobile Inter document", async () => {
  const host = new ContentComponentHost(await readFile(componentPath));
  const fixture = await readFile(fixturePath, "utf8");
  const result = host.run(fixture);

  assert.equal(result.status, "accepted");
  assert.equal(result.outputIsUTF8, true);
  const svg = new TextDecoder().decode(result.output);
  assert.match(svg, /^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg" width="390" height="844"/);
  assert.match(svg, /<rect[^>]+rx="12\.000"/);
  assert.match(svg, /fill="#2563eb"/);
  assert.match(svg, /fill="#ffffff"/);
  assert.match(svg, /<path /);
  assert.doesNotMatch(svg, /<text\b|font-family|href=/);
});
