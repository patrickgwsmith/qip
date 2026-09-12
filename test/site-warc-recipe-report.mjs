import assert from "node:assert/strict";
import test from "node:test";

import {
  formatWarcRecipeReport,
  parseWarcRecipeTrace,
  summarizeWarcRecipeRuns,
} from "../tools/benchmark-site-warc-recipes.mjs";

const firstTrace = [
  "router warc archive: recipe[1] site/_recipes/application/warc/05-text-uri-list-to-redirect.wasm input=raw/application/warc/43.5MiB output=raw/application/warc/43.5MiB duration=142ms",
  "router warc archive: recipe[7] site/_recipes/application/warc/35-add-search-index.wasm input=raw/application/warc/43.7MiB output=raw/application/warc/44.2MiB duration=808ms",
  "router warc /: recipe[1] site/_recipes/text/markdown/10-markdown-basic.wasm input=raw/text/markdown/1B output=utf8/text/html/1B duration=0.100ms",
].join("\n");

const secondTrace = [
  "router warc archive: recipe[1] site/_recipes/application/warc/05-text-uri-list-to-redirect.wasm input=raw/application/warc/43.5MiB output=raw/application/warc/43.5MiB duration=176ms",
  "router warc archive: recipe[7] site/_recipes/application/warc/35-add-search-index.wasm input=raw/application/warc/43.7MiB output=raw/application/warc/44.2MiB duration=922ms",
].join("\n");

test("site WARC report parses archive recipes and formats mean and range", () => {
  const first = parseWarcRecipeTrace(firstTrace);
  const second = parseWarcRecipeTrace(secondTrace);
  assert.equal(first.get("05-text-uri-list-to-redirect"), 142);
  assert.equal(first.get("35-add-search-index"), 808);
  assert.equal(first.size, 2);

  const remainingFirst = new Map([
    ["10-add-open-graph-image-meta", 268], ["15-add-html-data-path", 136], ["20-add-docs-sidebar", 389], ["25-add-content-size", 309], ["30-add-sitemap-xml", 152], ["99-add-custom-element-scripts", 449],
  ]);
  const remainingSecond = new Map([
    ["10-add-open-graph-image-meta", 339], ["15-add-html-data-path", 277], ["20-add-docs-sidebar", 496], ["25-add-content-size", 389], ["30-add-sitemap-xml", 218], ["99-add-custom-element-scripts", 553],
  ]);
  const summary = summarizeWarcRecipeRuns([
    new Map([...first, ...remainingFirst]),
    new Map([...second, ...remainingSecond]),
  ]);
  assert.deepEqual(summary[0], {
    recipe: "35-add-search-index",
    name: "Add search index",
    mean: 865,
    min: 808,
    max: 922,
  });
  const report = formatWarcRecipeReport(summary);
  assert.match(report, /WARC recipe/);
  assert.match(report, /Add search index\s+865 ms\s+808–922 ms/);
  assert.match(report, /Add redirects\s+159 ms\s+142–176 ms/);
});
