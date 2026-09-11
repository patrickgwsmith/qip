import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { ContentComponentHost } from "./lib/content-component-host.mjs";

const sample = "plain \x1b[1;94mbold blue\x1b[0m\n\x1b[43;30mwarning\x1b[0m";

async function render(component) {
  const host = new ContentComponentHost(await readFile(new URL(`../text/${component}`, import.meta.url)));
  const result = host.run(sample);
  assert.equal(result.status, "accepted");
  return new TextDecoder().decode(result.output);
}

test("strip-ansi-sgr removes only supported SGR presentation", async () => {
  assert.equal(await render("strip-ansi-sgr.wasm"), "plain bold blue\nwarning");
});

test("ansi-sgr-to-html emits escaped styled preformatted text", async () => {
  const html = await render("ansi-sgr-to-html.wasm");
  assert.match(html, /^<!doctype html><meta charset="utf-8"><pre>/);
  assert.match(html, /<b><span style="color:#3b8eea;">bold blue<\/span><\/b>/);
  assert.match(html, /background-color:#e5e510/);
});

test("ansi-sgr-to-svg uses browser-native styled SVG text", async () => {
  const svg = await render("ansi-sgr-to-svg.wasm");
  assert.match(svg, /^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg"/);
  assert.match(svg, /font-family="ui-monospace/);
  assert.match(svg, /font-weight="bold"/);
  assert.match(svg, /fill="#3b8eea"/);
  assert.doesNotMatch(svg, /<path\b/);
});
