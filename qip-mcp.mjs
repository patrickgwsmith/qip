#!/usr/bin/env node
/**
 * A dependency-free MCP 2026-07-28 server for the public qip.dev recipe
 * catalog. It supports stdio and Streamable HTTP, but deliberately exposes
 * only read-only catalog and code-generation tools.
 */
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const PROTOCOL_VERSION = "2026-07-28";
const CATALOG_HEADER = "path,input_encoding,input_mime,input_capacity_bytes,output_encoding,output_mime,output_capacity_bytes";
const MAX_REQUEST_BYTES = 1_048_576;
const MAX_RECIPES = 512;
const DEFAULT_CATALOG = new URL("./site/data/component-catalog.csv", import.meta.url);
const DEFAULT_GENERATOR = new URL("./text/csv/content-recipe-to-browser-javascript.wasm", import.meta.url);

const MIME_LABELS = {
  "application/json": "JSON",
  "application/octet-stream": "Binary data",
  "application/pdf": "PDF",
  "application/vnd.sqlite3": "SQLite database",
  "application/warc": "WARC web archive",
  "application/wasm": "WebAssembly module",
  "application/x-www-form-urlencoded": "URL-encoded form",
  "application/x-tar": "TAR archive",
  "application/xml": "XML",
  "application/zip": "ZIP archive",
  "font/ttf": "TrueType font",
  "multipart/form-data": "Multipart form data",
  "image/avif": "AVIF image",
  "image/bmp": "BMP image",
  "image/jp2": "JPEG 2000 image",
  "image/jpeg": "JPEG image",
  "image/ktx2": "KTX2 working image",
  "image/png": "PNG image",
  "image/svg+xml": "SVG image",
  "image/webp": "WebP image",
  "image/x-icon": "ICO image",
  "text/csv": "CSV",
  "text/html": "HTML",
  "text/javascript": "JavaScript",
  "text/markdown": "Markdown",
  "text/plain": "Plain text",
  "text/uri-list": "URI list",
  "text/vnd.mermaid": "Mermaid diagram",
  "text/x-c": "C source",
};

const FILE_EXTENSIONS = {
  "application/json": "json",
  "application/pdf": "pdf",
  "application/vnd.sqlite3": "sqlite",
  "application/warc": "warc",
  "application/wasm": "wasm",
  "application/x-www-form-urlencoded": "form",
  "application/x-tar": "tar",
  "application/xml": "xml",
  "application/zip": "zip",
  "multipart/form-data": "multipart",
  "image/avif": "avif",
  "image/bmp": "bmp",
  "image/jp2": "jp2",
  "image/jpeg": "jpg",
  "image/ktx2": "ktx2",
  "image/png": "png",
  "image/svg+xml": "svg",
  "image/webp": "webp",
  "image/x-icon": "ico",
  "text/csv": "csv",
  "text/html": "html",
  "text/javascript": "js",
  "text/markdown": "md",
  "text/plain": "txt",
  "text/uri-list": "txt",
  "text/vnd.mermaid": "mmd",
  "text/x-c": "c",
};

const PREFERENCES = new Set(["balanced", "quality", "smallest", "fastest"]);
const KTX2_RGBA8_SRGB = "ktx2-r8g8b8a8-srgb";
const KTX2_BGRA8_SRGB = "ktx2-b8g8r8a8-srgb";
const KTX2_RGBA32FLOAT_BT709_LINEAR = "ktx2-rgba32float-bt709-linear";
const KTX2_RGBA32FLOAT_DISPLAY_P3_LINEAR = "ktx2-rgba32float-display-p3-linear";
const KTX2_RGBA32FLOAT_DISPLAY_P3 = "ktx2-rgba32float-display-p3";

class ProtocolError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

class ToolError extends Error {}

function labelFor(mime) {
  return MIME_LABELS[mime] ?? mime;
}

function outputRole(mime) {
  return mime === "image/ktx2" ? "working" : "deliverable";
}

function encodingAccepted(actual, expected) {
  return actual === expected || (actual === "utf8" && expected === "bytes");
}

