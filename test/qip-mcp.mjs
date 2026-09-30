import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { Readable } from "node:stream";
import test from "node:test";
import { createHTTPHandler, createQIPDevServer } from "../qip-mcp.mjs";

const protocolVersion = "2026-07-28";
const requestMeta = {
  "io.modelcontextprotocol/protocolVersion": protocolVersion,
  "io.modelcontextprotocol/clientCapabilities": {},
};

function request(id, method, params = {}) {
  return { jsonrpc: "2.0", id, method, params: { ...params, _meta: requestMeta } };
}

async function call(server, name, args = {}) {
  return server.dispatch(request(1, "tools/call", { name, arguments: args }));
}

async function httpCall(handler, message, headers = {}, method = "POST", url = "/mcp") {
  const input = Readable.from(message === null ? [] : [Buffer.from(JSON.stringify(message))]);
  Object.assign(input, {
    method,
    url,
    headers: {
      ...(method === "POST" ? {
        "content-type": "application/json",
        "mcp-protocol-version": protocolVersion,
        "mcp-method": message.method,
        ...(message.method === "tools/call" ? { "mcp-name": message.params.name } : {}),
      } : {}),
      ...headers,
    },
  });
  let status;
  let body = "";
  await handler(input, {
    writeHead(code) { status = code; },
    end(part = "") { body += part; },
  });
  return { status, body: body === "" ? null : (body.startsWith("{") ? JSON.parse(body) : body) };
}

test("MCP discovery and tool listing use qip.dev names", async () => {
  const server = await createQIPDevServer();
  const discovery = await server.dispatch(request(1, "server/discover"));
  assert.deepEqual(discovery.supportedVersions, [protocolVersion]);
  assert.deepEqual(discovery.capabilities, { tools: {} });
  assert.equal(discovery._meta["io.modelcontextprotocol/serverInfo"].name, "qip.dev");

  const listing = await server.dispatch(request(2, "tools/list"));
  assert.deepEqual(listing.tools.map((tool) => tool.name), [
    "qip.dev.content_types.list",
    "qip.dev.mime_types.list",
    "qip.dev.modules.find",
    "qip.dev.modules.get_browser_javascript",
    "qip.dev.recipes.search",
    "qip.dev.recipes.get_cli",
    "qip.dev.recipes.get_browser_javascript",
  ]);
});

test("MIME type listing includes catalog usage counts", async () => {
  const server = await createQIPDevServer();
  const result = await call(server, "qip.dev.mime_types.list");
  const svg = result.structuredContent.mime_types.find((row) => row.mime === "image/svg+xml");
  assert.equal(svg.label, "SVG image");
  assert.equal(svg.role, "deliverable");
  assert.equal(svg.input_modules > 0, true);
  assert.equal(svg.output_modules > 0, true);
});

test("module finder returns direct qip.dev Wasm modules by MIME type", async () => {
  const server = await createQIPDevServer();
  const result = await call(server, "qip.dev.modules.find", {
    input_mime: "image/svg+xml",
    output_mime: "image/ktx2",
    limit: 1,
  });
  assert.equal(result.structuredContent.input_mime, "image/svg+xml");
  assert.equal(result.structuredContent.output_mime, "image/ktx2");
  assert.equal(result.structuredContent.count > 0, true);
  assert.equal(result.structuredContent.modules.length, 1);
  const [module] = result.structuredContent.modules;
  assert.match(module.path, /^\/image\/svg\+xml\/.+\.wasm$/);
  assert.equal(module.url, `https://qip.dev${module.path}`);
  assert.equal(module.input.mime, "image/svg+xml");
  assert.equal(module.output.mime, "image/ktx2");
  assert.equal(module.output.role, "working");
});

test("module finder requires a MIME filter", async () => {
  const server = await createQIPDevServer();
  const result = await call(server, "qip.dev.modules.find");
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /At least one/);
});

test("module JavaScript tool generates browser code for one Wasm module", async () => {
  const server = await createQIPDevServer();
  const result = await call(server, "qip.dev.modules.get_browser_javascript", {
    path: "/text/text-to-svg-inter.wasm",
  });
  assert.equal(result.structuredContent.module.path, "/text/text-to-svg-inter.wasm");
  assert.equal(result.structuredContent.module.url, "https://qip.dev/text/text-to-svg-inter.wasm");
  assert.match(result.structuredContent.javascript, /text-to-svg-inter\.wasm/);
  assert.match(result.structuredContent.javascript, /const components = await Promise\.all/);
});

test("module JavaScript tool rejects unknown paths as tool errors", async () => {
  const server = await createQIPDevServer();
  const result = await call(server, "qip.dev.modules.get_browser_javascript", {
    path: "/text/not-a-real-component.wasm",
  });
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /catalog component path/);
});

