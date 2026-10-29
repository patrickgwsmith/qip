#!/usr/bin/env node

import { createHash } from "node:crypto";
import { createServer, STATUS_CODES } from "node:http";
import { realpathSync } from "node:fs";
import { readFile, readdir, realpath, stat, writeFile } from "node:fs/promises";
import { availableParallelism } from "node:os";
import { extname, join, posix, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { isMainThread, parentPort, Worker, workerData } from "node:worker_threads";

const decoder = new TextDecoder();
const encoder = new TextEncoder();
const reservedDirectories = new Set(["_recipes", "_components", "_elements"]);

// Keep in sync with sourceMIMETypes in internal/routing.go.
const mimeTypes = new Map([
  [".apng", "image/apng"],
  [".avif", "image/avif"],
  [".bmp", "image/bmp"],
  [".c", "text/x-c"],
  [".css", "text/css"],
  [".csv", "text/csv"],
  [".gif", "image/gif"],
  [".gz", "application/gzip"],
  [".h", "text/x-c"],
  [".htm", "text/html"],
  [".html", "text/html"],
  [".ico", "image/x-icon"],
  [".jp2", "image/jp2"],
  [".jpeg", "image/jpeg"],
  [".jpg", "image/jpeg"],
  [".jxl", "image/jxl"],
  [".js", "text/javascript"],
  [".json", "application/json"],
  [".ktx2", "image/ktx2"],
  [".md", "text/markdown"],
  [".markdown", "text/markdown"],
  [".mermaid", "text/vnd.mermaid"],
  [".mjs", "text/javascript"],
  [".mmd", "text/vnd.mermaid"],
  [".mp3", "audio/mpeg"],
  [".mp4", "video/mp4"],
  [".ogg", "audio/ogg"],
  [".otf", "font/otf"],
  [".pdf", "application/pdf"],
  [".png", "image/png"],
  [".sqlite", "application/vnd.sqlite3"],
  [".sqlite3", "application/vnd.sqlite3"],
  [".svg", "image/svg+xml"],
  [".swift", "text/x-swift"],
  [".tar", "application/x-tar"],
  [".tif", "image/tiff"],
  [".tiff", "image/tiff"],
  [".ttf", "font/ttf"],
  [".txt", "text/plain"],
  [".uri", "text/uri-list"],
  [".uris", "text/uri-list"],
  [".warc", "application/warc"],
  [".wasm", "application/wasm"],
  [".wav", "audio/wav"],
  [".webm", "video/webm"],
  [".webp", "image/webp"],
  [".woff", "font/woff"],
  [".woff2", "font/woff2"],
  [".xml", "application/xml"],
  [".zig", "text/x-zig"],
  [".zip", "application/zip"],
]);

function sourceMime(filePath) {
  return mimeTypes.get(extname(filePath).toLowerCase()) ?? "application/octet-stream";
}

function responseContentType(type) {
  return type.startsWith("text/") || type === "application/xml"
    ? `${type}; charset=utf-8`
    : type;
}

function bytes(value) {
  if (value instanceof Uint8Array) return value;
  if (typeof value === "string") return encoder.encode(value);
  return new Uint8Array(value);
}

function exportedValue(exports, name) {
  const item = exports[name];
  if (typeof item !== "function") throw new Error(`Wasm module must export ${name}() -> i32`);
  return Number(item()) >>> 0;
}

function declaredType(exports, prefix) {
  const pointer = exports[`${prefix}_content_type_ptr`];
  const size = exports[`${prefix}_content_type_size`];
  if (pointer === undefined && size === undefined) return "";
  if (pointer === undefined || size === undefined) {
    throw new Error(`incomplete ${prefix} content-type exports`);
  }
  const start = exportedValue(exports, `${prefix}_content_type_ptr`);
  const length = exportedValue(exports, `${prefix}_content_type_size`);
  const type = decoder.decode(new Uint8Array(exports.memory.buffer, start, length));
  if (!/^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/.test(type)) {
    throw new Error(`invalid declared ${prefix} content type: ${type}`);
  }
  return type;
}

async function loadStage(spec) {
  const wasm = await readFile(spec.filePath);
  const module = await WebAssembly.compile(wasm);
  const imports = WebAssembly.Module.imports(module);
  if (imports.length !== 0) {
    throw new Error(`${spec.label} imports ${imports[0].module}.${imports[0].name}`);
  }
  return instantiateStage(spec, module);
}

// Instantiates a compiled stage. Kindred check workers call this with the
// main thread's compiled modules, so each recipe compiles once per process.
function instantiateStage(spec, module) {
  const instance = new WebAssembly.Instance(module);
  const exports = instance.exports;
  if (!(exports.memory instanceof WebAssembly.Memory)) {
    throw new Error(`${spec.label} does not export memory`);
  }
  if (typeof exports.render !== "function") {
    throw new Error(`${spec.label} does not export render`);
  }
  const inputCapName = exports.input_utf8_cap ? "input_utf8_cap" : "input_bytes_cap";
  const outputCapName = exports.output_utf8_cap ? "output_utf8_cap" : "output_bytes_cap";
  exportedValue(exports, "input_ptr");
  exportedValue(exports, inputCapName);
  exportedValue(exports, outputCapName);
  return {
    ...spec,
    module,
    exports,
    inputType: declaredType(exports, "input"),
    outputType: declaredType(exports, "output"),
    inputCapName,
    outputCapName,
    clearsContentType: !!exports.output_utf8_cap && !!exports.input_bytes_cap,
  };
}

function runStage(stage, input) {
  const { exports } = stage;
  const inputPointer = exportedValue(exports, "input_ptr");
  const inputCapacity = exportedValue(exports, stage.inputCapName);
  if (input.byteLength > inputCapacity || inputPointer + input.byteLength > exports.memory.buffer.byteLength) {
    throw new RangeError(`${stage.label} input exceeds its capacity`);
  }
  new Uint8Array(exports.memory.buffer, inputPointer, input.byteLength).set(input);
  const renderResult = exports.render(input.byteLength);
  if (typeof renderResult !== "bigint") {
    throw new TypeError(`${stage.label} render export must have signature render(i32) -> i64`);
  }
  const bits = BigInt.asUintN(64, renderResult);
  const outputLength = Number(bits & 0xffff_ffffn);
  if ((bits & (1n << 63n)) !== 0n) {
    if (typeof exports.failure_modes_per_input_offset !== "function") {
      throw new TypeError(`${stage.label} returned failure without failure_modes_per_input_offset`);
    }
    const modes = exportedValue(exports, "failure_modes_per_input_offset");
    if (modes === 0) throw new Error(`${stage.label} rejected input`);
    const position = Math.floor(outputLength / modes);
    const mode = outputLength % modes;
    throw new Error(modes === 1
      ? `${stage.label} rejected input at input offset ${position}`
      : `${stage.label} rejected input at input offset ${position} with mode ${mode}`);
  }
  const outputPointer = Number((bits >> 32n) & 0x7fff_ffffn);
  const outputCapacity = exportedValue(exports, stage.outputCapName);
  if (outputLength > outputCapacity || outputPointer + outputLength > exports.memory.buffer.byteLength) {
    throw new RangeError(`${stage.label} returned an invalid output length`);
  }
  return new Uint8Array(exports.memory.buffer, outputPointer, outputLength).slice();
}

async function walkFiles(root, { skipReserved = false } = {}) {
  const files = [];
  const activeDirectories = new Set();
  async function walk(directory, relDirectory) {
    const canonical = await realpath(directory);
    if (activeDirectories.has(canonical)) return;
    activeDirectories.add(canonical);
    try {
      const entries = await readdir(directory, { withFileTypes: true });
      entries.sort((a, b) => a.name.localeCompare(b.name));
      for (const entry of entries) {
        if (skipReserved && relDirectory === "" && reservedDirectories.has(entry.name)) continue;
        const relPath = relDirectory ? `${relDirectory}/${entry.name}` : entry.name;
        const filePath = join(directory, entry.name);
        if (entry.isFile()) files.push({ relPath, filePath });
        else if (entry.isDirectory()) await walk(filePath, relPath);
        else if (entry.isSymbolicLink()) {
          const info = await stat(filePath);
          if (info.isFile()) files.push({ relPath, filePath });
          else if (info.isDirectory()) await walk(filePath, relPath);
          else throw new Error(`content entry ${filePath} must be a regular file`);
        } else {
          throw new Error(`content entry ${filePath} must be a regular file`);
        }
      }
    } finally {
      activeDirectories.delete(canonical);
    }
  }
  await walk(root, "");
  return files;
}

function routeAliases(relPath) {
  const aliases = [`/${relPath}`];
  const extension = extname(relPath);
  const lower = extension.toLowerCase();
  if (![".html", ".md", ".markdown", ".uri", ".uris"].includes(lower)) return aliases;
  const withoutExtension = relPath.slice(0, -extension.length);
  const parts = withoutExtension.split("/");
  if (parts.at(-1).toLowerCase() === "index") {
    parts.pop();
    const directory = parts.join("/");
    aliases.push(directory ? `/${directory}` : "/");
    if (directory) aliases.push(`/${directory}/`);
  } else {
    aliases.push(`/${withoutExtension}`);
  }
  return [...new Set(aliases)];
}

async function discoverContentRoutes(contentRoot) {
  const routes = new Map();
  for (const file of await walkFiles(contentRoot, { skipReserved: true })) {
    const route = { ...file, sourceType: sourceMime(file.relPath) };
    for (const requestPath of routeAliases(file.relPath)) {
      const previous = routes.get(requestPath);
      if (previous && previous.filePath !== route.filePath) {
        throw new Error(`duplicate route path ${requestPath} for ${previous.relPath} and ${route.relPath}`);
      }
      routes.set(requestPath, route);
    }
  }
  return routes;
}

// Keep in sync with ContentPathFilter in internal/content_filter.go. The
// routed files are the include paths, or every file when there are none, minus
// the exclude paths. An active filter skips dot paths unless an include path
// names them.
export function createContentFilter({ include = [], exclude = [] } = {}) {
  const normalize = (flag, values) => values.map((value) => {
    let path = String(value).trim();
    if (path.includes("\\")) throw new Error(`${flag} ${JSON.stringify(value)} must use / separators`);
    path = path.replace(/^\/+|\/+$/g, "");
    const parts = [];
    for (const part of path.split("/")) {
      if (part === "" || part === ".") continue;
      if (part === "..") {
        if (parts.length === 0) throw new Error(`${flag} ${JSON.stringify(value)} must not leave the content root`);
        parts.pop();
      } else parts.push(part);
    }
    if (parts.length === 0) throw new Error(`${flag} ${JSON.stringify(value)} must name a path inside the content root`);
    return parts.join("/");
  });
  const includes = normalize("--include", include);
  const excludes = normalize("--exclude", exclude);
  const active = includes.length > 0 || excludes.length > 0;
  // Matches whole segments, and the file whose path without its extension is
  // the prefix. Returns the part of relPath below the prefix.
  const match = (relPath, prefix) => {
    const extension = extname(relPath);
    if (relPath === prefix || (extension && relPath.slice(0, -extension.length) === prefix)) return "";
    if (relPath.startsWith(`${prefix}/`)) return relPath.slice(prefix.length + 1);
    return null;
  };
  const hasDotSegment = (relPath) => relPath.split("/").some((segment) => segment.startsWith("."));
  return {
    active,
    allows(relPath) {
      if (!active) return true;
      if (excludes.some((prefix) => match(relPath, prefix) !== null)) return false;
      if (includes.length === 0) return !hasDotSegment(relPath);
      return includes.some((prefix) => {
        const rest = match(relPath, prefix);
        return rest !== null && !hasDotSegment(rest);
      });
    },
  };
}

function filterContentRoutes(routes, filter) {
  if (!filter.active) return routes;
  return new Map([...routes].filter(([, route]) => filter.allows(route.relPath)));
}

async function discoverAssetRoutes(root, requestPrefix, accept) {
  const routes = new Map();
  try {
    for (const file of await walkFiles(root)) {
      if (!accept(file.relPath)) continue;
      routes.set(`${requestPrefix}/${file.relPath}`, file);
    }
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
  return routes;
}

async function discoverRecipeSpecs(recipesRoot) {
  const specs = new Map();
  let typeEntries;
  try {
    typeEntries = await readdir(recipesRoot, { withFileTypes: true });
  } catch (error) {
    if (error?.code === "ENOENT") return specs;
    throw error;
  }
  for (const typeEntry of typeEntries.sort((a, b) => a.name.localeCompare(b.name))) {
    if (!typeEntry.isDirectory()) continue;
    const typeRoot = join(recipesRoot, typeEntry.name);
    const subtypeEntries = await readdir(typeRoot, { withFileTypes: true });
    for (const subtypeEntry of subtypeEntries.sort((a, b) => a.name.localeCompare(b.name))) {
      if (!subtypeEntry.isDirectory()) continue;
      const sourceType = `${typeEntry.name}/${subtypeEntry.name}`;
      const chainRoot = join(typeRoot, subtypeEntry.name);
      const entries = await readdir(chainRoot, { withFileTypes: true });
      const chain = [];
      const orders = new Map();
      for (const entry of entries) {
        const filePath = join(chainRoot, entry.name);
        const regularFile = entry.isFile() || (entry.isSymbolicLink() && (await stat(filePath)).isFile());
        if (!regularFile || !entry.name.endsWith(".wasm")) continue;
        const match = /^(-?)([0-9]{2})-(.+)\.wasm$/.exec(entry.name);
        if (!match) throw new Error(`invalid recipe filename ${sourceType}/${entry.name}`);
        if (match[1]) continue;
        const order = Number(match[2]);
        if (orders.has(order)) {
          throw new Error(`duplicate recipe step ${match[2]} for ${sourceType}`);
        }
        orders.set(order, entry.name);
        chain.push({
          sourceType,
          order,
          filePath,
          label: `${sourceType}/${entry.name}`,
        });
      }
      chain.sort((a, b) => a.order - b.order || a.label.localeCompare(b.label));
      if (chain.length) specs.set(sourceType, chain);
    }
  }
  return specs;
}

async function createRecipeRuntime(recipesRoot) {
  const specs = await discoverRecipeSpecs(recipesRoot);
  const chains = new Map();
  for (const [sourceType, chainSpecs] of specs) {
    const chain = await Promise.all(chainSpecs.map(loadStage));
    let type = sourceType;
    for (const stage of chain) {
      if (stage.inputType && stage.inputType !== type) {
        throw new Error(`${stage.label} expects ${stage.inputType}, got ${type}`);
      }
      if (stage.outputType) type = stage.outputType;
      else if (stage.clearsContentType) type = "";
    }
    chains.set(sourceType, { stages: chain, outputType: type });
  }
  const queues = new Map();
  return Object.freeze({
    sourceTypes: Object.freeze([...chains.keys()]),
    has(sourceType) {
      return chains.has(sourceType);
    },
    outputType(sourceType) {
      return chains.get(sourceType)?.outputType ?? sourceType;
    },
    render(sourceType, input) {
      const chain = chains.get(sourceType);
      if (!chain) return Promise.reject(new Error(`no recipe for ${sourceType}`));
      const previous = queues.get(sourceType) ?? Promise.resolve();
      const result = previous.then(() => renderChain(chain.stages, sourceType, input));
      queues.set(sourceType, result.catch(() => {}));
      return result;
    },
    // The compiled modules of a chain, for instantiating it in a worker.
    stageSpecs(sourceType) {
      return (chains.get(sourceType)?.stages ?? []).map(({ sourceType, order, label, module }) => ({ sourceType, order, label, module }));
    },
  });
}

function renderChain(stages, sourceType, input) {
  let output = bytes(input);
  let type = sourceType;
  // Hash payloads natively so recipes can read WARC-Payload-Digest instead
  // of hashing in wasm, and so a recipe that leaves a stale digest is named.
  const digester = sourceType === "application/warc" ? createPayloadDigester() : null;
  if (digester) output = digester.apply(output);
  for (const stage of stages) {
    if (stage.inputType && stage.inputType !== type) {
      throw new Error(`${stage.label} expects ${stage.inputType}, got ${type}`);
    }
    output = runStage(stage, output);
    if (digester) {
      try {
        output = digester.apply(output);
      } catch (error) {
        throw new Error(`${stage.label}: ${error.message}`);
      }
    }
    if (stage.outputType) type = stage.outputType;
    else if (stage.clearsContentType) type = "";
  }
  return { bytes: output, contentType: type };
}

// A pool of worker threads that each keep one instance of every
// application/warc recipe step and reuse it for page after page, so a
// recipe's large starting memory is set up once per worker, not per page.
// A page that runs longer than timeoutMs fails the whole check: every worker
// is terminated, which also stops running Wasm, and no page is retried.
function createKindredPool(stageSpecs, size, timeoutMs) {
  const workers = [];
  const idle = [];
  const queue = [];
  let nextID = 0;
  let failure = null;

  function dispatch() {
    while (!failure && idle.length && queue.length) {
      const entry = idle.pop();
      const task = queue.shift();
      entry.task = task;
      entry.worker.postMessage({ id: task.id, targetURI: task.targetURI, archive: task.archive }, [task.archive.buffer]);
      entry.timer = setTimeout(() => {
        fail(new Error(`Kindred Routes check stopped: ${task.pathname}: WARC recipes did not finish within ${timeoutMs}ms`));
      }, timeoutMs);
    }
  }

  function fail(error) {
    if (failure) return;
    failure = error;
    for (const entry of workers) {
      clearTimeout(entry.timer);
      entry.task?.reject(failure);
      entry.task = null;
      entry.worker.terminate();
    }
    for (const task of queue.splice(0)) task.reject(failure);
  }

  for (let index = 0; index < size; index += 1) {
    const worker = new Worker(new URL(import.meta.url), {
      workerData: { qipRouterKindredWorker: true, stageSpecs },
    });
    const entry = { worker, task: null, timer: null };
    worker.on("message", (message) => {
      if (failure) return;
      // Instantiating every step can take a while, so a worker only takes
      // pages, and their timers only start, once it is ready.
      if (message.ready) {
        idle.push(entry);
        dispatch();
        return;
      }
      clearTimeout(entry.timer);
      const task = entry.task;
      entry.task = null;
      idle.push(entry);
      if (message.response) {
        const { status, headers, body } = message.response;
        task.resolve({ response: { status, headers: new Headers(headers), body } });
      } else {
        task.resolve(message);
      }
      dispatch();
    });
    worker.on("error", fail);
    worker.on("exit", (code) => {
      if (code !== 0) fail(new Error(`kindred check worker exited with code ${code}`));
    });
    workers.push(entry);
  }

  return {
    size,
    // Resolves to { response } for the record at targetURI, { missing: true }
    // when the recipes dropped it, or { error } when they failed. Rejects if
    // any page timed out or a worker died.
    run(pathname, targetURI, archive) {
      if (failure) return Promise.reject(failure);
      return new Promise((resolveTask, rejectTask) => {
        queue.push({ id: nextID++, pathname, targetURI, archive, resolve: resolveTask, reject: rejectTask });
        dispatch();
      });
    },
    close() {
      return Promise.all(workers.map((entry) => entry.worker.terminate()));
    },
  };
}

function runKindredWorker({ stageSpecs }) {
  const instantiate = () => stageSpecs.map((spec) => instantiateStage(spec, spec.module));
  let stages = instantiate();
  parentPort.postMessage({ ready: true });
  parentPort.on("message", ({ id, targetURI, archive }) => {
    let reply;
    try {
      const rendered = renderChain(stages, "application/warc", archive);
      const record = parseWarcResponses(rendered.bytes).find((item) => item.targetURI === targetURI);
      if (!record) reply = { id, missing: true };
      else {
        const { status, headers, body } = record.response;
        reply = { id, response: { status, headers: [...headers], body } };
      }
    } catch (error) {
      reply = { id, error: error.message ?? String(error) };
      // A trap can leave an instance's memory half-written, so start over.
      stages = instantiate();
    }
    parentPort.postMessage(reply, reply.response ? [reply.response.body.buffer] : []);
  });
}

function canonicalPath(pathname) {
  let value;
  try {
    value = decodeURI(pathname || "/");
  } catch {
    return null;
  }
  if (!value.startsWith("/")) value = `/${value}`;
  const parts = [];
  for (const part of value.split("/")) {
    if (!part || part === ".") continue;
    if (part === "..") parts.pop();
    else parts.push(part);
  }
  return `/${parts.join("/")}` || "/";
}

function isCustomElementName(name) {
  if (!/^[a-z][a-z0-9._-]*$/.test(name) || !name.includes("-")) return false;
  return !name.toLowerCase().startsWith("xml");
}

function rawMarkdownRequest(pathname, route) {
  if (route.sourceType !== "text/markdown") return false;
  return [".md", ".markdown"].includes(extname(pathname).toLowerCase());
}

function makeResponse(status, contentType, body, headers = {}, addCharset = true) {
  const resultHeaders = new Headers(headers);
  if (contentType) resultHeaders.set("Content-Type", addCharset ? responseContentType(contentType) : contentType);
  return { status, headers: resultHeaders, body: bytes(body) };
}

function headResponse(response) {
  const headers = new Headers(response.headers);
  if (!headers.has("content-length")) headers.set("content-length", String(response.body.byteLength));
  return { ...response, headers, body: new Uint8Array() };
}

function parentPaths(pathname) {
  const parts = pathname.split("/").filter(Boolean);
  const paths = ["/"];
  let current = "";
  for (let index = 0; index < parts.length - 1; index += 1) {
    current += `/${parts[index]}`;
    paths.push(current);
  }
  return [...new Set(paths)].filter((path) => path !== pathname);
}

const rawTextTags = new Set([
  "script",
  "style",
  "textarea",
  "title",
  "xmp",
  "iframe",
  "noembed",
  "noframes",
  "plaintext",
]);
const kindredLinkRelations = new Set([
  "stylesheet",
  "manifest",
  "preload",
  "modulepreload",
  "prefetch",
]);

function htmlSpace(character) {
  return character === " " || character === "\t" || character === "\n" || character === "\r" || character === "\f";
}

function htmlNameCharacter(character) {
  return character !== undefined && /[A-Za-z0-9:_-]/.test(character);
}

function rawTextEnd(html, tagName, offset) {
  const needle = `</${tagName}`;
  while (offset < html.length) {
    const found = html.indexOf(needle, offset);
    if (found === -1) return -1;
    const next = html[found + needle.length];
    if (next === ">" || next === "/" || htmlSpace(next)) return found;
    offset = found + needle.length;
  }
  return -1;
}

function decodeHTMLAttribute(value) {
  return value.replace(/&(?:amp|quot|apos|lt|gt|#(?:[0-9]+|x[0-9a-fA-F]+));/g, (reference) => {
    if (reference === "&amp;") return "&";
    if (reference === "&quot;") return '"';
    if (reference === "&apos;") return "'";
    if (reference === "&lt;") return "<";
    if (reference === "&gt;") return ">";
    const hexadecimal = reference[2] === "x";
    const digits = reference.slice(hexadecimal ? 3 : 2, -1);
    const codePoint = Number.parseInt(digits, hexadecimal ? 16 : 10);
    try {
      return String.fromCodePoint(codePoint);
    } catch {
      return "\ufffd";
    }
  });
}

function htmlDependencyPaths(body, basePath) {
  const html = decoder.decode(body);
  const paths = [];
  const seen = new Set();

  function addPath(reference) {
    if (!reference) return;
    try {
      const url = new URL(decodeHTMLAttribute(reference), `http://qip.local${basePath}`);
      if (url.origin !== "http://qip.local") return;
      const pathname = canonicalPath(url.pathname);
      if (!pathname || seen.has(pathname)) return;
      if (paths.length === 256) throw new Error(`HTML for ${basePath} references more than 256 Kindred Routes`);
      seen.add(pathname);
      paths.push(pathname);
    } catch (error) {
      if (error?.message?.includes("references more than 256 Kindred Routes")) throw error;
      // Invalid browser URLs do not create Kindred Routes.
    }
  }

  let offset = 0;
  while (offset < html.length) {
    const tagStart = html.indexOf("<", offset);
    if (tagStart === -1) break;
    if (html.startsWith("<!--", tagStart)) {
      const commentEnd = html.indexOf("-->", tagStart + 4);
      if (commentEnd === -1) break;
      offset = commentEnd + 3;
      continue;
    }

    let cursor = tagStart + 1;
    while (htmlSpace(html[cursor])) cursor += 1;
    if (html[cursor] === "/" || html[cursor] === "!" || html[cursor] === "?") {
      const tagEnd = html.indexOf(">", cursor + 1);
      if (tagEnd === -1) break;
      offset = tagEnd + 1;
      continue;
    }

    const nameStart = cursor;
    while (htmlNameCharacter(html[cursor])) cursor += 1;
    if (nameStart === cursor) {
      offset = tagStart + 1;
      continue;
    }
    const tagName = html.slice(nameStart, cursor);
    if (/[A-Z]/.test(tagName)) throw new Error(`HTML for ${basePath} has uppercase tag <${tagName}>`);

    const attributes = new Map();
    let complete = false;
    while (cursor < html.length) {
      while (htmlSpace(html[cursor]) || html[cursor] === "/") cursor += 1;
      if (html[cursor] === ">") {
        cursor += 1;
        complete = true;
        break;
      }
      const attributeStart = cursor;
      while (htmlNameCharacter(html[cursor])) cursor += 1;
      if (attributeStart === cursor) {
        cursor += 1;
        continue;
      }
      const attributeName = html.slice(attributeStart, cursor);
      if (/[A-Z]/.test(attributeName)) {
        throw new Error(`HTML for ${basePath} has uppercase attribute ${attributeName} on <${tagName}>`);
      }
      while (htmlSpace(html[cursor])) cursor += 1;
      let value = "";
      if (html[cursor] === "=") {
        cursor += 1;
        while (htmlSpace(html[cursor])) cursor += 1;
        if (html[cursor] === '"' || html[cursor] === "'") {
          const quote = html[cursor];
          cursor += 1;
          const valueStart = cursor;
          while (cursor < html.length && html[cursor] !== quote) cursor += 1;
          if (cursor >= html.length) break;
          value = html.slice(valueStart, cursor);
          cursor += 1;
        } else {
          const valueStart = cursor;
          while (cursor < html.length && !htmlSpace(html[cursor]) && html[cursor] !== ">") cursor += 1;
          value = html.slice(valueStart, cursor);
        }
      }
      if (!attributes.has(attributeName)) attributes.set(attributeName, value);
    }
    if (!complete) break;

    addPath(attributes.get("src"));
    if (tagName === "link" && attributes.has("href") && attributes.has("rel")) {
      const relations = attributes.get("rel").split(/[\t\n\f\r ]+/).filter(Boolean);
      for (const relation of relations) {
        if (!/^[a-z0-9-]+$/.test(relation)) {
          throw new Error(`HTML for ${basePath} has non-lowercase link rel token ${relation}`);
        }
      }
      if (relations.some((relation) => kindredLinkRelations.has(relation))) addPath(attributes.get("href"));
    }

    offset = cursor;
    if (tagName === "plaintext") break;
    if (rawTextTags.has(tagName)) {
      const closingTag = rawTextEnd(html, tagName, offset);
      if (closingTag === -1) break;
      offset = closingTag;
    }
  }
  return paths;
}

function headerEntries(headers) {
  return [...headers.entries()]
    .map(([name, value]) => [
      name.split("-").map((part) => part ? part[0].toUpperCase() + part.slice(1).toLowerCase() : part).join("-"),
      value,
    ])
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
}

function recordID(targetURI, payload) {
  const hash = createHash("sha256")
    .update("qip:warc-response:v1\0")
    .update(targetURI)
    .update("\0")
    .update(payload)
    .digest()
    .subarray(0, 16);
  hash[6] = (hash[6] & 0x0f) | 0x80;
  hash[8] = (hash[8] & 0x3f) | 0x80;
  const hex = hash.toString("hex");
  return `<urn:uuid:${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}>`;
}

// Keep in sync with PayloadDigest in internal/warc/warc.go.
function payloadDigest(payload) {
  return `sha256:${createHash("sha256").update(payload).digest("hex")}`;
}

function digestValueMatches(value, sum) {
  if (/^[0-9a-fA-F]{64}$/.test(value)) return value.toLowerCase() === sum.toString("hex");
  const trimmed = value.replace(/=+$/, "");
  if (/^[A-Za-z2-7]{52}$/.test(trimmed)) return trimmed.toUpperCase() === base32(sum);
  return trimmed === sum.toString("base64").replace(/=+$/, "") || trimmed === sum.toString("base64url");
}

function base32(data) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let output = "";
  let bits = 0;
  let value = 0;
  for (const byte of data) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      output += alphabet[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) output += alphabet[(value << (5 - bits)) & 31];
  return output;
}

// Keep in sync with PayloadDigester in internal/warc/warc.go: adds a sha256
// WARC-Payload-Digest to response and resource records that lack one, rejects
// stale sha256 digests, and skips rehashing payloads unchanged since the
// previous apply.
function createPayloadDigester() {
  let verified = new Map();
  return {
    apply(archive) {
      const data = Buffer.from(archive.buffer, archive.byteOffset, archive.byteLength);
      const next = new Map();
      const chunks = [];
      let copied = 0;
      let cursor = 0;
      let recordNumber = 0;
      while (cursor < data.byteLength) {
        recordNumber += 1;
        const headerEnd = data.indexOf("\r\n\r\n", cursor);
        if (headerEnd < 0) throw new Error(`WARC record ${recordNumber} is missing its header terminator`);
        let length = -1;
        let warcType = "";
        let targetURI = "";
        let digest = null;
        for (const line of data.toString("latin1", cursor, headerEnd).split("\r\n").slice(1)) {
          const colon = line.indexOf(":");
          if (colon <= 0 || line[0] === " " || line[0] === "\t") continue;
          const name = line.slice(0, colon).trim().toLowerCase();
          const value = line.slice(colon + 1).trim();
          if (name === "content-length") {
            length = /^\d+$/.test(value) ? Number(value) : NaN;
            if (!Number.isSafeInteger(length)) throw new Error(`WARC record ${recordNumber} has invalid Content-Length ${value}`);
          } else if (name === "warc-type") warcType = value.toLowerCase();
          else if (name === "warc-target-uri") targetURI = value;
          else if (name === "warc-payload-digest") digest = value;
        }
        if (length < 0) throw new Error(`WARC record ${recordNumber} is missing content-length`);
        const blockStart = headerEnd + 4;
        const blockEnd = blockStart + length;
        if (blockEnd > data.byteLength) throw new Error(`WARC record ${recordNumber} block exceeds the archive`);
        const following = Math.min(blockEnd + 4, data.byteLength);

        let payload = null;
        if (warcType === "response") {
          const httpEnd = data.indexOf("\r\n\r\n", blockStart);
          if (httpEnd >= 0 && httpEnd + 4 <= blockEnd) payload = data.subarray(httpEnd + 4, blockEnd);
        } else if (warcType === "resource") {
          payload = data.subarray(blockStart, blockEnd);
        }
        if (payload) {
          const colon = digest?.indexOf(":") ?? -1;
          const algorithm = colon >= 0 ? digest.slice(0, colon).toLowerCase() : digest;
          if (digest !== null && algorithm === "sha256") {
            const value = digest.slice(colon + 1).trim();
            const previous = verified.get(value);
            if (!previous || !previous.equals(payload)) {
              const sum = createHash("sha256").update(payload).digest();
              if (!digestValueMatches(value, sum)) {
                throw new Error(`WARC record ${recordNumber} ${targetURI} has a WARC-Payload-Digest that does not match its payload`);
              }
            }
            next.set(value, payload);
          } else if (digest === null) {
            const labelled = payloadDigest(payload);
            next.set(labelled.slice("sha256:".length), payload);
            chunks.push(data.subarray(copied, headerEnd), encoder.encode(`\r\nWARC-Payload-Digest: ${labelled}`));
            copied = headerEnd;
          }
        }
        cursor = following;
      }
      verified = next;
      if (chunks.length === 0) return archive;
      chunks.push(data.subarray(copied));
      return concat(chunks);
    },
  };
}

function concat(chunks) {
  const length = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0);
  const output = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    output.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return output;
}

