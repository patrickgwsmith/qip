import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { copyFile, mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import test from "node:test";

import { createQIPRouter } from "../npm/qip-router/qip-router.mjs";

const execFileAsync = promisify(execFile);
const root = process.cwd();
const globalAccessorComponent = Buffer.from(
  "AGFzbQEAAAABCgJgAAF/YAF/AX8DBQQAAAABBQQBAQEBBgYBfwBBAAsHUQYGbWVtb3J5AgAJaW5wdXRfcHRyAwAPaW5wdXRfYnl0ZXNfY2FwAAAKb3V0cHV0X3B0cgABEG91dHB1dF9ieXRlc19jYXAAAgZyZW5kZXIAAwoVBAQAQQELBABBAQsEAEEBCwQAQQAL",
  "base64",
);

async function fixtureSite() {
  const directory = await mkdtemp(join(tmpdir(), "qip-node-router-"));
  await mkdir(join(directory, "docs"));
  await mkdir(join(directory, "_recipes", "text", "markdown"), { recursive: true });
  await mkdir(join(directory, "_components", "demo"), { recursive: true });
  await writeFile(join(directory, "index.md"), "# Home\n");
  await writeFile(join(directory, "docs", "guide.md"), "# Guide\n\nHello from Markdown.\n");
  await writeFile(join(directory, "plain.txt"), "plain text\n");
  const markdown = join(root, "recipes", "text", "markdown", "10-markdown-basic.wasm");
  await copyFile(markdown, join(directory, "_recipes", "text", "markdown", "10-markdown-basic.wasm"));
  await copyFile(markdown, join(directory, "_components", "demo", "markdown.wasm"));
  return directory;
}

test("self-contained Node router serves content recipes, raw Markdown, and component assets", async () => {
  const contentRoot = await fixtureSite();
  const router = await createQIPRouter({ contentRoot });

  const home = await router.resolve("GET", "/");
  assert.equal(home.status, 200);
  assert.equal(home.headers.get("content-type"), "text/html; charset=utf-8");
  assert.equal(new TextDecoder().decode(home.body), "<h1>Home</h1>\n");

  const guide = await router.resolve("GET", "/docs/guide");
  assert.match(new TextDecoder().decode(guide.body), /<h1>Guide<\/h1>/);

  const source = await router.resolve("GET", "/docs/guide.md");
  assert.equal(source.headers.get("content-type"), "text/markdown; charset=utf-8");
  assert.equal(new TextDecoder().decode(source.body), "# Guide\n\nHello from Markdown.\n");

  const component = await router.resolve("GET", "/demo/markdown.wasm");
  assert.equal(component.status, 200);
  assert.equal(component.headers.get("content-type"), "application/wasm");
  assert.ok(component.body.byteLength > 1_000);

  const missingReservedRoute = await router.resolve("GET", "/_recipes/text/markdown/10-markdown-basic.wasm");
  assert.equal(missingReservedRoute.status, 404);
});

test("Node router handles canonical redirects, HEAD, and reload discovery", async () => {
  const contentRoot = await fixtureSite();
  const router = await createQIPRouter({ contentRoot });
  const redirected = await router.resolve("GET", "/docs/guide/");
  assert.equal(redirected.status, 308);
  assert.equal(redirected.headers.get("location"), "/docs/guide");

  const head = await router.resolve("HEAD", "/plain.txt");
  assert.equal(head.status, 200);
  assert.equal(head.headers.get("content-length"), "11");
  assert.equal(head.body.byteLength, 0);

  await writeFile(join(contentRoot, "new.md"), "# Newly discovered\n");
  assert.equal((await router.resolve("GET", "/new")).status, 404);
  await router.reload();
  const afterReload = await router.resolve("GET", "/new");
  assert.equal(afterReload.status, 200);
  assert.match(new TextDecoder().decode(afterReload.body), /<h1>Newly discovered<\/h1>/);
});

test("Node router prescans focused HTML dependencies for Kindred Routes", async () => {
  const contentRoot = await mkdtemp(join(tmpdir(), "qip-node-router-kindred-"));
  await writeFile(join(contentRoot, "index.html"), "<h1>Home</h1>");
  await writeFile(join(contentRoot, "page.html"), [
    '<!-- <img src="/comment.png"> -->',
    '<p data-src="/data-attribute.png">src="/text.png"</p>',
    '<script>const example = \'</scripture><img src="/script.png">\';</script>',
    '<img src="/hero.png?size=2#preview">',
    '<qip-view src="/tool.wasm"></qip-view>',
    '<link rel="stylesheet" href="/site.css">',
    '<link rel="modulepreload" href="/app.js">',
    '<link rel="prefetch" href="/future.json?one=1&amp;two=2">',
    '<link rel="manifest" href="/app.webmanifest">',
    '<link rel="icon" href="/favicon.ico">',
    '<link rel="canonical" href="/other.html">',
  ].join("\n"));
  for (const path of ["hero.png", "tool.wasm", "site.css", "app.js", "future.json", "app.webmanifest", "favicon.ico", "other.html"]) {
    await writeFile(join(contentRoot, path), path);
  }

  const router = await createQIPRouter({ contentRoot });
  assert.deepEqual(await router.kindred("/page"), [
    { method: "GET", path: "/" },
    { method: "GET", path: "/hero.png" },
    { method: "GET", path: "/tool.wasm" },
    { method: "GET", path: "/site.css" },
    { method: "GET", path: "/app.js" },
    { method: "GET", path: "/future.json" },
    { method: "GET", path: "/app.webmanifest" },
  ]);
});

test("Node router requires lowercase HTML dependency markup", async () => {
  const contentRoot = await mkdtemp(join(tmpdir(), "qip-node-router-kindred-case-"));
  await writeFile(join(contentRoot, "upper-tag.html"), '<IMG src="/hero.png">');
  await writeFile(join(contentRoot, "upper-attribute.html"), '<img SRC="/hero.png">');
  await writeFile(join(contentRoot, "upper-relation.html"), '<link rel="STYLESHEET" href="/site.css">');
  await writeFile(join(contentRoot, "hero.png"), "png");
  await writeFile(join(contentRoot, "site.css"), "css");

  const router = await createQIPRouter({ contentRoot });
  await assert.rejects(router.kindred("/upper-tag"), /uppercase tag <IMG>/);
  await assert.rejects(router.kindred("/upper-attribute"), /uppercase attribute SRC/);
  await assert.rejects(router.kindred("/upper-relation"), /non-lowercase link rel token STYLESHEET/);
});

test("Node router rejects globals used in place of accessor functions", async () => {
  const contentRoot = await mkdtemp(join(tmpdir(), "qip-node-router-global-"));
  const recipeRoot = join(contentRoot, "_recipes", "text", "plain");
  await mkdir(recipeRoot, { recursive: true });
  await writeFile(join(contentRoot, "index.txt"), "hello\n");
  await writeFile(join(recipeRoot, "10-global-accessor.wasm"), globalAccessorComponent);
  await assert.rejects(
    createQIPRouter({ contentRoot }),
    /Wasm module must export input_ptr\(\) -> i32/,
  );
});

test("Node router reports Content component rejection", async () => {
  const contentRoot = await mkdtemp(join(tmpdir(), "qip-node-router-rejection-"));
  const recipeRoot = join(contentRoot, "_recipes", "text", "plain");
  await mkdir(recipeRoot, { recursive: true });
  await writeFile(join(contentRoot, "index.txt"), "49927398717");
  await copyFile(
    join(root, "text", "luhn.wasm"),
    join(recipeRoot, "10-luhn.wasm"),
  );
  const router = await createQIPRouter({ contentRoot });
  await assert.rejects(
    router.resolve("GET", "/index.txt"),
    /text\/plain\/10-luhn\.wasm rejected input at input offset 11/,
  );
});

test("Node and Go routers produce identical page and full-site WARC bytes", async () => {
  const router = await createQIPRouter({ contentRoot: "site", recipesRoot: "recipes" });
  const nodePage = await router.resolve("GET", "/docs/router");
  const goPage = await execFileAsync(
    join(root, "qip"),
    ["router", "get", "site", "/docs/router", "--recipes", "recipes"],
    { encoding: "buffer", maxBuffer: 2 * 1024 * 1024 },
  );
  assert.deepEqual(Buffer.from(nodePage.body), goPage.stdout);

  const search = await router.resolve("GET", "/search/v1/index/c.csv");
  assert.equal(search.status, 200);
  assert.match(new TextDecoder().decode(search.body), /^term,target,weight\nc,/);

  const nodeWarc = await router.warc();
  const goWarc = await execFileAsync(
    join(root, "qip"),
    ["router", "warc", "site", "--recipes", "recipes", "-o", "-"],
    { encoding: "buffer", maxBuffer: 64 * 1024 * 1024 },
  );
  assert.deepEqual(Buffer.from(nodeWarc), goWarc.stdout);
});