function parseCSV(csv) {
  if (!csv.endsWith("\n") || csv.includes("\r")) throw new Error("CSV must use LF lines and end with a newline.");
  const rows = [];
  let row = [];
  let field = "";
  let quoted = false;
  let closedQuote = false;
  for (let index = 0; index < csv.length; index += 1) {
    const character = csv[index];
    if (quoted) {
      if (character !== '"') {
        if (character === "\n") throw new Error("CSV fields must not contain newlines.");
        field += character;
      } else if (csv[index + 1] === '"') {
        field += '"';
        index += 1;
      } else {
        quoted = false;
        closedQuote = true;
      }
      continue;
    }
    if (closedQuote && character !== "," && character !== "\n") throw new Error("Invalid character after a quoted CSV field.");
    if (character === '"') {
      if (field.length !== 0 || closedQuote) throw new Error("Invalid quote in CSV field.");
      quoted = true;
      continue;
    }
    if (character === ",") {
      row.push(field);
      field = "";
      closedQuote = false;
      continue;
    }
    if (character === "\n") {
      row.push(field);
      rows.push(row);
      row = [];
      field = "";
      closedQuote = false;
      continue;
    }
    field += character;
  }
  if (quoted) throw new Error("Unterminated CSV quote.");
  return rows;
}

export function parseCatalog(csv) {
  const rows = parseCSV(csv);
  if (rows.length < 2 || rows[0].join(",") !== CATALOG_HEADER) throw new Error("Unexpected component catalog header.");
  return rows.slice(1).map((row, index) => {
    if (row.length !== 7) throw new Error(`Component catalog row ${index + 2} must have seven columns.`);
    const [path, inputEncoding, inputMime, inputCapacityText, outputEncoding, outputMime, outputCapacityText] = row;
    if (!path.startsWith("/") || !["bytes", "utf8"].includes(inputEncoding) || !["bytes", "utf8"].includes(outputEncoding)) {
      throw new Error(`Invalid component catalog row ${index + 2}.`);
    }
    const inputCapacity = Number(inputCapacityText);
    const outputCapacity = Number(outputCapacityText);
    if (![inputCapacity, outputCapacity].every((value) => Number.isSafeInteger(value) && value >= 0 && value <= 0xffff_ffff)) {
      throw new Error(`Component catalog capacity exceeds uint32 on row ${index + 2}.`);
    }
    return { path, inputEncoding, inputMime, inputCapacity, outputEncoding, outputMime, outputCapacity };
  });
}

function inputProfiles(component) {
  if (component.inputMime !== "image/ktx2") return [null];
  const { path } = component;
  if (path.includes("r8g8b8a8-or-b8g8r8a8-srgb")) return [KTX2_RGBA8_SRGB, KTX2_BGRA8_SRGB];
  if (path.includes("r8g8b8a8-srgb")) return [KTX2_RGBA8_SRGB];
  if (path.includes("b8g8r8a8-srgb")) return [KTX2_BGRA8_SRGB];
  if (path.includes("rgba32float-display-p3-linear")) return [KTX2_RGBA32FLOAT_DISPLAY_P3_LINEAR];
  if (path.includes("rgba32float-display-p3")) return [KTX2_RGBA32FLOAT_DISPLAY_P3];
  if (path.includes("rgba32float")) return [KTX2_RGBA32FLOAT_BT709_LINEAR];
  return [];
}

function outputProfile(component) {
  if (component.outputMime !== "image/ktx2") return null;
  const { path } = component;
  if (path.includes("rgba32float-display-p3-linear")) return KTX2_RGBA32FLOAT_DISPLAY_P3_LINEAR;
  if (path.includes("rgba32float-display-p3")) return KTX2_RGBA32FLOAT_DISPLAY_P3;
  if (path.includes("rgba32float")) return KTX2_RGBA32FLOAT_BT709_LINEAR;
  if (path.includes("r8g8b8a8-srgb")) return KTX2_RGBA8_SRGB;
  if (path.includes("b8g8r8a8-srgb")) return KTX2_BGRA8_SRGB;
  return null;
}

function stateKey(state) {
  return `${state.mime}\0${state.encoding}\0${state.profile ?? ""}`;
}

function accepts(component, state) {
  return component.inputMime === state.mime
    && (state.encoding === null || encodingAccepted(state.encoding, component.inputEncoding))
    && inputProfiles(component).includes(state.profile);
}

function nextState(component) {
  return { mime: component.outputMime, encoding: component.outputEncoding, profile: outputProfile(component) };
}