function buildWarcRecord(targetURI, response) {
  const headers = new Headers(response.headers);
  headers.delete("transfer-encoding");
  headers.set("content-length", String(response.body.byteLength));
  const statusText = STATUS_CODES[response.status] ?? "Status";
  let httpHead = `HTTP/1.1 ${response.status} ${statusText}\r\n`;
  for (const [name, value] of headerEntries(headers)) httpHead += `${name}: ${value}\r\n`;
  httpHead += "\r\n";
  const payload = concat([encoder.encode(httpHead), response.body]);
  const warcHead =
    `WARC/1.1\r\n` +
    `WARC-Type: response\r\n` +
    `WARC-Target-URI: ${targetURI}\r\n` +
    `WARC-Date: 2000-01-01T00:00:00Z\r\n` +
    `WARC-Record-ID: ${recordID(targetURI, payload)}\r\n` +
    `WARC-Payload-Digest: ${payloadDigest(response.body)}\r\n` +
    `Content-Type: application/http; msgtype=response\r\n` +
    `Content-Length: ${payload.byteLength}\r\n\r\n`;
  return concat([encoder.encode(warcHead), payload, encoder.encode("\r\n\r\n")]);
}

function findHeaderEnd(data, start) {
  for (let index = start; index + 3 < data.byteLength; index += 1) {
    if (data[index] === 13 && data[index + 1] === 10 && data[index + 2] === 13 && data[index + 3] === 10) {
      return index + 4;
    }
  }
  return -1;
}

