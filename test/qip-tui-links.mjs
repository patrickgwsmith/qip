import assert from "node:assert/strict";
import test from "node:test";

import { httpLinks } from "../site/_elements/_qip-tui-links.js";

test("links absolute HTTP URLs without swallowing prose punctuation", () => {
  const text = "See (https://example.com/a_(b)), then http://127.0.0.1:4000/path.";
  assert.deepEqual(httpLinks(text).map(({ label, href }) => [label, href]), [
    ["https://example.com/a_(b)", "https://example.com/a_(b)"],
    ["http://127.0.0.1:4000/path", "http://127.0.0.1:4000/path"],
  ]);
});

test("ignores malformed, embedded, and credential-bearing URLs", () => {
  assert.deepEqual(httpLinks(
    "https:example.com https:// javascript:alert(1) " +
    "wordhttps://example.com https://good.test@evil.test/ " +
    "https://user:pass@evil.test/",
  ), []);
});

test("keeps URL query text as the visible link target", () => {
  const [link] = httpLinks("https://example.com/search?q=one&lang=en!");
  assert.equal(link.label, "https://example.com/search?q=one&lang=en");
  assert.equal(link.href, link.label);
});
