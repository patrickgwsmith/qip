#!/usr/bin/env node

import { createHash } from "node:crypto";
import { createServer, STATUS_CODES } from "node:http";
import { realpathSync } from "node:fs";
import { readFile, readdir, realpath, stat, writeFile } from "node:fs/promises";
import { extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

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
  const instance = await WebAssembly.instantiate(module);
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
      const result = previous.then(() => {
        let output = bytes(input);
        let type = sourceType;
        // Hash payloads natively so recipes can read WARC-Payload-Digest instead
        // of hashing in wasm, and so a recipe that leaves a stale digest is named.
        const digester = sourceType === "application/warc" ? createPayloadDigester() : null;
        if (digester) output = digester.apply(output);
        for (const stage of chain.stages) {
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
      });
      queues.set(sourceType, result.catch(() => {}));
      return result;
    },
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
      });
    }
    cursor = payloadEnd + 4;
  }
  return responses;
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
  let generation;

  async function loadGeneration() {
    const [routes, components, elements, recipes] = await Promise.all([
      discoverContentRoutes(contentRoot),
      discoverAssetRoutes(componentsRoot, "", (path) => path.endsWith(".wasm")),
      discoverAssetRoutes(elementsRoot, "/elements", (path) => path.endsWith(".js")),
      createRecipeRuntime(recipesRoot),
    ]);
    const current = { routes, components, elements, recipes, derived: null };
    if (recipes.has("application/warc")) {
      const home = await baseResponseForGeneration("/", current);
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

  async function baseResponseForGeneration(pathname, current) {
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

    const route = current.routes.get(pathname);
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

  async function baseResponse(pathname, current = generation) {
    return baseResponseForGeneration(pathname, current);
  }

  function archivePaths(current) {
    const paths = new Set();
    for (const [pathname] of current.routes) paths.add(canonicalPath(pathname));
    for (const [pathname] of current.components) paths.add(pathname);
    for (const [pathname] of current.elements) paths.add(pathname);
    return [...paths].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  }

  function startDerivedBuild(current) {
    if (!current.derived || current.derived.buildPromise) return current.derived?.buildPromise;
    current.derived.buildPromise = (async () => {
      const records = [];
      const inputPaths = archivePaths(current);
      for (const pathname of inputPaths) {
        const response = await baseResponseForGeneration(pathname, current);
        if (!response) throw new Error(`full-site route ${pathname} disappeared during build`);
        records.push(buildWarcRecord(`http://qip.local${pathname}`, response));
      }
      const rendered = await current.recipes.render("application/warc", concat(records));
      current.derived.archive = rendered.bytes;
      const inputSet = new Set(inputPaths);
      for (const record of parseWarcResponses(rendered.bytes)) {
        const url = new URL(record.targetURI);
        if (url.host !== "qip.local" || url.search || url.hash || inputSet.has(url.pathname)) continue;
        current.derived.responses.set(url.pathname, record.response);
      }
      return current.derived.responses;
    })();
    return current.derived.buildPromise;
  }

  async function kindredArchive(pathname, target, current) {
    const records = [];
    const seen = new Set([pathname]);
    for (const parent of parentPaths(pathname)) {
      if (seen.has(parent)) continue;
      seen.add(parent);
      const response = await baseResponse(parent, current);
      if (response?.status === 200 && response.headers.get("content-type")?.startsWith("text/html")) {
        records.push(buildWarcRecord(`http://qip.local${parent}`, response));
      }
    }
    if (target.status === 200 && target.headers.get("content-type")?.startsWith("text/html")) {
      for (const sourcePath of htmlDependencyPaths(target.body, pathname)) {
        if (seen.has(sourcePath)) continue;
        seen.add(sourcePath);
        const response = await baseResponse(sourcePath, current);
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
      const response = await baseResponse(elementPath, current);
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
    if (!response) return makeResponse(404, "text/plain", "404 page not found\n");
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
        const response = await baseResponseForGeneration(parent, current);
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
    async warc() {
      const current = generation;
      if (current.derived) {
        await startDerivedBuild(current);
        return current.derived.archive.slice();
      }
      const records = [];
      for (const pathname of archivePaths(current)) {
        const response = await baseResponseForGeneration(pathname, current);
        if (response) records.push(buildWarcRecord(`http://qip.local${pathname}`, response));
      }
      const archive = concat(records);
      if (!current.recipes.has("application/warc")) return archive;
      return (await current.recipes.render("application/warc", archive)).bytes;
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

function usage() {
  return `Usage: qip-router <command> <content-directory> [options]\n\n` +
    `Commands:\n` +
    `  dev   Serve the content directory\n` +
    `  get   Render one request path\n` +
    `  head     Print headers for one request path\n` +
    `  kindred  List Kindred Route context for one path\n` +
    `  list     List routed paths\n` +
    `  warc  Write the transformed site WARC\n\n` +
    `Documentation: https://qip.dev/docs/router\n`;
}

function parseCLI(argv) {
  const [command, contentRoot, ...rest] = argv;
  if (!command || !contentRoot) throw new Error(usage());
  const options = { contentRoot };
  const positional = [];
  for (let index = 0; index < rest.length; index += 1) {
    const arg = rest[index];
    if (arg === "--recipes") options.recipesRoot = rest[++index];
    else if (arg === "--components") options.componentsRoot = rest[++index];
    else if (arg === "--elements") options.elementsRoot = rest[++index];
    else if (arg === "--host") options.hostname = rest[++index];
    else if (arg === "--port") options.port = Number(rest[++index]);
    else if (arg === "-o" || arg === "--output") options.output = rest[++index];
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
    const archive = await router.warc();
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
if (invokedPath === modulePath) {
  main().catch((error) => {
    console.error(error.message ?? error);
    process.exitCode = 1;
  });
}