export function findRecipes(catalog, inputMime, outputMime) {
  if (inputMime === outputMime) return [[]];
  const recipes = [];
  const start = { mime: inputMime, encoding: null, profile: inputMime === "image/ktx2" ? KTX2_RGBA8_SRGB : null };
  function visit(state, steps, visited) {
    if (recipes.length >= MAX_RECIPES) return;
    for (const component of catalog) {
      if (!accepts(component, state)) continue;
      const next = nextState(component);
      const nextKey = stateKey(next);
      if (visited.has(nextKey)) continue;
      const nextSteps = [...steps, component];
      if (next.mime === outputMime) recipes.push(nextSteps);
      else visit(next, nextSteps, new Set([...visited, nextKey]));
    }
  }
  visit(start, [], new Set([stateKey(start)]));
  return recipes;
}

function countLossy(recipe) {
  return recipe.filter((component) => component.path.includes("-lossy")).length;
}

function countLossless(recipe) {
  return recipe.filter((component) => component.path.includes("-lossless")).length;
}

function intermediatePenalty(recipe) {
  return recipe.slice(0, -1).reduce((penalty, component) => {
    if (component.outputMime === "image/ktx2") return penalty + (outputProfile(component) === KTX2_RGBA8_SRGB ? 0 : 1);
    return penalty + (component.outputMime === "image/bmp" ? 2 : 0);
  }, 0);
}

function scalarPenalty(recipe) {
  return recipe.filter((component) => component.path.includes("rasterize") && !component.path.includes("-simd")).length;
}

function score(recipe, preference) {
  const lossiness = countLossy(recipe);
  const losslessness = countLossless(recipe);
  const bridge = intermediatePenalty(recipe);
  const scalar = scalarPenalty(recipe);
  if (preference === "quality") return [lossiness, bridge, recipe.length, scalar];
  if (preference === "smallest") return [losslessness, recipe.length, bridge, scalar];
  if (preference === "fastest") return [recipe.length, scalar, bridge, lossiness];
  return [lossiness, recipe.length, bridge, scalar];
}

function compareNumbers(left, right) {
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) return left[index] - right[index];
  }
  return 0;
}

export function findRankedRecipes(catalog, inputMime, outputMime, preference = "balanced") {
  if (!PREFERENCES.has(preference)) throw new ToolError(`Unsupported preference: ${preference}.`);
  return findRecipes(catalog, inputMime, outputMime).sort((left, right) =>
    compareNumbers(score(left, preference), score(right, preference))
      || left.map((component) => component.path).join("\n").localeCompare(right.map((component) => component.path).join("\n")));
}