function parseHeaderBlock(data, start, end) {
  const text = decoder.decode(data.subarray(start, end));
  const lines = text.replace(/\r\n\r\n$/, "").split("\r\n");
  const headers = new Headers();
  for (const line of lines.slice(1)) {
    const colon = line.indexOf(":");
    if (colon <= 0) continue;
    headers.append(line.slice(0, colon), line.slice(colon + 1).trim());
  }
  return { firstLine: lines[0], headers };
}

function parseWarcResponses(archive) {
  const responses = [];
  let cursor = 0;
  while (cursor < archive.byteLength) {
    while (archive[cursor] === 13 || archive[cursor] === 10) cursor += 1;
    if (cursor >= archive.byteLength) break;
    const recordStart = cursor;
    const headerEnd = findHeaderEnd(archive, cursor);
    if (headerEnd < 0) throw new Error("WARC header terminator not found");
    const warcHeader = parseHeaderBlock(archive, cursor, headerEnd);
    if (warcHeader.firstLine !== "WARC/1.1") throw new Error("WARC record must use WARC/1.1");
    const length = Number(warcHeader.headers.get("content-length"));
    if (!Number.isSafeInteger(length) || length < 0) throw new Error("invalid WARC Content-Length");
    const payloadEnd = headerEnd + length;
    if (payloadEnd > archive.byteLength) throw new Error("WARC payload exceeds archive length");
    if (warcHeader.headers.get("warc-type")?.toLowerCase() === "response") {
      const httpHeaderEnd = findHeaderEnd(archive, headerEnd);
      if (httpHeaderEnd < 0 || httpHeaderEnd > payloadEnd) throw new Error("HTTP header terminator not found");
      const httpHeader = parseHeaderBlock(archive, headerEnd, httpHeaderEnd);
      const status = Number(httpHeader.firstLine.split(/\s+/)[1]);
      const body = archive.slice(httpHeaderEnd, payloadEnd);
      const declared = Number(httpHeader.headers.get("content-length"));
      if (declared !== body.byteLength) throw new Error("HTTP Content-Length does not match body");
      responses.push({
        targetURI: warcHeader.headers.get("warc-target-uri") ?? "",
        response: { status, headers: httpHeader.headers, body },
        recordStart,
        recordEnd: Math.min(payloadEnd + 4, archive.byteLength),
      });
    }
    cursor = payloadEnd + 4;
  }
  return responses;
}