test("recipe tools return catalog-backed CLI and browser JavaScript", async () => {
  const server = await createQIPDevServer();
  const search = await call(server, "qip.dev.recipes.search", {
    from: "image/svg+xml",
    to: "image/webp",
    preference: "quality",
  });
  const [recipe] = search.structuredContent.recipes;
  assert.equal(search.structuredContent.output_role, "deliverable");
  assert.deepEqual(recipe.ranking, {
    rank: 1,
    preference: "quality",
    score: [0, 0, 2, 0],
    metrics: {
      steps: 2,
      lossy_steps: 0,
      lossless_steps: 1,
      intermediate_penalty: 0,
      scalar_fallbacks: 0,
    },
  });
  assert.match(recipe.steps[0], /svg-rasterize-to-ktx2-r8g8b8a8-srgb-simd\.wasm$/);
  assert.match(recipe.steps[1], /ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-webp-lossless\.wasm$/);

  const cli = await call(server, "qip.dev.recipes.get_cli", { recipe });
  assert.match(cli.structuredContent.cli, /^qip run -i input\.svg -o output\.webp -- \\\n/);
  assert.doesNotMatch(cli.structuredContent.cli, /\n\+/);

  const browser = await call(server, "qip.dev.recipes.get_browser_javascript", { recipe });
  assert.match(browser.structuredContent.javascript, /const components = await Promise\.all/);
});

test("recipe search can rank shortest paths first", async () => {
  const server = await createQIPDevServer();
  const search = await call(server, "qip.dev.recipes.search", {
    from: "image/svg+xml",
    to: "image/webp",
    preference: "shortest",
  });
  const [recipe] = search.structuredContent.recipes;
  assert.equal(recipe.ranking.preference, "shortest");
  assert.equal(recipe.ranking.metrics.steps, recipe.steps.length);
  assert.equal(recipe.steps.length, 2);
  assert.deepEqual(recipe.ranking.score.slice(0, 2), [2, 0]);
});

test("recipe tools reject made-up recipe steps as tool errors", async () => {
  const server = await createQIPDevServer();
  const result = await call(server, "qip.dev.recipes.get_cli", {
    recipe: {
      from: "image/svg+xml",
      to: "image/webp",
      steps: ["/image/svg+xml/not-a-real-component.wasm"],
    },
  });
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /not a compatible/);
});

test("HTTP validates the MCP header and JSON-RPC body agreement", async () => {
  const server = await createQIPDevServer();
  const handler = createHTTPHandler(server);
  const message = request(1, "tools/list");

  const good = await httpCall(handler, message);
  assert.equal(good.status, 200);
  assert.equal(good.body.result.resultType, "complete");

  const bad = await httpCall(handler, message, { "mcp-method": "tools/call" });
  assert.equal(bad.status, 400);
  assert.equal(bad.body.error.code, -32020);
});

test("HTTP serves a no-store health check outside the MCP endpoint", async () => {
  const server = await createQIPDevServer();
  const handler = createHTTPHandler(server);
  const health = await httpCall(handler, null, {}, "GET", "/healthz");
  assert.equal(health.status, 200);
  assert.equal(health.body, "ok\n");
});

function runCLI(args, input = "") {
  const result = spawnSync(process.execPath, [fileURLToPath(new URL("../qip-mcp.mjs", import.meta.url)), ...args],
    { input, encoding: "utf8", timeout: 5000 });
  assert.equal(result.error, undefined);
  return result;
}

test("CLI requires an explicit transport and shows usage without waiting for input", () => {
  for (const args of [[], ["--port", "8787"]]) {
    const result = runCLI(args);
    assert.equal(result.status, 1);
    assert.equal(result.stdout, "");
    assert.match(result.stderr, /Choose a mode: --stdio or --http/);
    assert.match(result.stderr, /Usage: qip-mcp \(--stdio \| --http\)/);
  }
  const help = runCLI(["--help"]);
  assert.equal(help.status, 0);
  assert.match(help.stdout, /Usage:/);
  assert.doesNotMatch(help.stdout, /stdin\/stdout \(default\)/);
});

test("CLI rejects conflicting transport modes", () => {
  for (const args of [["--stdio", "--http"], ["--http", "--stdio"]]) {
    const result = runCLI(args);
    assert.equal(result.status, 1);
    assert.equal(result.stdout, "");
    assert.match(result.stderr, /Choose only one mode/);
  }
});

test("explicit stdio serves MCP messages and keeps stdout free of startup text", () => {
  const result = runCLI(["--stdio"], JSON.stringify(request(1, "tools/list")) + "\n");
  assert.equal(result.status, 0);
  assert.equal(result.stderr, "");
  const message = JSON.parse(result.stdout);
  assert.equal(message.id, 1);
  assert.ok(message.result.tools.some(tool => tool.name === "qip.dev.modules.find"));
});