function commandFor(recipe, inputMime, outputMime) {
  const inputExtension = FILE_EXTENSIONS[inputMime] ?? "input";
  const outputExtension = FILE_EXTENSIONS[outputMime] ?? "output";
  const paths = recipe.map((component) => component.path.replace(/^\//, "")).join(" \\\n  ");
  return `qip run -i input.${inputExtension} -o output.${outputExtension} -- \\\n  ${paths}`;
}

function csvField(value) {
  const text = String(value);
  return /[",\r\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

function contentRecipeCSV(recipe) {
  const rows = recipe.map((component) => [
    component.path,
    component.inputEncoding,
    component.inputMime,
    component.inputCapacity,
    component.outputEncoding,
    component.outputMime,
    component.outputCapacity,
  ].map(csvField).join(","));
  return `${CATALOG_HEADER}\n${rows.join("\n")}\n`;
}

async function browserJavaScriptFor(recipe, generatorPath) {
  const wasm = await readFile(generatorPath);
  const { instance } = await WebAssembly.instantiate(wasm);
  const exports = instance.exports;
  const input = new TextEncoder().encode(contentRecipeCSV(recipe));
  const capacity = exports.input_utf8_cap();
  if (input.length > capacity) throw new ToolError(`Content Recipe CSV is too large: ${input.length} > ${capacity}.`);
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.length).set(input);
  const result = BigInt.asUintN(64, exports.render(input.length));
  if ((result >> 63n) !== 0n) throw new ToolError("The browser JavaScript generator rejected this recipe.");
  const length = Number(result & 0xffff_ffffn);
  const pointer = Number((result >> 32n) & 0x7fff_ffffn);
  return new TextDecoder("utf-8", { fatal: true }).decode(new Uint8Array(exports.memory.buffer, pointer, length));
}

function jsonContent(value) {
  return [{ type: "text", text: JSON.stringify(value, null, 2) }];
}

function complete(structuredContent, extra = {}) {
  return { resultType: "complete", content: jsonContent(structuredContent), structuredContent, ...extra };
}

function discoverResult(value) {
  return {
    resultType: "complete",
    ...value,
    content: jsonContent(value),
    structuredContent: value,
  };
}

function listResult(value) {
  return {
    resultType: "complete",
    ...value,
    content: jsonContent({ tools: value.tools }),
    structuredContent: { tools: value.tools },
  };
}

function toolError(message) {
  return { resultType: "complete", content: [{ type: "text", text: message }], isError: true };
}

function toolDefinitions() {
  const recipeSchema = {
    type: "object",
    properties: {
      from: { type: "string", description: "Input MIME type." },
      to: { type: "string", description: "Output MIME type." },
      steps: { type: "array", minItems: 1, items: { type: "string", description: "Catalog component path." } },
    },
    required: ["from", "to", "steps"],
    additionalProperties: false,
  };
  return [
    {
      name: "qip.dev.content_types.list",
      title: "List qip.dev content types",
      description: "List content types in qip.dev's public component recipe catalog. KTX2 is marked as a QIP working format.",
      inputSchema: { type: "object", additionalProperties: false },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    {
      name: "qip.dev.recipes.search",
      title: "Search qip.dev component recipes",
      description: "Find up to five compatible qip.dev component recipes between two MIME types. Results are ranked for the requested tradeoff and keep incompatible KTX2 pixel profiles apart.",
      inputSchema: {
        type: "object",
        properties: {
          from: { type: "string", description: "Input MIME type." },
          to: { type: "string", description: "Desired output MIME type." },
          preference: { type: "string", enum: [...PREFERENCES], default: "balanced", description: "Ranking tradeoff." },
        },
        required: ["from", "to"],
        additionalProperties: false,
      },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    {
      name: "qip.dev.recipes.get_cli",
      title: "Get qip.dev recipe CLI command",
      description: "Generate a copy-ready qip run command for an explicit, catalog-backed component recipe.",
      inputSchema: { type: "object", properties: { recipe: recipeSchema }, required: ["recipe"], additionalProperties: false },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    {
      name: "qip.dev.recipes.get_browser_javascript",
      title: "Get qip.dev browser JavaScript recipe",
      description: "Generate browser JavaScript for an explicit, catalog-backed component recipe. This code is for browser applications, not Node.js.",
      inputSchema: { type: "object", properties: { recipe: recipeSchema }, required: ["recipe"], additionalProperties: false },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
  ];
}

function recipeFromArguments(catalog, value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new ToolError("recipe must be an object.");
  const { from, to, steps } = value;
  if (typeof from !== "string" || typeof to !== "string" || !Array.isArray(steps) || steps.length === 0 || !steps.every((step) => typeof step === "string")) {
    throw new ToolError("recipe must contain from, to, and a non-empty array of steps.");
  }
  const candidates = findRecipes(catalog, from, to);
  const recipe = candidates.find((candidate) => candidate.length === steps.length && candidate.every((component, index) => component.path === steps[index]));
  if (!recipe) throw new ToolError("recipe steps are not a compatible qip.dev catalog recipe.");
  return { from, to, recipe };
}

function objectArguments(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new ToolError("tool arguments must be an object.");
  return value;
}

function requestMeta(request) {
  const meta = request.params?._meta;
  if (!meta || typeof meta !== "object" || Array.isArray(meta)) throw new ProtocolError(-32600, "Missing request _meta.");
  if (meta["io.modelcontextprotocol/protocolVersion"] !== PROTOCOL_VERSION) {
    throw new ProtocolError(-32022, `Unsupported protocol version: ${meta["io.modelcontextprotocol/protocolVersion"] ?? "missing"}.`);
  }
  if (!Object.hasOwn(meta, "io.modelcontextprotocol/clientCapabilities")) throw new ProtocolError(-32600, "Missing client capabilities in request _meta.");
  return meta;
}

function response(id, result) {
  return { jsonrpc: "2.0", id, result };
}

function errorResponse(id, error) {
  const code = error instanceof ProtocolError ? error.code : -32603;
  return { jsonrpc: "2.0", id: id ?? null, error: { code, message: error.message ?? "Internal server error." } };
}

function validateRequest(request) {
  if (!request || typeof request !== "object" || Array.isArray(request) || request.jsonrpc !== "2.0" || typeof request.method !== "string") {
    throw new ProtocolError(-32600, "Request must be a JSON-RPC 2.0 object with a method.");
  }
  if (!Object.hasOwn(request, "id")) throw new ProtocolError(-32600, "Notifications are not supported by this server.");
  requestMeta(request);
}

function validateHTTPHeaders(headers, request) {
  const fail = (message) => { throw new ProtocolError(-32020, message); };
  if (headers.get("mcp-protocol-version") !== PROTOCOL_VERSION) fail("MCP-Protocol-Version header does not match the request.");
  if (headers.get("mcp-method") !== request.method) fail("Mcp-Method header does not match the request.");
  if (request.method === "tools/call" && headers.get("mcp-name") !== request.params?.name) fail("Mcp-Name header does not match the tool name.");
}

export async function createQIPDevServer({ catalogPath = DEFAULT_CATALOG, generatorPath = DEFAULT_GENERATOR } = {}) {
  const catalog = parseCatalog(await readFile(catalogPath, "utf8"));
  const knownMimes = new Set(catalog.flatMap((component) => [component.inputMime, component.outputMime]));
  const definitions = toolDefinitions();

  async function dispatch(request) {
    validateRequest(request);
    if (request.method === "server/discover") {
      return discoverResult({
        supportedVersions: [PROTOCOL_VERSION],
        capabilities: { tools: {} },
        instructions: "Use qip.dev recipe tools to discover public QIP component pipelines and generate CLI or browser JavaScript. The server does not execute components.",
        ttlMs: 3_600_000,
        cacheScope: "public",
        _meta: { "io.modelcontextprotocol/serverInfo": { name: "qip.dev", version: "0.1.0" } },
      });
    }
    if (request.method === "tools/list") return listResult({ tools: definitions, ttlMs: 3_600_000, cacheScope: "public" });
    if (request.method !== "tools/call") throw new ProtocolError(-32601, `Unsupported method: ${request.method}.`);
    const { name, arguments: args = {} } = request.params ?? {};
    if (typeof name !== "string") throw new ProtocolError(-32602, "tools/call requires a tool name.");
    try {
      if (name === "qip.dev.content_types.list") {
        const contentTypes = [...knownMimes].sort().map((mime) => ({ mime, label: labelFor(mime), role: outputRole(mime) }));
        return complete({ content_types: contentTypes });
      }
      if (name === "qip.dev.recipes.search") {
        const { from, to, preference = "balanced" } = objectArguments(args);
        if (!knownMimes.has(from) || !knownMimes.has(to)) throw new ToolError("from and to must be MIME types in the qip.dev catalog.");
        const recipes = findRankedRecipes(catalog, from, to, preference).slice(0, 5).map((recipe) => ({
          from,
          to,
          steps: recipe.map((component) => component.path),
          command: commandFor(recipe, from, to),
        }));
        return complete({ from, to, preference, output_role: outputRole(to), recipes });
      }
      if (name === "qip.dev.recipes.get_cli") {
        const { from, to, recipe } = recipeFromArguments(catalog, args.recipe);
        return complete({ recipe: { from, to, steps: recipe.map((component) => component.path) }, cli: commandFor(recipe, from, to) });
      }
      if (name === "qip.dev.recipes.get_browser_javascript") {
        const { from, to, recipe } = recipeFromArguments(catalog, args.recipe);
        const javascript = await browserJavaScriptFor(recipe, generatorPath);
        return complete({ recipe: { from, to, steps: recipe.map((component) => component.path) }, javascript });
      }
      throw new ProtocolError(-32602, `Unknown tool: ${name}.`);
    } catch (error) {
      if (error instanceof ProtocolError) throw error;
      if (error instanceof ToolError) return toolError(error.message);
      throw error;
    }
  }

  return { catalog, dispatch };
}

async function readHTTPBody(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > MAX_REQUEST_BYTES) throw new ProtocolError(-32600, `Request body exceeds ${MAX_REQUEST_BYTES} bytes.`);
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new ProtocolError(-32700, "Invalid JSON.");
  }
}

export function createHTTPHandler(server, { allowedOrigins = [] } = {}) {
  return async (request, responseWriter) => {
    if (request.method === "GET" && request.url?.split("?", 1)[0] === "/healthz") {
      responseWriter.writeHead(200, { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" });
      responseWriter.end("ok\n");
      return;
    }
    if (request.url?.split("?", 1)[0] !== "/mcp") {
      responseWriter.writeHead(404);
      responseWriter.end();
      return;
    }
    if (request.method !== "POST") {
      responseWriter.writeHead(405, { Allow: "POST" });
      responseWriter.end();
      return;
    }
    const origin = request.headers.origin;
    if (origin && !allowedOrigins.includes(origin)) {
      responseWriter.writeHead(403, { "Content-Type": "application/json" });
      responseWriter.end(JSON.stringify(errorResponse(null, new ProtocolError(-32600, "Origin is not allowed."))));
      return;
    }
    const contentType = request.headers["content-type"] ?? "";
    if (!contentType.toLowerCase().startsWith("application/json")) {
      responseWriter.writeHead(415, { "Content-Type": "application/json" });
      responseWriter.end(JSON.stringify(errorResponse(null, new ProtocolError(-32600, "Content-Type must be application/json."))));
      return;
    }
    let message;
    try {
      message = await readHTTPBody(request);
      validateHTTPHeaders(new Headers(request.headers), message);
      const result = await server.dispatch(message);
      responseWriter.writeHead(200, { "Content-Type": "application/json" });
      responseWriter.end(JSON.stringify(response(message.id, result)));
    } catch (error) {
      responseWriter.writeHead(400, { "Content-Type": "application/json" });
      responseWriter.end(JSON.stringify(errorResponse(message?.id, error)));
    }
  };
}

export async function serveStdio(server, input = process.stdin, output = process.stdout) {
  let buffered = "";
  input.setEncoding("utf8");
  for await (const chunk of input) {
    buffered += chunk;
    let newline;
    while ((newline = buffered.indexOf("\n")) >= 0) {
      const line = buffered.slice(0, newline).trim();
      buffered = buffered.slice(newline + 1);
      if (line === "") continue;
      let message;
      try {
        message = JSON.parse(line);
        const result = await server.dispatch(message);
        output.write(`${JSON.stringify(response(message.id, result))}\n`);
      } catch (error) {
        output.write(`${JSON.stringify(errorResponse(message?.id, error instanceof SyntaxError ? new ProtocolError(-32700, "Invalid JSON.") : error))}\n`);
      }
    }
  }
  if (buffered.trim() !== "") output.write(`${JSON.stringify(errorResponse(null, new ProtocolError(-32700, "Stdio messages must end with a newline.")))}\n`);
}

function usage() {
  return `Usage: qip-mcp [--stdio | --http] [options]\n\n`
    + `A read-only MCP 2026-07-28 server for qip.dev recipes.\n\n`
    + `Options:\n`
    + `  --stdio                 Serve newline-delimited JSON-RPC on stdin/stdout (default).\n`
    + `  --http                  Serve Streamable HTTP.\n`
    + `  --host <host>           HTTP host (default: 127.0.0.1).\n`
    + `  --port <port>           HTTP port (default: 8787).\n`
    + `  --origin <origin>       Allowed HTTP Origin; repeat as needed.\n`
    + `  --catalog <path>        Component catalog CSV.\n`
    + `  --generator <path>      Browser JavaScript generator Wasm.\n`;
}

function parseArgs(argv) {
  const options = { mode: "stdio", host: "127.0.0.1", port: 8787, allowedOrigins: [], catalogPath: DEFAULT_CATALOG, generatorPath: DEFAULT_GENERATOR };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--help" || argument === "-h") return { help: true };
    if (argument === "--stdio") options.mode = "stdio";
    else if (argument === "--http") options.mode = "http";
    else if (["--host", "--port", "--origin", "--catalog", "--generator"].includes(argument)) {
      const value = argv[++index];
      if (!value) throw new Error(`${argument} requires a value.`);
      if (argument === "--host") options.host = value;
      else if (argument === "--port") options.port = Number(value);
      else if (argument === "--origin") options.allowedOrigins.push(value);
      else if (argument === "--catalog") options.catalogPath = value;
      else options.generatorPath = value;
    } else throw new Error(`Unknown option: ${argument}.`);
  }
  if (!Number.isInteger(options.port) || options.port < 1 || options.port > 65535) throw new Error("--port must be an integer from 1 through 65535.");
  return options;
}

export async function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  if (options.help) {
    process.stdout.write(usage());
    return;
  }
  const server = await createQIPDevServer(options);
  if (options.mode === "stdio") return serveStdio(server);
  const http = createServer(createHTTPHandler(server, options));
  await new Promise((resolve, reject) => {
    http.once("error", reject);
    http.listen(options.port, options.host, resolve);
  });
  process.stderr.write(`qip-mcp: listening on http://${options.host}:${options.port}/mcp\n`);
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  main().catch((error) => {
    process.stderr.write(`qip-mcp: ${error.message ?? error}\n`);
    process.exitCode = 1;
  });
}