function removeWarcResponses(archive, targetURIs) {
  if (targetURIs.size === 0) return archive;
  const parts = [];
  let copied = 0;
  for (const record of parseWarcResponses(archive)) {
    if (!targetURIs.has(record.targetURI)) continue;
    parts.push(archive.subarray(copied, record.recordStart));
    copied = record.recordEnd;
  }
  parts.push(archive.subarray(copied));
  return concat(parts);
}

function isKindredParentResponse(response) {
  return response?.status === 200 && Boolean(response.headers.get("content-type")?.startsWith("text/html"));
}

async function existingDirectory(path, label) {
  try {
    if (!(await stat(path)).isDirectory()) throw new Error(`${label} ${path} is not a directory`);
    return path;
  } catch (error) {
    if (error?.code === "ENOENT" && label !== "content directory") return path;
    throw error;
  }
}

export async function createQIPRouter(options = {}) {
  const contentRoot = resolve(options.contentRoot ?? options.root ?? ".");
  await existingDirectory(contentRoot, "content directory");
  const recipesRoot = resolve(options.recipesRoot ?? join(contentRoot, "_recipes"));
  const componentsRoot = resolve(options.componentsRoot ?? join(contentRoot, "_components"));
  const elementsRoot = resolve(options.elementsRoot ?? join(contentRoot, "_elements"));
  const contentFilter = createContentFilter({ include: options.include, exclude: options.exclude });
  let generation;

  async function loadGeneration() {
    const [contextRoutes, components, elements, recipes] = await Promise.all([
      discoverContentRoutes(contentRoot),
      discoverAssetRoutes(componentsRoot, "", (path) => path.endsWith(".wasm")),
      discoverAssetRoutes(elementsRoot, "/elements", (path) => path.endsWith(".js")),
      createRecipeRuntime(recipesRoot),
    ]);
    // routes are the routes the content filter allows. contextRoutes are all
    // content routes: parent pages outside the filter still supply layouts.
    const routes = filterContentRoutes(contextRoutes, contentFilter);
    const current = { routes, contextRoutes, components, elements, recipes, derived: null };
    if (recipes.has("application/warc")) {
      const home = await baseResponseForGeneration("/", current, { parent: true });
      if (home) {
        const probe = buildWarcRecord("http://qip.local/", home);
        const rendered = await recipes.render("application/warc", probe);
        const basePaths = archivePaths(current);
        const known = new Set();
        for (const record of parseWarcResponses(rendered.bytes)) {
          const url = new URL(record.targetURI);
          if (url.host === "qip.local" && !url.search && !url.hash && !basePaths.includes(url.pathname)) {
            known.add(url.pathname);
          }
        }
        if (known.size) current.derived = { known, responses: new Map(), buildPromise: null, archive: null };
      }
    }
    return current;
  }

  generation = await loadGeneration();

  async function baseResponseForGeneration(pathname, current, { parent = false } = {}) {
    const component = current.components.get(pathname);
    if (component) return makeResponse(200, "application/wasm", await readFile(component.filePath), {}, false);

    const element = current.elements.get(pathname);
    if (element) {
      let body = new Uint8Array(await readFile(element.filePath));
      let type = "text/javascript";
      let renderedElement = false;
      if (current.recipes.has(type)) {
        const rendered = await current.recipes.render(type, body);
        body = rendered.bytes;
        type = rendered.contentType || type;
        renderedElement = true;
      }
      return makeResponse(200, type, body, {}, renderedElement);
    }

    const route = (parent ? current.contextRoutes : current.routes).get(pathname);
    if (!route) return null;
    let body = new Uint8Array(await readFile(route.filePath));
    let type = route.sourceType;
    if (!rawMarkdownRequest(pathname, route) && current.recipes.has(type)) {
      const rendered = await current.recipes.render(type, body);
      body = rendered.bytes;
      type = rendered.contentType || (route.sourceType === "text/markdown" ? "text/html" : type);
    }
    return makeResponse(200, type, body);
  }

  async function baseResponse(pathname, current = generation, resolveOptions) {
    return baseResponseForGeneration(pathname, current, resolveOptions);
  }

  // Lists the parent pages of paths that exist but that the content filter
  // leaves out. A whole-site WARC includes them while the WARC recipes run,
  // so their layouts apply as they do in dev. Keep in sync with
  // filteredParentPaths in router_kindred.go.
  function filteredParentPaths(current, paths) {
    if (current.routes === current.contextRoutes) return [];
    const out = new Set();
    for (const pathname of paths) {
      for (const parent of parentPaths(pathname)) {
        if (parent !== pathname && !current.routes.has(parent) && current.contextRoutes.has(parent)) out.add(parent);
      }
    }
    return [...out].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  }

  async function wholeSiteRecords(current, resolveBase) {
    const paths = archivePaths(current);
    const contextPaths = new Set(filteredParentPaths(current, paths));
    const records = [];
    const inputPaths = new Set();
    const contextURIs = new Set();
    let missing;
    for (const pathname of [...paths, ...contextPaths].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))) {
      const isContext = contextPaths.has(pathname);
      const response = await resolveBase(pathname, isContext ? { parent: true } : undefined);
      if (!response) {
        if (!isContext) missing ??= pathname;
        continue;
      }
      if (isContext) {
        if (!isKindredParentResponse(response)) continue;
        contextURIs.add(`http://qip.local${pathname}`);
      }
      inputPaths.add(pathname);
      records.push(buildWarcRecord(`http://qip.local${pathname}`, response));
    }
    return { archive: concat(records), inputPaths, contextURIs, missing };
  }

  function archivePaths(current) {
    const paths = new Set();
    for (const [pathname] of current.routes) paths.add(canonicalPath(pathname));
    for (const [pathname] of current.components) paths.add(pathname);
    for (const [pathname] of current.elements) paths.add(pathname);
    return [...paths].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  }

  function startDerivedBuild(current, resolveBase = (pathname, resolveOptions) => baseResponseForGeneration(pathname, current, resolveOptions)) {
    if (!current.derived || current.derived.buildPromise) return current.derived?.buildPromise;
    const startedAt = performance.now();
    current.derived.buildPromise = (async () => {
      const { archive, inputPaths, contextURIs, missing } = await wholeSiteRecords(current, resolveBase);
      if (missing) throw new Error(`full-site route ${missing} disappeared during build`);
      const rendered = await current.recipes.render("application/warc", archive);
      current.derived.archive = rendered.bytes;
      current.derived.contextURIs = contextURIs;
      for (const record of parseWarcResponses(rendered.bytes)) {
        const url = new URL(record.targetURI);
        if (url.host !== "qip.local" || url.search || url.hash || inputPaths.has(url.pathname)) continue;
        current.derived.responses.set(url.pathname, record.response);
      }
      return current.derived.responses;
    })();
    // Requests that do not wait for the build still start it, so record the
    // result here rather than leave a failure unhandled.
    current.derived.buildPromise.then(
      () => { current.derived.durationMs = performance.now() - startedAt; },
      (error) => {
        current.derived.durationMs = performance.now() - startedAt;
        current.derived.error = error;
      },
    );
    return current.derived.buildPromise;
  }

  // Handles a request that matched no other route. If the path is in a
  // directory that the full-site WARC writes to, such as /_og/, it waits for
  // the build and serves the result, so routes that home-page discovery did not
  // see still load. Otherwise it returns null and the caller sends its usual
  // 404. Keep in sync with resolveMissing in router_derived.go.
  async function resolveMissing(current, pathname) {
    if (!current.derived || !derivedCoversDirectory(current.derived, pathname)) return null;
    await startDerivedBuild(current).catch(() => {});
    const derived = current.derived;
    const response = derived.responses.get(pathname);
    if (response) return response;
    const ms = Math.round(derived.durationMs);
    const status = derived.error
      ? `full-site WARC build failed after ${ms}ms: ${derived.error.message}`
      : `full-site WARC build finished in ${ms}ms without producing ${pathname} (${derived.responses.size} derived routes)`;
    return makeResponse(404, "text/plain", `404 page not found\n\n${status}\n`);
  }

  function derivedCoversDirectory(derived, pathname) {
    const dir = posix.dirname(pathname);
    if (dir === "/") return false;
    for (const known of derived.known) {
      const knownDir = posix.dirname(known);
      if (knownDir === "/") continue;
      if (dir === knownDir || dir.startsWith(`${knownDir}/`)) return true;
    }
    return false;
  }

  async function kindredArchive(pathname, target, current, resolveBase = (path, resolveOptions) => baseResponse(path, current, resolveOptions)) {
    const records = [];
    const seen = new Set([pathname]);
    for (const parent of parentPaths(pathname)) {
      if (seen.has(parent)) continue;
      seen.add(parent);
      const response = await resolveBase(parent, { parent: true });
      if (response?.status === 200 && response.headers.get("content-type")?.startsWith("text/html")) {
        records.push(buildWarcRecord(`http://qip.local${parent}`, response));
      }
    }
    if (target.status === 200 && target.headers.get("content-type")?.startsWith("text/html")) {
      for (const sourcePath of htmlDependencyPaths(target.body, pathname)) {
        if (seen.has(sourcePath)) continue;
        seen.add(sourcePath);
        const response = await resolveBase(sourcePath);
        if (response?.status === 200 && !response.headers.get("content-type")?.startsWith("text/html")) {
          records.push(buildWarcRecord(`http://qip.local${sourcePath}`, response));
        }
      }
    }
    for (const [elementPath] of current.elements) {
      const filename = elementPath.split("/").at(-1);
      const name = filename.endsWith(".js") ? filename.slice(0, -3) : "";
      if (!isCustomElementName(name) || elementPath.slice("/elements/".length).includes("/")) continue;
      if (seen.has(elementPath)) continue;
      const response = await resolveBase(elementPath);
      if (response) records.push(buildWarcRecord(`http://qip.local${elementPath}`, response));
    }
    records.push(buildWarcRecord(`http://qip.local${pathname}`, target));
    return concat(records);
  }

  async function resolveRequest(method, requestTarget) {
    const current = generation;
    const url = new URL(requestTarget, "http://qip.local");
    if (method !== "GET" && method !== "HEAD") return makeResponse(405, "text/plain", "Method Not Allowed\n");
    const canonical = canonicalPath(url.pathname);
    if (canonical === null) return makeResponse(400, "text/plain", "Bad Request\n");
    if (canonical !== url.pathname) {
      const location = canonical + (url.search || "");
      return makeResponse(308, "text/plain", "", { location });
    }
    if (current.derived) {
      const build = startDerivedBuild(current);
      if (current.derived.known.has(canonical)) {
        await build;
        const derived = current.derived.responses.get(canonical);
        if (!derived) throw new Error(`full-site WARC did not produce discovered route ${canonical}`);
        return method === "HEAD" ? headResponse(derived) : derived;
      }
    }
    let response = await baseResponse(canonical, current);
    if (!response) {
      const missing = await resolveMissing(current, canonical);
      if (missing) return method === "HEAD" ? headResponse(missing) : missing;
      return makeResponse(404, "text/plain", "404 page not found\n");
    }
    if (current.recipes.has("application/warc") && !current.components.has(canonical) && !current.elements.has(canonical)) {
      const archive = await kindredArchive(canonical, response, current);
      const rendered = await current.recipes.render("application/warc", archive);
      const targetURI = `http://qip.local${canonical}`;
      const transformed = parseWarcResponses(rendered.bytes).find((item) => item.targetURI === targetURI);
      if (!transformed) throw new Error(`application/warc recipe removed ${targetURI}`);
      response = transformed.response;
    }
    return method === "HEAD" ? headResponse(response) : response;
  }

  // Reruns the application/warc recipes for each page with only that page's
  // Kindred Routes, as dev does, and throws if any page differs from its record
  // in the whole-site archive. A difference means a recipe read a record that
  // dev would not have given it. Keep in sync with checkKindredWARC in
  // router_check_kindred.go.
  async function checkKindredWarc(current, fullArchive, resolveBase, pageTimeoutMs) {
    const fullByURI = new Map();
    for (const record of parseWarcResponses(fullArchive)) {
      if (!fullByURI.has(record.targetURI)) fullByURI.set(record.targetURI, record.response);
    }
    const pagePaths = [...new Set([...current.routes.keys()].map(canonicalPath))]
      .filter((pathname) => !current.components.has(pathname) && !current.elements.has(pathname))
      .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
    const details = new Array(pagePaths.length).fill("");
    const pool = createKindredPool(
      current.recipes.stageSpecs("application/warc"),
      Math.min(availableParallelism(), pagePaths.length),
      pageTimeoutMs,
    );
    try {
      // Build archives on this thread a few pages ahead of the workers, so
      // they stay busy without every page's archive being held at once.
      let next = 0;
      const feed = async () => {
        while (next < pagePaths.length) {
          const index = next++;
          const pathname = pagePaths[index];
          const response = await resolveBase(pathname);
          if (!response) continue;
          const archive = await kindredArchive(pathname, response, current, resolveBase);
          const targetURI = `http://qip.local${pathname}`;
          const result = await pool.run(pathname, targetURI, archive);
          const want = fullByURI.get(targetURI);
          if (result.error !== undefined) details[index] = `WARC recipes failed with only Kindred Routes: ${result.error}`;
          else if (result.missing) details[index] = "WARC recipes with only Kindred Routes returned no record";
          else if (!want) details[index] = "whole-site WARC has no record for this page";
          else details[index] = describeResponseDifference(want, result.response);
        }
      };
      await Promise.all(Array.from({ length: pool.size * 2 }, feed));
    } finally {
      await pool.close();
    }
    const mismatches = details.flatMap((detail, index) => (detail ? [`${pagePaths[index]}: ${detail}`] : []));
    if (mismatches.length === 0) return;
    let message = `${mismatches.length} of ${pagePaths.length} pages differ when WARC recipes see only their Kindred Routes:`;
    for (const [index, mismatch] of mismatches.entries()) {
      if (index === maxReportedKindredMismatches) {
        message += `\n  … and ${mismatches.length - index} more`;
        break;
      }
      message += `\n  ${mismatch}`;
    }
    throw new Error(message);
  }

  const api = {
    contentRoot,
    recipesRoot,
    async reload() {
      const next = await loadGeneration();
      generation = next;
      return api;
    },
    async resolve(method, requestTarget) {
      return resolveRequest(method.toUpperCase(), requestTarget);
    },
    async get(requestTarget) {
      return resolveRequest("GET", requestTarget);
    },
    async head(requestTarget) {
      return resolveRequest("HEAD", requestTarget);
    },
    async kindred(requestTarget) {
      const current = generation;
      const url = new URL(requestTarget, "http://qip.local");
      const canonical = canonicalPath(url.pathname);
      if (canonical === null) throw new Error(`invalid request path ${requestTarget}`);
      const target = await baseResponseForGeneration(canonical, current);
      if (!target) throw new Error(`route not found: ${canonical}`);
      const entries = [];
      const seen = new Set([canonical]);
      for (const parent of parentPaths(canonical)) {
        if (seen.has(parent)) continue;
        seen.add(parent);
        const response = await baseResponseForGeneration(parent, current, { parent: true });
        if (response?.status === 200 && response.headers.get("content-type")?.startsWith("text/html")) {
          entries.push({ method: "GET", path: parent });
        }
      }
      if (target.status === 200 && target.headers.get("content-type")?.startsWith("text/html")) {
        for (const sourcePath of htmlDependencyPaths(target.body, canonical)) {
          if (seen.has(sourcePath)) continue;
          seen.add(sourcePath);
          const response = await baseResponseForGeneration(sourcePath, current);
          if (response?.status === 200 && !response.headers.get("content-type")?.startsWith("text/html")) {
            entries.push({ method: "GET", path: sourcePath });
          }
        }
      }
      return entries;
    },
    list() {
      const current = generation;
      const entries = new Map();
      for (const [pathname, route] of current.routes) {
        if (pathname.endsWith("/") && pathname !== "/") continue;
        const rendered = !rawMarkdownRequest(pathname, route) && current.recipes.has(route.sourceType);
        const type = rendered ? current.recipes.outputType(route.sourceType) || "text/html" : route.sourceType;
        entries.set(pathname, type);
      }
      for (const [pathname] of current.components) entries.set(pathname, "application/wasm");
      for (const [pathname] of current.elements) entries.set(pathname, current.recipes.outputType("text/javascript") || "text/javascript");
      return [...entries]
        .sort(([a], [b]) => a.localeCompare(b))
        .flatMap(([path, type]) => [
          { method: "GET", path, contentType: type },
          { method: "HEAD", path, contentType: type },
        ]);
    },
    async warc({ checkKindred = false, kindredPageTimeoutMs = defaultKindredPageTimeoutMs } = {}) {
      const current = generation;
      // The check reuses content recipe output from the export, so each route's
      // content recipes run once however many pages list it as a Kindred Route.
      // A filtered-out parent resolves from contextRoutes, so it caches under
      // its own key.
      const cached = new Map();
      const resolveBase = (pathname, resolveOptions) => {
        if (!checkKindred) return baseResponseForGeneration(pathname, current, resolveOptions);
        const key = `${resolveOptions?.parent ? "parent" : "route"} ${pathname}`;
        if (!cached.has(key)) cached.set(key, baseResponseForGeneration(pathname, current, resolveOptions));
        return cached.get(key);
      };
      let archive;
      let contextURIs;
      if (current.derived) {
        await startDerivedBuild(current, resolveBase);
        archive = current.derived.archive.slice();
        contextURIs = current.derived.contextURIs;
      } else {
        const records = await wholeSiteRecords(current, resolveBase);
        archive = records.archive;
        contextURIs = records.contextURIs;
        if (current.recipes.has("application/warc")) {
          archive = (await current.recipes.render("application/warc", archive)).bytes;
        }
      }
      if (checkKindred && current.recipes.has("application/warc")) {
        await checkKindredWarc(current, archive, resolveBase, kindredPageTimeoutMs);
      }
      return removeWarcResponses(archive, contextURIs);
    },
    async fetch(request) {
      const cacheControl = request.headers.get("cache-control")?.toLowerCase() ?? "";
      const pragma = request.headers.get("pragma")?.toLowerCase() ?? "";
      const accept = request.headers.get("accept")?.toLowerCase() ?? "";
      const hardReload = (cacheControl.includes("no-cache") || cacheControl.includes("max-age=0") || pragma.includes("no-cache")) &&
        accept.includes("text/html");
      if (hardReload) await api.reload();
      const url = new URL(request.url);
      const result = await resolveRequest(request.method, `${url.pathname}${url.search}`);
      return new Response(request.method === "HEAD" ? null : result.body, {
        status: result.status,
        headers: result.headers,
      });
    },
    async handler(request, response) {
      try {
        const cacheControl = String(request.headers?.["cache-control"] ?? "").toLowerCase();
        const pragma = String(request.headers?.pragma ?? "").toLowerCase();
        const accept = String(request.headers?.accept ?? "").toLowerCase();
        const hardReload = (cacheControl.includes("no-cache") || cacheControl.includes("max-age=0") || pragma.includes("no-cache")) &&
          accept.includes("text/html");
        if (hardReload) await api.reload();
        const result = await resolveRequest(request.method ?? "GET", request.url ?? "/");
        for (const [name, value] of result.headers) response.setHeader(name, value);
        if (!result.headers.has("content-length")) response.setHeader("content-length", result.body.byteLength);
        response.statusCode = result.status;
        response.end(request.method === "HEAD" ? undefined : result.body);
      } catch (error) {
        const body = encoder.encode(`${error.stack ?? error}\n`);
        response.statusCode = 500;
        response.setHeader("content-type", "text/plain; charset=utf-8");
        response.setHeader("content-length", body.byteLength);
        response.end(body);
      }
    },
    listen({ hostname = "127.0.0.1", port = 4000 } = {}) {
      const server = createServer((request, response) => api.handler(request, response));
      return new Promise((resolveListen, reject) => {
        server.once("error", reject);
        server.listen(port, hostname, () => {
          server.off("error", reject);
          resolveListen(server);
        });
      });
    },
  };
  return Object.freeze(api);
}

