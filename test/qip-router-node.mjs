import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { copyFile, mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import test from "node:test";

import { createContentFilter, createQIPRouter } from "../npm/qip-router/qip-router.mjs";

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

// From wat2wasm: a WARC recipe that rewrites the first "utf-8" in archives under
// 2000 bytes to "UTF-8", so its output depends on how many records it sees.
const smallArchiveUppercaseCharset = Buffer.from(
  "AGFzbQEAAAABCgJgAAF/YAF/AX4DBgUAAAAAAQUDAQACB1EGBm1lbW9yeQIACWlucHV0X3B0cgAAD2lucHV0X2J5dGVzX2NhcAABCm91dHB1dF9wdHIAAhBvdXRwdXRfYnl0ZXNfY2FwAAMGcmVuZGVyAAQKawUEAEEACwYAQYCABAsEAEEACwYAQYCABAtRAQF/IABB0A9JBEACQANAIAFBBWogAEsNASABKAIAQfXomesCRiABQQRqLQAAQThGcQRAIAFB1aiZ6gI2AgAMAgsgAUEBaiEBDAALCwsgAK0L",
  "base64",
);

// From wat2wasm: a WARC recipe that traps on archives of 1000 to 1999 bytes,
// which here means two records, and passes others through unchanged.
const smallArchiveTrap = Buffer.from(
  "AGFzbQEAAAABCgJgAAF/YAF/AX4DBgUAAAAAAQUDAQACB1EGBm1lbW9yeQIACWlucHV0X3B0cgAAD2lucHV0X2J5dGVzX2NhcAABCm91dHB1dF9wdHIAAhBvdXRwdXRfYnl0ZXNfY2FwAAMGcmVuZGVyAAQKMAUEAEEACwYAQYCABAsEAEEACwYAQYCABAsWACAAQegHTyAAQdAPSXEEQAALIACtCw==",
  "base64",
);

// From wat2wasm: a WARC recipe that loops forever on archives of 1000 to 1999
// bytes, which here means two records, and passes others through unchanged.
const smallArchiveLoop = Buffer.from(
  "AGFzbQEAAAABCgJgAAF/YAF/AX4DBgUAAAAAAQUDAQACB1EGBm1lbW9yeQIACWlucHV0X3B0cgAAD2lucHV0X2J5dGVzX2NhcAABCm91dHB1dF9wdHIAAhBvdXRwdXRfYnl0ZXNfY2FwAAMGcmVuZGVyAAQKNAUEAEEACwYAQYCABAsEAEEACwYAQYCABAsaACAAQegHTyAAQdAPSXEEQANADAALCyAArQs=",
  "base64",
);

async function kindredCheckSite(pageNames, recipe = smallArchiveUppercaseCharset) {
  const contentRoot = await mkdtemp(join(tmpdir(), "qip-node-router-check-kindred-"));
  const recipeRoot = join(contentRoot, "_recipes", "application", "warc");
  await mkdir(recipeRoot, { recursive: true });
  await writeFile(join(recipeRoot, "10-small-archive-recipe.wasm"), recipe);
  const filler = "<p>" + "x".repeat(200) + "</p>";
  await writeFile(join(contentRoot, "index.html"), `<h1>Home</h1>${filler}`);
  for (const name of pageNames) await writeFile(join(contentRoot, `${name}.html`), `<h1>${name}</h1>${filler}`);
  return contentRoot;
}

// Each Kindred Routes archive starts with "/", so only "/" has its own record
// rewritten. Every .html alias is checked as its own page.
const kindredCheckFailure =
  "1 of 12 pages differ when WARC recipes see only their Kindred Routes:\n" +
  '  /: header content-type is "text/html; charset=utf-8" in whole-site WARC, "text/html; charset=UTF-8" with only Kindred Routes';

test("Node router warc --check-kindred passes when pages match their Kindred Routes output", async () => {
  const router = await createQIPRouter({ contentRoot: await kindredCheckSite([]) });
  const checked = await router.warc({ checkKindred: true });
  assert.deepEqual(checked, await router.warc());
  assert.match(new TextDecoder().decode(checked), /charset=UTF-8/);
});

test("Node router warc --check-kindred reports pages whose output depends on other routes", async () => {
  const router = await createQIPRouter({ contentRoot: await kindredCheckSite(["a", "b", "c", "d", "e"]) });
  assert.doesNotMatch(new TextDecoder().decode(await router.warc()), /charset=UTF-8/);
  await assert.rejects(router.warc({ checkKindred: true }), { message: kindredCheckFailure });
});

test("Node router warc --check-kindred reports every page whose WARC recipes trap", async () => {
  const router = await createQIPRouter({ contentRoot: await kindredCheckSite(["a", "b", "c", "d", "e"], smallArchiveTrap) });
  await router.warc();
  const error = await router.warc({ checkKindred: true }).then(() => null, (failure) => failure);
  const [summary, ...lines] = error.message.split("\n");
  // Only "/" has a one-record Kindred Routes archive, since "/index.html" also
  // gets "/" as its parent. Each trap replaces the worker's instances, so every
  // other page is still checked.
  assert.equal(summary, "11 of 12 pages differ when WARC recipes see only their Kindred Routes:");
  assert.equal(lines.length, 11);
  for (const line of lines) assert.match(line, /^  \/\S+: WARC recipes failed with only Kindred Routes: unreachable$/);
});

test("Node router warc --check-kindred stops the whole check when a page times out", async () => {
  const router = await createQIPRouter({ contentRoot: await kindredCheckSite(["a", "b", "c", "d", "e"], smallArchiveLoop) });
  await router.warc();
  // Only the first page to time out is reported. If a worker were left
  // looping, this test file would never exit.
  await assert.rejects(router.warc({ checkKindred: true, kindredPageTimeoutMs: 200 }), {
    message: /^Kindred Routes check stopped: \/\S+: WARC recipes did not finish within 200ms$/,
  });
});

test("Node router CLI warc --check-kindred exits non-zero on a difference", async () => {
  const contentRoot = await kindredCheckSite(["a", "b", "c", "d", "e"]);
  const output = join(await mkdtemp(join(tmpdir(), "qip-node-router-check-kindred-out-")), "site.warc");
  const cli = join(root, "npm", "qip-router", "qip-router.mjs");
  await execFileAsync(process.execPath, [cli, "warc", contentRoot, "-o", output]);
  await assert.rejects(
    execFileAsync(process.execPath, [cli, "warc", contentRoot, "--check-kindred", "-o", output]),
    { code: 1, stderr: `${kindredCheckFailure}\n` },
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
    { encoding: "buffer", maxBuffer: 128 * 1024 * 1024 },
  );
  assertSameArchive(Buffer.from(nodeWarc), goWarc.stdout);
});

test("content filter routes include paths minus exclude paths and skips dot paths", () => {
  const filter = createContentFilter({ include: ["blog", "./docs/"], exclude: ["blog/drafts"] });
  const cases = {
    "blog.md": true,
    "blog/post.md": true,
    "blog/drafts.md": false,
    "blog/drafts/wip.md": false,
    "blogroll.md": false,
    "docs/router.md": true,
    "index.md": false,
    "blog/.DS_Store": false,
  };
  for (const [relPath, want] of Object.entries(cases)) assert.equal(filter.allows(relPath), want, relPath);
  assert.equal(createContentFilter({ exclude: ["blog/drafts"] }).allows(".env"), false);
  assert.equal(createContentFilter({ include: [".well-known"] }).allows(".well-known/security.txt"), true);
  assert.equal(createContentFilter().allows(".env"), true);
  assert.throws(() => createContentFilter({ include: ["../x"] }), /must not leave the content root/);
});

test("Node and Go routers filter content but keep filtered-out parent layouts", async () => {
  const contentRoot = await mkdtemp(join(tmpdir(), "qip-node-router-filter-"));
  await mkdir(join(contentRoot, "blog", "drafts"), { recursive: true });
  await writeFile(join(contentRoot, "index.md"), "# Home\n");
  await writeFile(
    join(contentRoot, "blog.md"),
    "# Blog\n\n<qip-main-layout>\n<nav><a href=\"/blog\">Blog</a></nav>\n<slot></slot>\n</qip-main-layout>\n",
  );
  await writeFile(join(contentRoot, "blog", "post.md"), "# Post\n");
  await writeFile(join(contentRoot, "blog", "drafts", "wip.md"), "# Draft\n");
  await writeFile(join(contentRoot, ".env"), "SECRET=1\n");
  const recipesRoot = join(root, "site", "_recipes");
  const router = await createQIPRouter({ contentRoot, recipesRoot, include: ["blog/post"], exclude: ["blog/drafts"] });

  assert.deepEqual(router.list().filter((entry) => entry.method === "GET").map((entry) => entry.path), ["/blog/post", "/blog/post.md"]);
  assert.equal((await router.get("/blog/drafts/wip")).status, 404);
  assert.equal((await router.get("/blog")).status, 404);
  assert.match(new TextDecoder().decode((await router.get("/blog/post")).body), /<qip-main-layout>/);
  assert.deepEqual((await router.kindred("/blog/post")).map((entry) => entry.path), ["/", "/blog"]);

  const nodeWarc = Buffer.from(await router.warc({ checkKindred: true }));
  const text = nodeWarc.toString("latin1");
  assert.match(text, /WARC-Target-URI: http:\/\/qip\.local\/blog\/post\r\n/);
  assert.doesNotMatch(text, /WARC-Target-URI: http:\/\/qip\.local\/blog\r\n/);
  assert.doesNotMatch(text, /Draft|SECRET/);
  const goWarc = await execFileAsync(
    join(root, "qip"),
    ["router", "warc", contentRoot, "--recipes", recipesRoot, "--include", "blog/post", "--exclude", "blog/drafts", "-o", "-"],
    { encoding: "buffer", maxBuffer: 16 * 1024 * 1024 },
  );
  assertSameArchive(nodeWarc, goWarc.stdout);
});

// assert.deepEqual on two large Buffers renders a full diff and exhausts the heap.
function assertSameArchive(actual, expected) {
  if (actual.equals(expected)) return;
  let offset = 0;
  while (offset < actual.length && actual[offset] === expected[offset]) offset++;
  const recordStart = Math.max(0, actual.lastIndexOf("WARC/1.1\r\n", offset));
  const excerpt = (bytes) => bytes.subarray(recordStart, Math.min(offset + 64, bytes.length)).toString("latin1");
  assert.fail(
    `WARC bytes differ at offset ${offset} (Node ${actual.length} bytes, Go ${expected.length} bytes)\n` +
    `--- Node\n${excerpt(actual)}\n--- Go\n${excerpt(expected)}`,
  );
}