const maxReportedKindredMismatches = 20;
// Matches defaultRouteWARCTransformTimeout in the Go router.
const defaultKindredPageTimeoutMs = 5000;

// Returns "" when both responses are the same, otherwise a one-line
// description of the first difference.
function describeResponseDifference(want, got) {
  if (want.status !== got.status) {
    return `status ${want.status} in whole-site WARC, ${got.status} with only Kindred Routes`;
  }
  if (Buffer.compare(want.body, got.body) !== 0) {
    let offset = 0;
    while (offset < want.body.byteLength && offset < got.body.byteLength && want.body[offset] === got.body[offset]) offset += 1;
    return `body differs from byte ${offset}: whole-site WARC has ${bodySnippet(want.body, offset)}, ` +
      `only Kindred Routes has ${bodySnippet(got.body, offset)} (${want.body.byteLength} vs ${got.body.byteLength} bytes)`;
  }
  const names = [...new Set([...want.headers.keys(), ...got.headers.keys()])].sort();
  for (const name of names) {
    // Content-Length follows the body, which has already been compared.
    if (name === "content-length") continue;
    if (want.headers.get(name) !== got.headers.get(name)) {
      return `header ${name} is ${JSON.stringify(want.headers.get(name))} in whole-site WARC, ` +
        `${JSON.stringify(got.headers.get(name))} with only Kindred Routes`;
    }
  }
  return "";
}

function bodySnippet(body, offset) {
  if (offset >= body.byteLength) return "end of body";
  return JSON.stringify(decoder.decode(body.subarray(offset, offset + 48)));
}

function usage() {
  return `Usage: qip-router <command> <content-directory> [options]\n\n` +
    `Commands:\n` +
    `  dev   Serve the content directory\n` +
    `  get   Render one request path\n` +
    `  head     Print headers for one request path\n` +
    `  kindred  List Kindred Route context for one path\n` +
    `  list     List routed paths\n` +
    `  warc  Write the transformed site WARC\n\n` +
    `Options:\n` +
    `  --include <path>  Route only content under this path. Repeatable\n` +
    `  --exclude <path>  Do not route content under this path. Repeatable.\n` +
    `                    Routed content is the include paths, or everything,\n` +
    `                    minus the exclude paths. Either flag skips dot paths\n` +
    `                    unless an include path names them\n` +
    `  --check-kindred  With warc, rerun each page's WARC recipes with only its\n` +
    `                   Kindred Routes and fail if any output differs. A page\n` +
    `                   that takes over 5s stops the check and fails it\n\n` +
    `Documentation: https://qip.dev/docs/router\n`;
}

function parseCLI(argv) {
  const [command, contentRoot, ...rest] = argv;
  if (!command || !contentRoot) throw new Error(usage());
  const options = { contentRoot, include: [], exclude: [] };
  const positional = [];
  for (let index = 0; index < rest.length; index += 1) {
    const arg = rest[index];
    if (arg === "--recipes") options.recipesRoot = rest[++index];
    else if (arg === "--components") options.componentsRoot = rest[++index];
    else if (arg === "--elements") options.elementsRoot = rest[++index];
    else if (arg === "--host") options.hostname = rest[++index];
    else if (arg === "--port") options.port = Number(rest[++index]);
    else if (arg === "-o" || arg === "--output") options.output = rest[++index];
    else if (arg === "--check-kindred") options.checkKindred = true;
    else if (arg === "--include" || arg === "--exclude") {
      const value = rest[++index];
      if (value === undefined) throw new Error(`${arg} requires a path`);
      options[arg.slice(2)].push(value);
    }
    else if (arg.startsWith("-")) throw new Error(`unknown option ${arg}`);
    else positional.push(arg);
  }
  return { command, options, positional };
}

export async function main(argv = process.argv.slice(2)) {
  if (argv.length === 0 || argv[0] === "--help" || argv[0] === "-h" || argv[0] === "help") {
    console.log(usage());
    return;
  }
  const { command, options, positional } = parseCLI(argv);
  const router = await createQIPRouter(options);
  if (command === "dev") {
    const server = await router.listen({ hostname: options.hostname, port: options.port });
    const address = server.address();
    console.log(`qip-router: serving ${router.contentRoot} at http://${address.address}:${address.port}`);
    return;
  }
  if (command === "warc") {
    const archive = await router.warc({ checkKindred: options.checkKindred });
    if (!options.output || options.output === "-") process.stdout.write(archive);
    else await writeFile(options.output, archive);
    return;
  }
  if (command === "kindred") {
    const requestPath = positional[0];
    if (!requestPath) throw new Error("kindred requires a request path");
    for (const entry of await router.kindred(requestPath)) console.log(`${entry.method} ${entry.path}`);
    return;
  }
  if (command === "list") {
    for (const entry of router.list()) console.log(`${entry.method}\t${entry.path}\t${entry.contentType}`);
    return;
  }
  if (command === "get" || command === "head") {
    const requestPath = positional[0];
    if (!requestPath) throw new Error(`${command} requires a request path`);
    const response = await router.resolve(command.toUpperCase(), requestPath);
    if (command === "head") {
      console.log(`HTTP/1.1 ${response.status} ${STATUS_CODES[response.status] ?? "Status"}`);
      for (const [name, value] of response.headers) console.log(`${name}: ${value}`);
    } else {
      process.stdout.write(response.body);
    }
    if (response.status >= 400) process.exitCode = 1;
    return;
  }
  throw new Error(`unknown command ${command}\n\n${usage()}`);
}

const invokedPath = process.argv[1] ? realpathSync(resolve(process.argv[1])) : "";
const modulePath = realpathSync(fileURLToPath(import.meta.url));
if (!isMainThread && workerData?.qipRouterKindredWorker) {
  runKindredWorker(workerData);
} else if (isMainThread && invokedPath === modulePath) {
  main().catch((error) => {
    console.error(error.message ?? error);
    process.exitCode = 1;
  });
}
