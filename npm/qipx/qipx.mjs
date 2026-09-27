#!/usr/bin/env node

const runningInNode = typeof process !== "undefined" && process.versions?.node;
const [nodeCrypto, nodeFS, nodeOS, nodePath, nodeZlib] = runningInNode
  ? await Promise.all([
      import("node:crypto"),
      import("node:fs/promises"),
      import("node:os"),
      import("node:path"),
      import("node:zlib"),
    ])
  : [{}, {}, {}, {}, {}];
const { createHash, randomUUID } = nodeCrypto;
const { link, mkdir, open, readFile, readdir, realpath, stat, unlink, writeFile } = nodeFS;
const { arch, cpus, platform } = nodeOS;
const { basename, dirname, isAbsolute, join, relative } = nodePath;
const { gzipSync } = nodeZlib;

const decoder = new TextDecoder("utf-8", { fatal: true });
const encoder = new TextEncoder();

function multipartHelp(command) {
  const lines = [
    "Multipart fields:",
    "  -F name=value       UTF-8 text field",
    "  -F name=@path       Exact file bytes with the basename as filename",
    "  -F 'name=<path'     Exact file bytes as a regular field, without filename",
    "@path sends Content-Type: application/octet-stream; <path omits that part header.",
  ];
  if (command === "tui") {
    lines.push("  -F name=@- and -F 'name=<-' are unavailable: stdin carries terminal keys.");
  } else {
    lines.push("  -F name=@-          Stdin bytes as a file field with filename \"-\"");
    lines.push("  -F 'name=<-'        Stdin bytes as a regular field without filename");
    lines.push("Only one field may read stdin.");
  }
  lines.push("Quote arguments containing < in a shell.");
  if (command === "run") lines.push("Dry run plans form files without reading file contents or stdin.");
  lines.push("", "Examples:");
  if (command === "tui") {
    lines.push("  qipx tui tui/calendar-gregorian.wasm");
    lines.push("  qipx tui -F 'component=<text/wc.wasm' tui/qipdb.wasm");
  } else if (command === "bench") {
    lines.push("  qipx bench -F 'data=<input.txt' bytes/identity.wasm");
    lines.push("  printf hello | qipx bench -F 'data=<-' bytes/identity.wasm");
  } else {
    lines.push("  qipx run -F mode=step -F component=@text/wc.wasm bytes/identity.wasm");
    lines.push("  qipx run -F 'data=<input.txt' bytes/identity.wasm");
    lines.push("  printf hello | qipx run -F 'data=<-' bytes/identity.wasm");
  }
  return `${lines.join("\n")}\n\n`;
}

function usage() {
  return `Usage: qipx [host ...] run [options] <component.wasm> [component2.wasm ...]\n` +
    `       qipx [host ...] dry run [options] <component.wasm> [component2.wasm ...]\n` +
    `       qipx [host ...] tui [options] <interactive.wasm> [content.wasm ...]\n` +
    `       qipx [host ...] comply [options] <file-or-dir> [...]\n` +
    `       qipx [host ...] bench (-i <input> | -F <name=value>) [options] <component.wasm> [...]\n\n` +
    `Hosts:\n` +
    `  Hosts are dotted DNS names with optional ports. Missing relative .wasm files,\n` +
    `  including @path and <path form fields, use HTTPS in host order and are saved.\n\n` +
    `Options:\n` +
    `  -i, --input <path>              Read input from a file instead of stdin\n` +
    `  -F, --form <name=value>         Add multipart input (repeatable; @path, <path, @-, or <-)\n` +
    `  -o, --output <path>             Write output to a file instead of stdout\n` +
    `  --max-memory <bytes>            Reject modules whose declared memory exceeds bytes\n` +
    `  --capacities-must-fit           Reject stages whose max output cannot fit next input\n` +
    `  -u, --uniform <name=value>      Set a uniform on the preceding component (repeatable)\n` +
    `  dry run                         Validate the pipeline without reading input or rendering\n` +
    `  -h, --help                      Show this help\n\n` +
    multipartHelp("run") +
    `Uniforms:\n` +
    `  qipx run component.wasm -u width=640 -u height=480\n` +
    `  i32 uniforms are treated as unsigned values; use i64 for signed integers.\n\n` +
    `Inputless generators:\n` +
    `  A first-stage generator omits input_ptr and its input-capacity getter. qipx calls render(0).\n` +
    `  With neither -i nor -F, qipx uses empty input when stdin is a terminal.\n\n` +
    `Documentation: https://qip.dev/docs/content-component\n`;
}

function tuiUsage() {
  return `Usage: qipx [host ...] tui [options] <interactive.wasm> [content.wasm ...]\n\n` +
    `Input:\n` +
    `  -i, --input <path>              Read initial input from a file\n` +
    `  -F, --form <name=value>         Construct multipart input (repeatable; @path or <path)\n\n` +
    multipartHelp("tui") +
    `Execution:\n` +
    `  -u, --uniform <name=value>      Set a uniform on the preceding component\n` +
    `  --max-memory <bytes>            Reject modules whose declared memory exceeds bytes\n` +
    `  --capacities-must-fit           Check capacity between Content stages\n\n` +
    `The first component must be Interactive. Later components transform each\n` +
    `frame as ordinary Content stages; the final output must be UTF-8 text.\n` +
    `With hosts, missing safe relative .wasm files used by -F are downloaded.\n` +
    `Terminal stdin carries key events, so -i -, -F name=@-, and -F name=<- are unavailable.\n`;
}

const downloadByteLimit = 16 * 1024 * 1024;
const downloadTimeoutMilliseconds = 30_000;
const redirectLimit = 2;
const knownCommands = new Set(["run", "dry", "dry-run", "tui", "bench", "comply"]);

function displayText(value) {
  // Keep untrusted paths and labels from changing terminal display.
  return Array.from(String(value), (character) =>
    /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u.test(character)
      ? `\\u{${character.codePointAt(0).toString(16)}}`
      : character,
  ).join("");
}

function parseHost(value) {
  if (typeof value !== "string" || value.length === 0 || value.length > 259) {
    throw new Error(`invalid host ${JSON.stringify(value)}`);
  }
  const match = /^([A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+)(?::([0-9]{1,5}))?$/.exec(value);
  if (!match || match[1].length > 253) throw new Error(`invalid host ${JSON.stringify(value)}; use a dotted DNS name with an optional port`);
  if (!/[A-Za-z]/.test(match[1].split(".").at(-1))) throw new Error(`invalid host ${JSON.stringify(value)}; IP addresses are not supported`);
  if (match[2] !== undefined) {
    const port = Number(match[2]);
    if (port < 1 || port > 65535) throw new Error(`invalid host port in ${JSON.stringify(value)}`);
  }
  const authority = `${match[1].toLowerCase()}${match[2] === undefined ? "" : `:${Number(match[2])}`}`;
  return Object.freeze({ authority, origin: `https://${authority}` });
}

function parseInvocation(argv) {
  const commandIndex = argv.findIndex((arg) => knownCommands.has(arg));
  if (commandIndex < 0) throw new Error("qipx requires a subcommand: run, dry run, tui, bench, or comply");
  const hosts = argv.slice(0, commandIndex).map(parseHost);
  const command = argv[commandIndex];
  if (command === "dry") {
    if (argv[commandIndex + 1] !== "run") throw new Error("qipx dry must be followed by run");
    return { command: "dry-run", hosts, args: argv.slice(commandIndex + 2) };
  }
  return { command, hosts, args: argv.slice(commandIndex + 1) };
}

function remotelyEligiblePath(filePath) {
  if (typeof filePath !== "string" || !filePath.endsWith(".wasm")) return false;
  if (!/^[\x20-\x7e]+$/.test(filePath)) return false;
  if (isAbsolute(filePath) || filePath.includes(":") || filePath.includes("\\")) return false;
  if (filePath.includes("?") || filePath.includes("#")) return false;
  const segments = filePath.split("/");
  return segments.length > 0 && segments.every((segment) => segment !== "" && segment !== "." && segment !== "..");
}

function sourcePlan(filePath, hosts) {
  const sources = [{ kind: "local", path: filePath }];
  if (remotelyEligiblePath(filePath)) {
    const requestPath = filePath.split("/").map(encodeURIComponent).join("/");
    for (const host of hosts) sources.push({ kind: "https", url: `${host.origin}/${requestPath}` });
  }
  return Object.freeze({ filePath, sources: Object.freeze(sources.map(Object.freeze)) });
}

function missingFileError(error) {
  return error?.code === "ENOENT" || error?.code === "ENOTDIR";
}

async function observeLocalSource(plan) {
  try {
    return { state: "selected", bytes: await readFile(plan.filePath) };
  } catch (error) {
    if (missingFileError(error)) return { state: "missing" };
    throw error;
  }
}

async function readDownload(response, url) {
  const declaredLength = response.headers.get("content-length");
  if (declaredLength !== null && /^\d+$/.test(declaredLength) && Number(declaredLength) > downloadByteLimit) {
    throw new Error(`${url} exceeds the ${downloadByteLimit}-byte download limit`);
  }
  if (!response.body) return new Uint8Array();
  const chunks = [];
  let length = 0;
  const reader = response.body.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > downloadByteLimit) throw new Error(`${url} exceeds the ${downloadByteLimit}-byte download limit`);
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const out = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

async function fetchSource(source) {
  let response;
  let url = source.url;
  const sourceOrigin = new URL(source.url).origin;
  const signal = AbortSignal.timeout(downloadTimeoutMilliseconds);
  for (let redirects = 0; redirects <= redirectLimit; redirects += 1) {
    try {
      response = await fetch(url, { redirect: "manual", signal });
    } catch (error) {
      return { unavailable: true, reason: error.message ?? String(error) };
    }
    if (response.status < 300 || response.status > 399) break;
    if (response.body) await response.body.cancel();
    if (redirects === redirectLimit) {
      throw new Error(`${source.url} exceeded the ${redirectLimit}-redirect limit`);
    }
    const location = response.headers.get("location");
    if (!location) throw new Error(`${url} returned HTTP ${response.status} without Location`);
    const next = new URL(location, url);
    if (next.protocol !== "https:" || next.origin !== sourceOrigin || next.username || next.password) {
      throw new Error(`${url} redirected outside its HTTPS origin`);
    }
    url = next.href;
  }
  if (response.status === 404 || response.status === 410 || response.status >= 500) {
    return { unavailable: true, reason: `HTTP ${response.status}` };
  }
  if (response.status !== 200) throw new Error(`${url} returned HTTP ${response.status}`);
  return { unavailable: false, bytes: await readDownload(response, url), url };
}

function pathIsInside(root, child) {
  const difference = relative(root, child);
  return difference === "" || (!difference.startsWith(`..${process.platform === "win32" ? "\\" : "/"}`) && difference !== ".." && !isAbsolute(difference));
}

async function vendorDownload(filePath, wasm) {
  const root = await realpath(".");
  const parent = dirname(filePath);
  let existingAncestor = parent;
  while (true) {
    try {
      const resolvedAncestor = await realpath(existingAncestor);
      if (!pathIsInside(root, resolvedAncestor)) throw new Error(`refusing to vendor outside the current directory: ${filePath}`);
      break;
    } catch (error) {
      if (!missingFileError(error)) throw error;
      const next = dirname(existingAncestor);
      if (next === existingAncestor) throw error;
      existingAncestor = next;
    }
  }
  await mkdir(parent, { recursive: true });
  const resolvedParent = await realpath(parent);
  if (!pathIsInside(root, resolvedParent)) throw new Error(`refusing to vendor outside the current directory: ${filePath}`);
  const temporaryPath = join(parent, `.${basename(filePath)}.qipx-${process.pid}-${randomUUID()}.tmp`);
  let output = await open(temporaryPath, "wx");
  try {
    await output.writeFile(wasm);
    await output.close();
    output = null;
    try {
      await link(temporaryPath, filePath);
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
    }
  } finally {
    if (output) await output.close();
    try {
      await unlink(temporaryPath);
    } catch (error) {
      if (!missingFileError(error)) throw error;
    }
  }
  return readFile(filePath);
}

async function resolveSource(plan, validate) {
  const local = await observeLocalSource(plan);
  if (local.state === "selected") {
    validate(local.bytes, plan.filePath);
    return local.bytes;
  }
  const unavailable = [];
  for (const source of plan.sources.slice(1)) {
    const fetched = await fetchSource(source);
    if (fetched.unavailable) {
      unavailable.push(`${source.url}: ${fetched.reason}`);
      continue;
    }
    validate(fetched.bytes, fetched.url);
    const installed = await vendorDownload(plan.filePath, fetched.bytes);
    validate(installed, plan.filePath);
    return installed;
  }
  if (plan.sources.length === 1 && !remotelyEligiblePath(plan.filePath)) {
    throw new Error(`${plan.filePath} is missing; only missing relative paths ending in .wasm can be downloaded`);
  }
  const detail = unavailable.length === 0 ? "" : ` (${unavailable.join("; ")})`;
  throw new Error(`${plan.filePath} is unavailable from every source${detail}`);
}

const canonicalWasmHeader = Uint8Array.of(0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00);

function wasmHeaderMustBeValid(candidate, label) {
  const data = bytes(candidate);
  if (data.byteLength < canonicalWasmHeader.byteLength) throw new Error(`${label} does not have a WebAssembly 1.0 header`);
  for (let index = 0; index < canonicalWasmHeader.byteLength; index += 1) {
    if (data[index] !== canonicalWasmHeader[index]) throw new Error(`${label} does not have a WebAssembly 1.0 header`);
  }
}

async function loadMultipartFile(filePath, plan) {
  try {
    return await readFile(filePath);
  } catch (error) {
    if (!missingFileError(error) || plan.sources.length === 1) throw error;
  }
  return resolveSource(plan, wasmHeaderMustBeValid);
}

function benchUsage() {
  return `Usage: qipx [host ...] bench (-i <input> | -F, --form <name=value>) [options] <component.wasm> [...]\n\n` +
    `Options:\n` +
    `  -i, --input <path>              Read benchmark input from a file ('-' for stdin)\n` +
    `  -F, --form <name=value>         Add multipart text or file input (repeatable; @path or @-)\n` +
    `  -r, --runs <n>                  Measure exactly n runs per component\n` +
    `  --benchtime <duration>          Target measured time per component (default: 3s)\n` +
    `  --warmup <n>                    Warmup runs per component (default: 10)\n` +
    `  --max-memory <bytes>            Reject modules whose declared memory exceeds bytes\n` +
    `  -u, --uniform <name=value>      Set a uniform on the preceding component (repeatable)\n` +
    `  -h, --help                      Show this help\n\n` +
    multipartHelp("bench") +
    `Components are measured one at a time on reused runtime instances.\n` +
    `With hosts, missing safe relative .wasm files used by -F are downloaded.\n` +
    `With --expose-gc, qipx collects after each component's warmup.\n` +
    `Every output must match the first component byte for byte.\n`;
}

function complyUsage() {
  return `Usage: qipx [host ...] comply [options] <file-or-dir> [...]\n\n` +
    `Options:\n` +
    `  --with <compliance.wasm>        Run a Compliance oracle (repeatable)\n` +
    `  --seed <n>                      Call uniform_set_seed(u32) on each oracle\n` +
    `  --max-memory <bytes>            Reject implementation memory above bytes\n` +
    `  -h, --help                      Show this help\n\n` +
    `Checks QIP Content ABI compliance and the Strict Wasm Profile subset.\n` +
    `Documentation: https://qip.dev/docs/comply\n`;
}

function bytes(value) {
  if (value instanceof Uint8Array) return value;
  if (typeof value === "string") return encoder.encode(value);
  return new Uint8Array(value);
}

function exportedValue(exports, name, label) {
  const item = exports[name];
  if (typeof item !== "function") throw new Error(`${label} must export ${name}() -> i32`);
  return Number(item()) >>> 0;
}

function requireFunction(exports, name, label) {
  const item = exports[name];
  if (typeof item !== "function") throw new Error(`${label} must export ${name}`);
  return item;
}

function declaredType(exports, prefix, label) {
  const pointer = exports[`${prefix}_content_type_ptr`];
  const size = exports[`${prefix}_content_type_size`];
  if (pointer === undefined && size === undefined) return "";
  if (pointer === undefined || size === undefined) throw new Error(`${label} has incomplete ${prefix} content-type exports`);
  const start = exportedValue(exports, `${prefix}_content_type_ptr`, label);
  const length = exportedValue(exports, `${prefix}_content_type_size`, label);
  const type = decoder.decode(new Uint8Array(exports.memory.buffer, start, length));
  validateContentType(type, `${label} ${prefix} content type`);
  return type;
}

// A lowercase media type, optionally followed by ";name=value" parameters with no whitespace
// anywhere. Parameter names are case-insensitive; values are case-sensitive and kept
// verbatim, as in "image/ktx2;vkFormat=R32G32B32A32_SFLOAT;colorPrimaries=BT709;transferFunction=LINEAR".
// multipart/form-data is valid only in its canonical placeholder-boundary form.
function validateContentType(type, label = "content type") {
  if (type === "multipart/form-data;boundary=uuid-00000000-0000-0000-0000-000000000000") return;
  if (
    !String(type).startsWith("multipart/form-data") &&
    /^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+(?:;[A-Za-z0-9!#$&^_.+-]+=[^\s;"=]+)*$/.test(type)
  ) return;
  throw new Error(`invalid ${label}: ${type}`);
}

// Parameters are keyed by lowercase name; `names` keeps each name's declared spelling.
function parseContentType(value) {
  const segments = String(value ?? "").split(";");
  const mediaType = segments[0].trim().toLowerCase();
  const params = new Map();
  const names = new Map();
  for (const segment of segments.slice(1)) {
    const eq = segment.indexOf("=");
    if (eq === -1) continue;
    const declaredName = segment.slice(0, eq).trim();
    const name = declaredName.toLowerCase();
    if (name === "") continue;
    params.set(name, segment.slice(eq + 1).trim());
    names.set(name, declaredName);
  }
  return { mediaType, params, names };
}

// Whether content of type `incoming` satisfies a declared `expected` type: the media types
// must match, and any parameter both declare must have the same value. A parameter only
// one side declares is not required, so bare declarations keep matching.
function contentTypeAccepts(expected, incoming) {
  return contentTypeMismatch(expected, incoming) === "";
}

// Renders the incoming type for an "expected A, got B" message: only its parameters when it
// shares the media type with `expected`, since repeating the media type adds nothing.
function incomingForMessage(expected, incoming) {
  if (parseContentType(expected).mediaType !== parseContentType(incoming).mediaType) return incoming;
  const cut = String(incoming).indexOf(";");
  return cut === -1 ? incoming : String(incoming).slice(cut + 1).trim();
}

// Why `incoming` does not satisfy `expected`, or "" when it does: the media types differ,
// or every parameter both declare with different values. Shared wording across QIP hosts.
function contentTypeMismatch(expected, incoming) {
  const want = parseContentType(expected);
  const got = parseContentType(incoming);
  if (want.mediaType !== got.mediaType) return `media type expected ${want.mediaType} got ${got.mediaType}`;
  const details = [];
  for (const [name, value] of want.params) {
    if (got.params.has(name) && got.params.get(name) !== value) {
      const shown = want.names.get(name);
      details.push(`${shown} expected ${value} got ${got.params.get(name)}`);
    }
  }
  return details.join("; ");
}

function optionalContentType(type, label = "contentType") {
  if (type === undefined) return undefined;
  validateContentType(type, label);
  return type;
}

class ContentType {
  constructor(encoding, optionalMIMEType) {
    this.encoding = encoding;
    this.mediaType = optionalContentType(optionalMIMEType, "mediaType");
    Object.freeze(this);
  }
}

export function contentTypeUTF8(optionalMIMEType) {
  return new ContentType("utf8", optionalMIMEType);
}

export function contentTypeBytes(optionalMIMEType) {
  return new ContentType("bytes", optionalMIMEType);
}

const contentComponentContractBrand = Symbol("qipx.contentComponentContract");

class ContentComponentContractSpec {
  constructor(options = {}) {
    this[contentComponentContractBrand] = true;
    this.label = options.label;
    this.maxMemory = options.maxMemory === undefined ? undefined : parseMaxMemory(options.maxMemory);
    this.inputType = options.inputType;
    this.outputType = options.outputType;
    if (this.inputType !== undefined && !isContentType(this.inputType)) throw new Error("inputType must be contentTypeUTF8(...) or contentTypeBytes(...)");
    if (this.outputType !== undefined && !isContentType(this.outputType)) throw new Error("outputType must be contentTypeUTF8(...) or contentTypeBytes(...)");
    Object.freeze(this);
  }
}

export function newContentComponentContract(options = {}) {
  return new ContentComponentContractSpec(options);
}

function componentContractOptions(options = {}) {
  return options?.[contentComponentContractBrand] ? options : options;
}

function isContentType(value) {
  return value instanceof ContentType;
}

function describeContentType(type) {
  return `${type.encoding}${type.mediaType ? ` ${type.mediaType}` : ""}`;
}

function assertComponentContract(component, field, expected) {
  if (expected === undefined) return;
  if (!isContentType(expected)) throw new Error(`${field} must be contentTypeUTF8(...) or contentTypeBytes(...)`);
  const actual = component[field];
  if (actual.encoding !== expected.encoding || (expected.mediaType !== undefined && !contentTypeAccepts(expected.mediaType, actual.mediaType))) {
    throw new Error(`${component.label} ${field} contract mismatch: expected ${describeContentType(expected)}, got ${describeContentType(actual)}`);
  }
}

function validUniformKey(key) {
  return key.length >= 1 && key.length <= 63 && /^[a-z][a-z0-9_]*$/.test(key) && !key.endsWith("_") && !key.includes("__");
}

function parseUniformValue(value) {
  const trimmed = String(value).trim();
  if (/^[-+]?0x[0-9a-f]+$/i.test(trimmed)) return Number.parseInt(trimmed, 16);
  if (/^[-+]?\d+$/.test(trimmed)) return Number.parseInt(trimmed, 10);
  if (/^[-+]?(?:\d+\.\d*|\d*\.\d+|\d+)(?:e[-+]?\d+)?$/i.test(trimmed)) return Number(trimmed);
  throw new Error(`uniform value ${JSON.stringify(value)} is not a number`);
}

function validateUniforms(stage) {
  for (const [key, rawValue] of stage.uniforms ?? []) {
    if (!validUniformKey(key)) throw new Error(`${stage.label} has invalid uniform key ${key}`);
    parseUniformValue(rawValue);
    const setterName = `uniform_set_${key}`;
    const setter = stage.component.exports[setterName];
    if (typeof setter !== "function") throw new Error(`${stage.label} does not export ${setterName}`);
  }
}

function applyUniforms(stage) {
  validateUniforms(stage);
  for (const [key, rawValue] of stage.uniforms ?? []) {
    stage.component.exports[`uniform_set_${key}`](parseUniformValue(rawValue));
  }
}

// Module inspection reads plain Numbers: every LEB128 value the checks decode (section
// sizes, counts, indices, page limits) fits in 53 bits. readULEB leaves the decoded value in
// lebValue and returns the offset after it; skipLEB steps over values whose magnitude does not
// matter. Both throw on truncation so malformed input fails here rather than in the engine.
let lebValue = 0;

function readULEB(bytes, offset) {
  let value = 0;
  let scale = 1;
  let byte;
  do {
    byte = bytes[offset++];
    if (byte === undefined) throw new Error("truncated Wasm LEB128 integer");
    value += (byte & 0x7f) * scale;
    scale *= 128;
  } while (byte & 0x80);
  lebValue = value;
  return offset;
}

function skipLEB(bytes, offset) {
  let byte;
  do {
    byte = bytes[offset++];
    if (byte === undefined) throw new Error("truncated Wasm LEB128 integer");
  } while (byte & 0x80);
  return offset;
}

function readName(bytes, offset) {
  const start = readULEB(bytes, offset);
  const end = start + lebValue;
  if (end > bytes.length) throw new Error("truncated Wasm name");
  return { value: decoder.decode(bytes.subarray(start, end)), offset: end };
}

function readLimits(bytes, offset, label) {
  const flags = bytes[offset++];
  if (flags === undefined) throw new Error(`${label} has truncated limits`);
  offset = readULEB(bytes, offset);
  const minimum = lebValue;
  let maximum = null;
  if ((flags & 0x01) !== 0) {
    offset = readULEB(bytes, offset);
    maximum = lebValue;
  }
  return { flags, minimum, maximum, offset };
}

function validateMemoryLimits(limits, label, maxMemory) {
  if ((limits.flags & 0x02) !== 0) throw new Error(`${label} declares shared memory, which is outside the Strict Wasm Profile`);
  if (limits.maximum === null) throw new Error(`${label} declares memory without a maximum, which is outside the Strict Wasm Profile`);
  if (maxMemory === undefined || maxMemory === null) return;
  const cap = BigInt(maxMemory);
  const minBytes = BigInt(limits.minimum) * 65536n;
  if (minBytes > cap) throw new Error(`${label} declares minimum memory ${minBytes} bytes, exceeding --max-memory ${cap}`);
  const maxBytes = BigInt(limits.maximum) * 65536n;
  if (maxBytes > cap) throw new Error(`${label} declares maximum memory ${maxBytes} bytes, exceeding --max-memory ${cap}`);
}

function skipBlockType(wasm, offset) {
  const byte = wasm[offset];
  if (byte === undefined) throw new Error("truncated Wasm block type");
  if (byte === 0x40 || (byte >= 0x6f && byte <= 0x7f)) return offset + 1;
  return skipLEB(wasm, offset);
}

function skipMemarg(wasm, offset) {
  return skipLEB(wasm, skipLEB(wasm, offset));
}

function skipSIMDInstruction(wasm, offset, label) {
  offset = readULEB(wasm, offset);
  const code = lebValue;
  if (code <= 11 || code === 92 || code === 93) return skipMemarg(wasm, offset);
  if (code === 12 || code === 13) return offset + 16;
  if (code >= 21 && code <= 34) return offset + 1;
  if (code >= 84 && code <= 91) return skipMemarg(wasm, offset) + 1;
  if (code <= 255) return offset;
  throw new Error(`${label} uses unsupported SIMD opcode 0x${code.toString(16)}`);
}

// Steps over one Strict Wasm Profile instruction, rejecting anything outside the profile.
// Sets bodyIsDynamic when the instruction disqualifies the enclosing function from being a
// static getter: control flow, calls, locals, global writes, memory, or tables. Reading a
// global is allowed.
let bodyIsDynamic = false;

function skipStrictInstruction(wasm, offset, label) {
  const opcode = wasm[offset++];
  switch (opcode) {
    case 0x00: // unreachable
    case 0x01: // nop
    case 0x05: // else
    case 0x0b: // end
    case 0x0f: // return
    case 0x1a: // drop
    case 0x1b: // select
      return offset;
    case 0x02: // block
    case 0x03: // loop
    case 0x04: // if
      bodyIsDynamic = true;
      return skipBlockType(wasm, offset);
    case 0x0c: // br
    case 0x0d: // br_if
    case 0x10: // call
    case 0x20: // local.get
    case 0x21: // local.set
    case 0x22: // local.tee
    case 0x24: // global.set
    case 0x25: // table.get
    case 0x26: // table.set
    case 0xd2: // ref.func
      bodyIsDynamic = true;
      return skipLEB(wasm, offset);
    case 0x23: // global.get
      return skipLEB(wasm, offset);
    case 0x0e: { // br_table
      bodyIsDynamic = true;
      offset = readULEB(wasm, offset);
      for (let count = lebValue; count >= 0; count -= 1) offset = skipLEB(wasm, offset);
      return offset;
    }
    case 0x11: // call_indirect
      bodyIsDynamic = true;
      return skipLEB(wasm, skipLEB(wasm, offset));
    case 0x1c: // select t*
      offset = readULEB(wasm, offset);
      return offset + lebValue;
    case 0x3f: // memory.size
      bodyIsDynamic = true;
      return offset + 1;
    case 0x40: // memory.grow
      throw new Error(`${label} uses memory.grow, which is outside the Strict Wasm Profile`);
    case 0x41: // i32.const
    case 0x42: // i64.const
    case 0xd0: // ref.null
      return skipLEB(wasm, offset);
    case 0x43: // f32.const
      return offset + 4;
    case 0x44: // f64.const
      return offset + 8;
    case 0xfc: { // saturating truncation, bulk memory, table operations
      bodyIsDynamic = true;
      offset = readULEB(wasm, offset);
      const sub = lebValue;
      if (sub <= 7) return offset;
      if (sub === 8 || sub === 10 || sub === 12 || sub === 14) return skipLEB(wasm, skipLEB(wasm, offset));
      return skipLEB(wasm, offset);
    }
    case 0xfd:
      return skipSIMDInstruction(wasm, offset, label);
    case 0xfe:
      throw new Error(`${label} uses atomic instructions, which are outside the Strict Wasm Profile`);
    case undefined:
      throw new Error(`${label} has a truncated instruction`);
    default:
      if (opcode >= 0x28 && opcode <= 0x3e) { // loads and stores
        bodyIsDynamic = true;
        return skipMemarg(wasm, offset);
      }
      if (opcode >= 0x45 && opcode <= 0xc4) return offset; // numeric, including sign extension
      throw new Error(`${label} uses unsupported Wasm opcode 0x${opcode.toString(16)} at byte offset ${offset - 1}`);
  }
}

const staticExportNames = [
  "input_ptr",
  "input_utf8_cap",
  "input_bytes_cap",
  "output_utf8_cap",
  "output_bytes_cap",
  "failure_modes_per_input_offset",
  "input_content_type_ptr",
  "input_content_type_size",
  "output_content_type_ptr",
  "output_content_type_size",
];

// One pass over the module in binary section order, so every implementation reports the
// same first failure: imports, then memory limits, then exports, then a start function, then
// instructions outside the Strict Wasm Profile. Records which defined functions are static
// getters; because imports are rejected, function indices are code-section indices.
function analyzeStrictModule(wasm, label, maxMemory) {
  if (wasm.length < 8 || wasm[0] !== 0x00 || wasm[1] !== 0x61 || wasm[2] !== 0x73 || wasm[3] !== 0x6d) {
    throw new Error(`${label} is not a WebAssembly binary module`);
  }
  let offset = 8;
  let functionCount = 0;
  let memoryCount = 0;
  const exportsByName = new Map();
  let dynamicFunctions = new Uint8Array(0);
  while (offset < wasm.length) {
    const sectionID = wasm[offset++];
    offset = readULEB(wasm, offset);
    const sectionEnd = offset + lebValue;
    if (sectionEnd > wasm.length) throw new Error(`${label} has a truncated Wasm section`);
    if (sectionID === 2) {
      readULEB(wasm, offset);
      if (lebValue !== 0) throw new Error(`${label} imports host functions or state, which is outside the Strict Wasm Profile`);
    } else if (sectionID === 3) {
      readULEB(wasm, offset);
      functionCount = lebValue;
    } else if (sectionID === 5) {
      let cursor = readULEB(wasm, offset);
      const count = lebValue;
      for (let index = 0; index < count; index += 1) {
        const limits = readLimits(wasm, cursor, label);
        cursor = limits.offset;
        memoryCount += 1;
        validateMemoryLimits(limits, label, maxMemory);
      }
    } else if (sectionID === 7) {
      let cursor = readULEB(wasm, offset);
      const count = lebValue;
      for (let index = 0; index < count; index += 1) {
        const name = readName(wasm, cursor);
        const kind = wasm[name.offset];
        cursor = readULEB(wasm, name.offset + 1);
        exportsByName.set(name.value, { kind, index: lebValue });
      }
    } else if (sectionID === 8) {
      throw new Error(`${label} declares a start function, which is outside the Strict Wasm Profile`);
    } else if (sectionID === 10) {
      let cursor = readULEB(wasm, offset);
      const count = lebValue;
      if (count !== functionCount) throw new Error(`${label} code/function section count mismatch`);
      dynamicFunctions = new Uint8Array(count);
      for (let funcIndex = 0; funcIndex < count; funcIndex += 1) {
        cursor = readULEB(wasm, cursor);
        const bodyEnd = cursor + lebValue;
        if (bodyEnd > sectionEnd) throw new Error(`${label} has a truncated Wasm section`);
        cursor = readULEB(wasm, cursor);
        for (let groups = lebValue; groups > 0; groups -= 1) cursor = skipLEB(wasm, cursor) + 1;
        bodyIsDynamic = false;
        while (cursor < bodyEnd) cursor = skipStrictInstruction(wasm, cursor, label);
        if (cursor !== bodyEnd) throw new Error(`${label} function body is malformed`);
        dynamicFunctions[funcIndex] = bodyIsDynamic ? 1 : 0;
      }
    }
    offset = sectionEnd;
  }
  if (memoryCount !== 1) throw new Error(`${label} must declare exactly one memory`);
  return { exportsByName, dynamicFunctions };
}

function failStaticExports(message) {
  throw new Error(message ?? "comply: static qip contract checks failed");
}

function requireFunctionExport(analysis, name, label) {
  const exp = analysis.exportsByName.get(name);
  if (!exp) failStaticExports(`${label} must export ${name}`);
  if (exp.kind !== 0x00) failStaticExports(`${label} export ${name} must be a function`);
  return exp;
}

function requireStaticFunctionExport(analysis, name, label) {
  const exp = requireFunctionExport(analysis, name, label);
  if (analysis.dynamicFunctions[exp.index] !== 0) failStaticExports("comply: static qip contract checks failed");
}

function wasmMustExportComponentFunctions(analysis, label) {
  const memory = analysis.exportsByName.get("memory");
  if (!memory) failStaticExports(`${label} does not export memory`);
  if (memory.kind !== 0x02) failStaticExports(`${label} export memory must be memory`);
  requireFunctionExport(analysis, "render", label);
  const hasInputPointer = analysis.exportsByName.has("input_ptr");
  const hasInputUTF8 = analysis.exportsByName.has("input_utf8_cap");
  const hasInputBytes = analysis.exportsByName.has("input_bytes_cap");
  if (hasInputPointer) {
    if (hasInputUTF8 === hasInputBytes) failStaticExports(`${label} transform must export exactly one input capacity: input_utf8_cap or input_bytes_cap`);
    requireStaticFunctionExport(analysis, "input_ptr", label);
    requireStaticFunctionExport(analysis, hasInputUTF8 ? "input_utf8_cap" : "input_bytes_cap", label);
  } else if (hasInputUTF8 || hasInputBytes) {
    failStaticExports(`${label} inputless generator must not export an input capacity`);
  }
  const hasOutputUTF8 = analysis.exportsByName.has("output_utf8_cap");
  const hasOutputBytes = analysis.exportsByName.has("output_bytes_cap");
  if (hasOutputUTF8 === hasOutputBytes) failStaticExports(`${label} must export exactly one output capacity: output_utf8_cap or output_bytes_cap`);
  requireStaticFunctionExport(analysis, hasOutputUTF8 ? "output_utf8_cap" : "output_bytes_cap", label);

  for (const prefix of ["input", "output"]) {
    const hasPtr = analysis.exportsByName.has(`${prefix}_content_type_ptr`);
    const hasSize = analysis.exportsByName.has(`${prefix}_content_type_size`);
    if (hasPtr !== hasSize) failStaticExports(`${label} has incomplete ${prefix} content-type exports`);
    if (hasPtr) {
      if (prefix === "input" && !hasInputPointer) failStaticExports(`${label} inputless generator must not declare an input content type`);
      requireStaticFunctionExport(analysis, `${prefix}_content_type_ptr`, label);
      requireStaticFunctionExport(analysis, `${prefix}_content_type_size`, label);
    }
  }

  for (const name of staticExportNames) {
    if (analysis.exportsByName.has(name)) requireStaticFunctionExport(analysis, name, label);
  }
}

export function wasmMustComplyWithComponentContract(wasm, options = {}) {
  const contract = componentContractOptions(options);
  const label = contract.label ?? "component";
  const data = bytes(wasm);
  const maxMemory = contract.maxMemory === undefined || contract.maxMemory === null || contract.maxMemory === "" ? undefined : parseMaxMemory(contract.maxMemory);
  wasmMustExportComponentFunctions(analyzeStrictModule(data, label, maxMemory), label);
}

export function newComponent(instance, options = {}) {
  const contract = componentContractOptions(options);
  const label = contract.label ?? "component";
  const exports = instance.exports;
  if (!(exports.memory instanceof WebAssembly.Memory)) throw new Error(`${label} does not export memory`);
  requireFunction(exports, "render", label);
  const hasInputUTF8 = typeof exports.input_utf8_cap === "function";
  const hasInputBytes = typeof exports.input_bytes_cap === "function";
  const hasInputPointer = exports.input_ptr !== undefined;
  const inputless = !hasInputPointer;
  const hasOutputUTF8 = typeof exports.output_utf8_cap === "function";
  const hasOutputBytes = typeof exports.output_bytes_cap === "function";
  if (!inputless && hasInputUTF8 === hasInputBytes) throw new Error(`${label} transform must export exactly one input capacity: input_utf8_cap or input_bytes_cap`);
  if (inputless && (hasInputUTF8 || hasInputBytes)) throw new Error(`${label} inputless generator must not export an input capacity`);
  if (hasOutputUTF8 === hasOutputBytes) throw new Error(`${label} must export exactly one output capacity: output_utf8_cap or output_bytes_cap`);
  const inputCapName = inputless ? undefined : (hasInputUTF8 ? "input_utf8_cap" : "input_bytes_cap");
  const outputCapName = hasOutputUTF8 ? "output_utf8_cap" : "output_bytes_cap";
  if (!inputless) {
    exportedValue(exports, "input_ptr", label);
    exportedValue(exports, inputCapName, label);
  }
  exportedValue(exports, outputCapName, label);
  const inputMediaType = declaredType(exports, "input", label) || undefined;
  if (inputless && inputMediaType !== undefined) throw new Error(`${label} inputless generator must not declare an input content type`);
  const component = Object.freeze({
    label,
    instance,
    exports,
    inputType: inputless ? undefined : new ContentType(hasInputUTF8 ? "utf8" : "bytes", inputMediaType),
    outputType: new ContentType(hasOutputUTF8 ? "utf8" : "bytes", declaredType(exports, "output", label) || undefined),
    inputCapName,
    outputCapName,
    inputless,
    clearsContentType: !inputless && hasOutputUTF8 && hasInputBytes,
    inputCapacity: inputless ? 0 : exportedValue(exports, inputCapName, label),
    outputCapacity: exportedValue(exports, outputCapName, label),
  });
  if (inputless && contract.inputType !== undefined) throw new Error(`${label} inputless generator does not accept an inputType contract`);
  if (!inputless) assertComponentContract(component, "inputType", contract.inputType);
  assertComponentContract(component, "outputType", contract.outputType);
  return component;
}

function makeStage(spec, component) {
  const stage = {
    label: spec.label ?? spec.filePath ?? component.label,
    uniforms: spec.uniforms ?? [],
    component,
    inputless: component.inputless,
    inputType: component.inputType,
    outputType: component.outputType,
    inputCapName: component.inputCapName,
    outputCapName: component.outputCapName,
    clearsContentType: component.clearsContentType,
    inputCapacity: component.inputCapacity,
    outputCapacity: component.outputCapacity,
  };
  validateUniforms(stage);
  return stage;
}

export class ContentRejection extends Error {
  constructor(label, inputOffset, failureMode) {
    super(inputOffset === undefined
      ? `${label} rejected input`
      : failureMode === 0
        ? `${label} rejected input at input offset ${inputOffset}`
        : `${label} rejected input at input offset ${inputOffset} with mode ${failureMode}`);
    this.name = "ContentRejection";
    this.label = label;
    this.inputOffset = inputOffset;
    this.failureMode = failureMode;
  }
}

// `stepNumber`, when given, prefixes failure messages with the step as every QIP host does:
// "step 2 <path> rejected input at input offset 7", "step 1 <path> trapped: <reason>".
function runStage(stage, input, stepNumber) {
  applyUniforms(stage);
  const label = stepNumber === undefined ? stage.label : `step ${stepNumber} ${stage.label}`;
  const { exports } = stage.component;
  if (stage.inputless) {
    if (input.byteLength !== 0) throw new RangeError(`${label} is an inputless generator and cannot receive input bytes`);
  } else {
    const inputPointer = exportedValue(exports, "input_ptr", stage.label);
    const inputCapacity = exportedValue(exports, stage.inputCapName, stage.label);
    if (input.byteLength > inputCapacity) {
      throw new RangeError(`${label} input is too large (${input.byteLength} bytes > ${inputCapacity} bytes input capacity)`);
    }
    if (inputPointer + input.byteLength > exports.memory.buffer.byteLength) {
      throw new RangeError(`${label} input exceeds linear memory`);
    }
    new Uint8Array(exports.memory.buffer, inputPointer, input.byteLength).set(input);
  }
  let renderResult;
  try {
    renderResult = exports.render(stage.inputless ? 0 : input.byteLength);
  } catch (error) {
    if (error instanceof WebAssembly.RuntimeError) throw new Error(`${label} trapped: ${error.message}`);
    throw error;
  }
  if (typeof renderResult !== "bigint") {
    throw new TypeError(`${label} render export must have signature render(i32) -> i64`);
  }
  const bits = BigInt.asUintN(64, renderResult);
  const outputLength = Number(bits & 0xffff_ffffn);
  if ((bits & (1n << 63n)) !== 0n) {
    if (typeof exports.failure_modes_per_input_offset !== "function") {
      throw new TypeError(`${label} returned failure without failure_modes_per_input_offset`);
    }
    const failureModesPerInputOffset = exportedValue(
      exports,
      "failure_modes_per_input_offset",
      stage.label,
    );
    const rejection = new ContentRejection(
      stage.label,
      failureModesPerInputOffset === 0 ? undefined : Math.floor(outputLength / failureModesPerInputOffset),
      failureModesPerInputOffset === 0 ? undefined : outputLength % failureModesPerInputOffset,
    );
    if (stepNumber !== undefined) rejection.message = `step ${stepNumber} ${rejection.message}`;
    throw rejection;
  }
  const outputPointer = Number((bits >> 32n) & 0x7fff_ffffn);
  const outputCapacity = exportedValue(exports, stage.outputCapName, stage.label);
  if (outputLength > outputCapacity || outputPointer + outputLength > exports.memory.buffer.byteLength) {
    throw new RangeError(`${label} returned an invalid output length`);
  }
  return new Uint8Array(exports.memory.buffer, outputPointer, outputLength).slice();
}

function resolveStageInputType(stage, currentType, allowMissingInputContentType, index = 0, previous = null) {
  if (stage.inputless) return "";
  let effectiveType = currentType;
  if (!effectiveType && stage.inputType.mediaType && allowMissingInputContentType) effectiveType = stage.inputType.mediaType;
  if (stage.inputType.mediaType) {
    const step = `step ${index + 1} ${stage.label}`;
    if (!effectiveType) throw new Error(`${step} expected ${stage.inputType.mediaType}, but pipeline content type is unspecified`);
    const mismatch = contentTypeMismatch(stage.inputType.mediaType, effectiveType);
    if (mismatch !== "") {
      const source = previous ? ` from step ${previous.index + 1} ${previous.stage.label}` : "";
      throw new Error(`${step} expected ${stage.inputType.mediaType}, got ${incomingForMessage(stage.inputType.mediaType, effectiveType)}${source}: ${mismatch}`);
    }
  }
  return effectiveType;
}

// The most recent stage whose output set the pipeline's content type.
function previousTypedStage(stages, index) {
  for (let candidate = index - 1; candidate >= 0; candidate -= 1) {
    const stage = stages[candidate];
    if (stage.outputType.mediaType || !stage.clearsContentType) return { stage, index: candidate };
  }
  return null;
}

function nextContentType(stage, effectiveInputType) {
  if (stage.outputType.mediaType) return stage.outputType.mediaType;
  if (stage.clearsContentType) return "";
  return effectiveInputType;
}

function parseMaxMemory(value) {
  if (!/^\d+$/.test(String(value))) throw new Error(`invalid --max-memory ${value}`);
  const parsed = BigInt(value);
  if (parsed <= 0n || parsed > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error(`invalid --max-memory ${value}`);
  return Number(parsed);
}

function parseU32Flag(name, value) {
  if (!/^\d+$/.test(String(value))) throw new Error(`invalid ${name} ${value}`);
  const parsed = BigInt(value);
  if (parsed < 0n || parsed > 0xffffffffn) throw new Error(`invalid ${name} ${value}`);
  return Number(parsed);
}

// The byte offset of the first invalid UTF-8 sequence in `bytes`, or -1 when it is all valid.
// Follows the Unicode well-formed byte sequence table, so overlong forms and surrogates are
// invalid. The offset matches the "input offset" a rejecting component reports.
function firstInvalidUTF8Offset(bytes) {
  const n = bytes.length;
  let i = 0;
  while (i < n) {
    const b = bytes[i];
    if (b < 0x80) { i += 1; continue; }
    let need;
    let lo = 0x80;
    let hi = 0xbf;
    if (b >= 0xc2 && b <= 0xdf) need = 1;
    else if (b === 0xe0) { need = 2; lo = 0xa0; }
    else if (b >= 0xe1 && b <= 0xec) need = 2;
    else if (b === 0xed) { need = 2; hi = 0x9f; }
    else if (b >= 0xee && b <= 0xef) need = 2;
    else if (b === 0xf0) { need = 3; lo = 0x90; }
    else if (b >= 0xf1 && b <= 0xf3) need = 3;
    else if (b === 0xf4) { need = 3; hi = 0x8f; }
    else return i;
    if (i + need >= n) return i;
    const second = bytes[i + 1];
    if (second < lo || second > hi) return i;
    for (let k = 2; k <= need; k += 1) {
      const c = bytes[i + k];
      if (c < 0x80 || c > 0xbf) return i;
    }
    i += need + 1;
  }
  return -1;
}

// The pipeline's own input is validated for a UTF-8 first stage, because nothing before it
// established the guarantee. Later stages trust the preceding UTF-8 output.
function checkInitialUTF8(stage, input) {
  if (stage.inputless || stage.inputType.encoding !== "utf8") return;
  const offset = firstInvalidUTF8Offset(input);
  if (offset !== -1) throw new Error(`step 1 ${stage.label} expected UTF-8 input, got invalid UTF-8 at input offset ${offset}`);
}

// A UTF-8 output may feed a bytes input; a bytes output may not feed a UTF-8 input, because
// the host never re-validates bytes and a UTF-8 component relies on valid input.
function checkStageEncoding(stages, index) {
  const stage = stages[index];
  if (stage.inputless || index === 0) return;
  const previous = stages[index - 1];
  const incoming = previous.outputType.encoding;
  const expected = stage.inputType.encoding;
  if (incoming === expected || (incoming === "utf8" && expected === "bytes")) return;
  throw new Error(`step ${index + 1} ${stage.label} expected UTF-8 input, got bytes from step ${index} ${previous.label}`);
}

function checkStagePosition(stages, index) {
  if (stages[index].inputless && index !== 0) {
    throw new Error(`step ${index + 1} ${stages[index].label} inputless generator must be the first pipeline stage`);
  }
}

// The capacity note and error share their wording with qip and the Rust qipx.
function capacityOverflow(stages, index) {
  if (index === 0 || stages[index].inputless) return null;
  const previous = stages[index - 1];
  if (previous.outputCapacity <= stages[index].inputCapacity) return null;
  return { previous, stage: stages[index], index };
}

function validatePipeline(stages, options = {}) {
  if (!Array.isArray(stages) || stages.length === 0) throw new Error("at least one component is required");
  let currentType = "";
  stages.forEach((stage, index) => {
    checkStagePosition(stages, index);
    checkStageEncoding(stages, index);
    const overflow = capacityOverflow(stages, index);
    if (overflow && options.capacitiesMustFit) {
      throw new Error(
        `step ${index + 1} ${stage.label} input capacity ${formatBytes(stage.inputCapacity)} cannot fit step ${index} ${overflow.previous.label} output capacity ${formatBytes(overflow.previous.outputCapacity)}`,
      );
    }
    const effectiveType = resolveStageInputType(stage, currentType, index === 0, index, previousTypedStage(stages, index));
    currentType = nextContentType(stage, effectiveType);
  });
  const last = stages.at(-1);
  return Object.freeze({
    stages,
    outputType: new ContentType(last.outputType.encoding, currentType || undefined),
  });
}

function runPreparedPipeline(input, pipeline, initialContentType = "") {
  let output = bytes(input);
  let currentType = initialContentType;
  for (let index = 0; index < pipeline.stages.length; index += 1) {
    const stage = pipeline.stages[index];
    checkStagePosition(pipeline.stages, index);
    checkStageEncoding(pipeline.stages, index);
    if (index === 0) checkInitialUTF8(stage, output);
    const effectiveType = resolveStageInputType(stage, currentType, index === 0, index, previousTypedStage(pipeline.stages, index));
    output = runStage(stage, output, index + 1);
    currentType = nextContentType(stage, effectiveType);
  }
  return pipelineResult(output, new ContentType(pipeline.stages.at(-1).outputType.encoding, currentType || undefined));
}

function pipelineResult(outputBytes, outputType) {
  const result = {
    outputBytes,
    outputType,
  };
  if (outputType.encoding === "utf8") {
    let outputString;
    Object.defineProperty(result, "outputString", {
      enumerable: true,
      get() {
        if (outputString === undefined) outputString = decoder.decode(outputBytes);
        return outputString;
      },
    });
  }
  return Object.freeze(result);
}

export function createRecipe(steps, options = {}) {
  const stages = [];
  for (const step of steps) {
    if (step && Array.isArray(step.stages)) {
      stages.push(...step.stages);
      continue;
    }
    if (step && step.instance instanceof WebAssembly.Instance) {
      stages.push(makeStage({ component: step }, step));
      continue;
    }
    if (!step?.component) throw new Error("recipe step requires component or recipe");
    stages.push(makeStage(step, step.component));
  }
  return validatePipeline(stages, options);
}

export function render(target, input) {
  if (target && Array.isArray(target.stages)) return runPreparedPipeline(input, target);
  if (target && target.instance instanceof WebAssembly.Instance) return runPreparedPipeline(input, createRecipe([{ component: target }]));
  throw new Error("render target must be a component or recipe");
}

async function walkWasmFiles(path) {
  const info = await stat(path);
  if (info.isFile()) {
    if (!path.endsWith(".wasm")) throw new Error(`${path} is not a .wasm file`);
    return [path];
  }
  if (!info.isDirectory()) throw new Error(`${path} is not a file or directory`);
  const files = [];
  async function walk(directory) {
    const entries = await readdir(directory, { withFileTypes: true });
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const entry of entries) {
      const child = join(directory, entry.name);
      if (entry.isDirectory()) await walk(child);
      else if (entry.isFile() && entry.name.endsWith(".wasm")) files.push(child);
    }
  }
  await walk(path);
  return files;
}

async function discoverWasmFiles(paths) {
  const files = [];
  for (const path of paths) {
    try {
      files.push(...await walkWasmFiles(path));
    } catch (error) {
      if (missingFileError(error) && remotelyEligiblePath(path)) files.push(path);
      else throw error;
    }
  }
  return [...new Set(files)].sort((a, b) => a.localeCompare(b));
}

function parseComplyCLI(argv) {
  // TODO: Add --straight-line-oracles for --with oracles so JS comply can
  // match Go's audit mode for fixture-style Compliance oracles.
  const options = { maxMemory: undefined, with: [], seed: undefined };
  const paths = [];
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--help" || arg === "-h") {
      console.log(complyUsage());
      process.exit(0);
    } else if (arg === "--max-memory") {
      options.maxMemory = parseMaxMemory(argv[++index]);
    } else if (arg === "--with") {
      const value = argv[++index];
      if (!value) throw new Error("--with requires a path");
      options.with.push(value);
    } else if (arg === "--seed") {
      options.seed = parseU32Flag("--seed", argv[++index]);
    } else if (arg.startsWith("-")) {
      throw new Error(`unknown comply option ${arg}`);
    } else {
      paths.push(arg);
    }
  }
  if (paths.length === 0) throw new Error("comply requires at least one file or directory");
  options.with.sort((a, b) => a.localeCompare(b));
  return { options, paths };
}

function readMemory(memory, ptr, length) {
  const start = Number(ptr) >>> 0;
  const size = Number(length) >>> 0;
  if (start + size > memory.buffer.byteLength) return null;
  return new Uint8Array(memory.buffer, start, size).slice();
}

function renderComponent(component, input) {
  const stage = makeStage({ component }, component);
  return runStage(stage, bytes(input));
}

async function instantiateContentComponent(wasm, label, options = {}) {
  wasmMustComplyWithComponentContract(wasm, { label, maxMemory: options.maxMemory });
  const module = new WebAssembly.Module(wasm);
  const instance = new WebAssembly.Instance(module);
  return newComponent(instance, { label });
}

function instantiateComplianceOracle(wasm, label, imports) {
  const module = new WebAssembly.Module(wasm);
  const instance = new WebAssembly.Instance(module, imports);
  if (!(instance.exports.memory instanceof WebAssembly.Memory)) throw new Error(`${label} Compliance oracle must export memory`);
  if (typeof instance.exports.comply !== "function") throw new Error(`${label} Compliance oracle must export comply() -> i32`);
  return instance;
}

async function runComplianceOracle(implWasm, implPath, oraclePath, oracleWasm, options = {}) {
  const impl = await instantiateContentComponent(implWasm, implPath, options);
  let oracleInstance;
  const state = { next: 0n, openRenderInto: null, openRenderIntoFailed: false, openRenderIntoErrorCount: 0, failCount: 0, failures: [], protocolError: null };
  const failProtocol = (message) => {
    if (!state.protocolError) state.protocolError = message;
  };
  const oracleMemory = () => oracleInstance?.exports?.memory;
  const readOracle = (ptr, length) => {
    const memory = oracleMemory();
    if (!(memory instanceof WebAssembly.Memory)) return null;
    return readMemory(memory, ptr, length);
  };
  const caseOpen = (ordinal, kind) => {
    const ord = BigInt(ordinal);
    if (state.openRenderInto !== null) {
      failProtocol(`${kind} at ordinal ${ord} inside open must_render_into case ${state.openRenderInto}`);
      return false;
    }
    if (ord !== state.next) {
      failProtocol(`${kind} declared ordinal ${ord}, host expected ${state.next}`);
      return false;
    }
    return true;
  };
  const qip = {
    set_uniform_u32(namePtr, nameLen, value) {
      if (state.openRenderInto !== null) {
        failProtocol(`set_uniform_u32 called inside open must_render_into case ${state.openRenderInto}`);
        return 0;
      }
      if (nameLen === 0 || nameLen > 128) {
        failProtocol(`set_uniform_u32 name length ${nameLen} is outside 1..128`);
        return 0;
      }
      const nameBytes = readOracle(namePtr, nameLen);
      if (!nameBytes) {
        failProtocol("set_uniform_u32 name pointer out of range");
        return 0;
      }
      const name = decoder.decode(nameBytes);
      if (!validUniformKey(name)) {
        failProtocol(`set_uniform_u32 name ${JSON.stringify(name)} is not a valid uniform key`);
        return 0;
      }
      const setter = impl.exports[`uniform_set_${name}`];
      if (typeof setter !== "function") {
        failProtocol(`implementation does not export uniform_set_${name}`);
        return 0;
      }
      try {
        return Number(setter(Number(value) >>> 0)) | 0;
      } catch (error) {
        failProtocol(`uniform_set_${name} trapped: ${error.message ?? error}`);
        return 0;
      }
    },
    must_render_exactly(ordinal, inPtr, inLen, expPtr, expLen) {
      if (!caseOpen(ordinal, "must_render_exactly")) return 0;
      state.next += 1n;
      const input = readOracle(inPtr, inLen);
      const expected = readOracle(expPtr, expLen);
      if (!input || !expected) {
        failProtocol(`must_render_exactly pointers out of range at ordinal ${ordinal}`);
        return 0;
      }
      try {
        const actual = renderComponent(impl, input);
        if (actual.byteLength !== expected.byteLength || actual.some((byte, index) => byte !== expected[index])) {
          state.failCount += 1;
          state.failures.push(`case ${ordinal}: output mismatch`);
          return 0;
        }
        return 1;
      } catch (error) {
        state.failCount += 1;
        if (error instanceof ContentRejection) {
          state.failures.push(`case ${ordinal}: unexpected rejection (failure detail ${error.detail})`);
        } else {
          state.failures.push(`case ${ordinal}: trapped: ${error.message ?? error}`);
        }
        return 0;
      }
    },
    must_trap(ordinal, inPtr, inLen) {
      if (!caseOpen(ordinal, "must_trap")) return 0;
      state.next += 1n;
      const input = readOracle(inPtr, inLen);
      if (!input) {
        failProtocol(`must_trap pointer out of range at ordinal ${ordinal}`);
        return 0;
      }
      try {
        renderComponent(impl, input);
        state.failCount += 1;
        state.failures.push(`case ${ordinal}: expected trap, got output`);
        return 0;
      } catch (error) {
        if (error instanceof ContentRejection) {
          state.failCount += 1;
          state.failures.push(`case ${ordinal}: expected trap, got rejection (failure detail ${error.detail})`);
          return 0;
        }
        return 1;
      }
    },
    must_reject(ordinal, inPtr, inLen) {
      if (!caseOpen(ordinal, "must_reject")) return 0;
      state.next += 1n;
      const input = readOracle(inPtr, inLen);
      if (!input) {
        failProtocol(`must_reject pointer out of range at ordinal ${ordinal}`);
        return 0;
      }
      if (typeof impl.exports.failure_modes_per_input_offset !== "function") {
        state.failCount += 1;
        state.failures.push(`case ${ordinal}: expected rejection, but implementation does not export failure_modes_per_input_offset`);
        return 0;
      }
      try {
        renderComponent(impl, input);
        state.failCount += 1;
        state.failures.push(`case ${ordinal}: expected rejection, render was accepted`);
        return 0;
      } catch (error) {
        if (error instanceof ContentRejection) return 1;
        state.failCount += 1;
        state.failures.push(`case ${ordinal}: expected rejection: ${error.message ?? error}`);
        return 0;
      }
    },
    must_render_into(ordinal, inPtr, inLen, outPtr, outCap) {
      const ord = BigInt(ordinal);
      if (state.openRenderInto !== null) {
        failProtocol(`must_render_into opened ordinal ${ord} while ordinal ${state.openRenderInto} is still open`);
        return -1;
      }
      if (ord !== state.next) {
        failProtocol(`must_render_into opened ordinal ${ord}, host expected ${state.next}`);
        return -1;
      }
      state.openRenderInto = ord;
      state.openRenderIntoFailed = false;
      state.openRenderIntoErrorCount = 0;
      const input = readOracle(inPtr, inLen);
      if (!input) {
        state.openRenderIntoFailed = true;
        failProtocol(`must_render_into pointer out of range at ordinal ${ord}`);
        return -1;
      }
      let output;
      try {
        output = renderComponent(impl, input);
      } catch {
        state.openRenderIntoFailed = true;
        return -1;
      }
      if (output.byteLength > (Number(outCap) >>> 0)) {
        state.openRenderIntoFailed = true;
        return -2;
      }
      const memory = oracleMemory();
      const outStart = Number(outPtr) >>> 0;
      if (outStart + output.byteLength > memory.buffer.byteLength) {
        state.openRenderIntoFailed = true;
        failProtocol(`must_render_into out pointer out of range at ordinal ${ord}`);
        return -1;
      }
      new Uint8Array(memory.buffer, outStart, output.byteLength).set(output);
      return output.byteLength;
    },
    must_render_into_emit_error(ordinal, messagePtr, messageSize) {
      const ord = BigInt(ordinal);
      if (state.openRenderInto === null || state.openRenderInto !== ord) {
        failProtocol(`must_render_into_emit_error ordinal ${ord} does not match open must_render_into case ${state.openRenderInto}`);
        return 0;
      }
      const message = readOracle(messagePtr, messageSize);
      if (!message) {
        failProtocol(`must_render_into_emit_error message pointer out of range at ordinal ${ord}`);
        return 0;
      }
      state.openRenderIntoErrorCount += 1;
      state.failures.push(`case ${ord}: render_into error: ${decoder.decode(message)}`);
      return 1;
    },
    must_render_into_finish(ordinal, errorCount) {
      const ord = BigInt(ordinal);
      const count = Number(errorCount) >>> 0;
      if (state.openRenderInto === null || state.openRenderInto !== ord) {
        failProtocol(`must_render_into_finish ordinal ${ord} does not match open must_render_into case ${state.openRenderInto}`);
        return 0;
      }
      if (count !== state.openRenderIntoErrorCount) {
        failProtocol(`must_render_into_finish ordinal ${ord} reported ${count} errors, host observed ${state.openRenderIntoErrorCount}`);
        return 0;
      }
      if (state.openRenderIntoFailed && count === 0) {
        failProtocol(`must_render_into_finish ordinal ${ord} reported 0 errors after render failure`);
        return 0;
      }
      if (count > 0) state.failCount += 1;
      state.openRenderInto = null;
      state.openRenderIntoFailed = false;
      state.openRenderIntoErrorCount = 0;
      state.next += 1n;
      return 1;
    },
  };
  oracleInstance = instantiateComplianceOracle(oracleWasm, oraclePath, { qip });
  if (options.seed !== undefined) {
    const setSeed = oracleInstance.exports.uniform_set_seed;
    if (typeof setSeed !== "function") throw new Error(`${oraclePath}: --seed given but Compliance oracle does not export uniform_set_seed`);
    try {
      setSeed(options.seed >>> 0);
    } catch (error) {
      throw new Error(`${oraclePath}: uniform_set_seed failed: ${error.message ?? error}`);
    }
  }
  let declared;
  try {
    declared = Number(oracleInstance.exports.comply()) | 0;
  } catch (error) {
    throw new Error(`${oraclePath}: comply() trapped: ${error.message ?? error}`);
  }
  if (state.protocolError) throw new Error(`${oraclePath}: bridge protocol violation: ${state.protocolError}`);
  if (state.openRenderInto !== null) throw new Error(`${oraclePath}: comply() returned with must_render_into case ${state.openRenderInto} still open`);
  if (declared <= 0) throw new Error(`${oraclePath}: comply() declared no cases (returned ${declared})`);
  if (BigInt(declared >>> 0) !== state.next) throw new Error(`${oraclePath}: comply() returned ${declared} cases but host counted ${state.next}`);
  if (state.failCount > 0) throw new Error(`${oraclePath}: ${state.failCount}/${state.next} cases failed; ${state.failures[0]}`);
  return { cases: Number(state.next) };
}

async function complyCommand(argv, hosts) {
  const { options, paths } = parseComplyCLI(argv);
  const files = await discoverWasmFiles(paths);
  if (files.length === 0) throw new Error("No .wasm files found");
  const oracles = [];
  for (const oraclePath of options.with) {
    const oracleWasm = await resolveSource(sourcePlan(oraclePath, hosts), (wasm, label) => {
      try {
        new WebAssembly.Module(wasm);
      } catch (error) {
        throw new Error(`${label} is not valid WebAssembly: ${error.message ?? error}`);
      }
    });
    oracles.push({ path: oraclePath, wasm: oracleWasm });
  }
  let pass = 0;
  let fail = 0;
  for (const file of files) {
    let wasm;
    try {
      wasm = await resolveSource(sourcePlan(file, hosts), (candidate, label) => {
        wasmMustComplyWithComponentContract(candidate, { label, maxMemory: options.maxMemory });
      });
      await instantiateContentComponent(wasm, file, options);
      console.log(`PASS ${displayText(file)}`);
      pass += 1;
    } catch (error) {
      console.log(`FAIL ${displayText(file)}: ${displayText(error.message ?? error)}`);
      fail += 1;
      continue;
    }
    for (const oracle of oracles) {
      try {
        const result = await runComplianceOracle(wasm, file, oracle.path, oracle.wasm, options);
        console.log(`PASS ${displayText(file)} --with ${displayText(oracle.path)} (${result.cases} cases)`);
        pass += 1;
      } catch (error) {
        console.log(`FAIL ${displayText(file)} --with ${displayText(oracle.path)}: ${displayText(error.message ?? error)}`);
        fail += 1;
      }
    }
  }
  console.log(`\npass=${pass} fail=${fail} total=${pass + fail}`);
  if (fail > 0) process.exitCode = 1;
}

function parseStageArgs(args) {
  const stages = [];
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "-u" || arg === "--uniform") {
      if (stages.length === 0) throw new Error(`${arg} must follow a component path`);
      const assignment = args[++index];
      if (assignment === undefined) throw new Error(`${arg} requires <name=value>`);
      const equals = assignment.indexOf("=");
      if (equals <= 0) throw new Error(`${arg} requires <name=value>, got ${JSON.stringify(assignment)}`);
      stages.at(-1).uniforms.push([assignment.slice(0, equals), assignment.slice(equals + 1)]);
      continue;
    }
    if (!arg) throw new Error("component path must not be empty");
    if (arg.startsWith("?")) throw new Error(`uniform query arguments are not supported; use -u <name=value>`);
    stages.push({ filePath: arg, label: arg, uniforms: [] });
  }
  return stages;
}

function parseCLI(argv) {
  const options = { input: "-", inputFromCLI: false, formValues: [], output: "-", maxMemory: undefined, capacitiesMustFit: false };
  const components = [];
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--") {
      components.push(...argv.slice(index + 1));
      break;
    } else if (arg === "-i" || arg === "--input") {
      options.input = argv[++index];
      options.inputFromCLI = true;
    } else if (arg === "-F" || arg === "--form") {
      const value = argv[++index];
      if (value === undefined) throw new Error(`${arg} requires <name=value>`);
      parseFormAssignment(value);
      options.formValues.push(value);
    } else if (arg === "-o" || arg === "--output") {
      options.output = argv[++index];
    } else if (arg === "--max-memory") {
      options.maxMemory = parseMaxMemory(argv[++index]);
    } else if (arg === "--capacities-must-fit") {
      options.capacitiesMustFit = true;
    } else if (arg === "-u" || arg === "--uniform") {
      components.push(arg);
      if (index + 1 >= argv.length) throw new Error(`${arg} requires <name=value>`);
      components.push(argv[++index]);
    } else if (arg.startsWith("-")) {
      throw new Error(`unknown option ${arg}`);
    } else {
      components.push(arg);
    }
  }
  if (!options.input) throw new Error("--input requires a path");
  if (!options.output) throw new Error("--output requires a path");
  if (options.inputFromCLI && options.formValues.length > 0) throw new Error("-F and -i are mutually exclusive");
  return { options, components: parseStageArgs(components) };
}

async function loadStages(componentSpecs, options, hosts) {
  const stages = [];
  for (const spec of componentSpecs) {
    const contract = newContentComponentContract({ maxMemory: options.maxMemory, label: spec.label });
    const wasm = await resolveSource(sourcePlan(spec.filePath, hosts), (candidate) => {
      wasmMustComplyWithComponentContract(candidate, contract);
    });
    const module = new WebAssembly.Module(wasm);
    const instance = new WebAssembly.Instance(module);
    const component = newComponent(instance, contract);
    stages.push({ component, label: spec.label, uniforms: spec.uniforms });
  }
  return stages;
}

async function prepareRunPipeline(argv, hosts) {
  const { options, components } = parseCLI(argv);
  const stages = await loadStages(components, options, hosts);
  const pipeline = createRecipe(stages, {
    capacitiesMustFit: options.capacitiesMustFit,
  });
  return { options, pipeline };
}

function printSourceObservations(observations) {
  console.log("Sources:");
  observations.forEach(({ plan }, componentIndex) => {
    if (observations.length > 1) console.log(`  Component ${componentIndex + 1}: ${displayText(plan.filePath)}`);
    plan.sources.forEach((source, sourceIndex) => {
      const indent = observations.length > 1 ? "    " : "  ";
      console.log(`${indent}${sourceIndex}  ${source.kind.padEnd(5)}  ${displayText(source.kind === "local" ? source.path : source.url)}`);
    });
  });
  console.log("\nResolution:");
  observations.forEach(({ plan, local }, componentIndex) => {
    if (observations.length > 1) console.log(`  Component ${componentIndex + 1}: ${displayText(plan.filePath)}`);
    const indent = observations.length > 1 ? "    " : "  ";
    console.log(`${indent}0  ${local.state}`);
    for (let index = 1; index < plan.sources.length; index += 1) console.log(`${indent}${index}  unexamined`);
  });
}

async function observeMultipartFileSources(formPlan) {
  const observations = [];
  for (const field of formPlan.fields) {
    const { assignment, sourcePlan: plan } = field;
    if (!assignment.filePath || assignment.filePath === "-") continue;
    let state;
    try {
      await stat(assignment.filePath);
      state = "present (contents not read)";
    } catch (error) {
      if (!missingFileError(error)) throw error;
      state = "missing";
    }
    observations.push({ assignment, plan, state });
  }
  return observations;
}

function printMultipartFileObservations(observations) {
  if (observations.length === 0) return;
  console.log("\nMultipart files:");
  for (const { assignment, plan, state } of observations) {
    console.log(`  Field ${displayText(JSON.stringify(assignment.name))}: ${displayText(plan.filePath)}`);
    plan.sources.forEach((source, index) => {
      const label = source.kind === "local" ? source.path : source.url;
      console.log(`    ${index}  ${source.kind.padEnd(5)}  ${displayText(label)}  ${index === 0 ? state : "unexamined"}`);
    });
  }
}

async function dryRunCommand(argv, hosts) {
  const { options, components } = parseCLI(argv);
  if (components.length === 0) throw new Error("at least one component is required");
  const observations = [];
  for (const spec of components) {
    const plan = sourcePlan(spec.filePath, hosts);
    observations.push({ spec, plan, local: await observeLocalSource(plan) });
  }
  printSourceObservations(observations);
  const formPlan = planMultipartFormInput(options.formValues, hosts);
  printMultipartFileObservations(await observeMultipartFileSources(formPlan));
  console.log("\nValidation:");
  const stages = [];
  let missing = 0;
  for (const observation of observations) {
    if (observation.local.state === "missing") {
      console.log(`  ${displayText(observation.spec.label)}: deferred (local file missing)`);
      missing += 1;
      continue;
    }
    const contract = newContentComponentContract({ maxMemory: options.maxMemory, label: observation.spec.label });
    wasmMustComplyWithComponentContract(observation.local.bytes, contract);
    const module = new WebAssembly.Module(observation.local.bytes);
    const instance = new WebAssembly.Instance(module);
    const component = newComponent(instance, contract);
    const stage = makeStage({ component, label: observation.spec.label, uniforms: observation.spec.uniforms }, component);
    applyUniforms(stage);
    stages.push(stage);
    console.log(`  ${displayText(observation.spec.label)}: valid`);
  }
  if (missing > 0) {
    console.log(`Pipeline compatibility: deferred (${missing} component${missing === 1 ? "" : "s"} missing locally)`);
    return;
  }
  const pipeline = createRecipe(stages, { capacitiesMustFit: options.capacitiesMustFit });
  printDryRunPlan(pipeline);
}

function formatBytes(count) {
  if (count < 1024) return `${count} B`;
  const units = ["KiB", "MiB", "GiB"];
  let value = count;
  let unit = "bytes";
  for (const next of units) {
    if (value < 1024) break;
    value /= 1024;
    unit = next;
  }
  return `${value.toFixed(1)} ${unit} (${count} bytes)`;
}

function printDryRunPlan(plan) {
  console.log(`Pipeline compatible: ${plan.stages.length} step(s)`);
  let total = 0;
  plan.stages.forEach((stage, index) => {
    const buffers = stage.inputCapacity + stage.outputCapacity;
    total += buffers;
    console.log(`${index + 1}. ${displayText(stage.label)} — Content`);
    console.log(`   Input:  encoding=${stage.inputless ? "none" : (stage.inputType.encoding === "utf8" ? "UTF-8" : "bytes")}, type=${stage.inputless ? "unspecified" : (stage.inputType.mediaType || "unspecified")}, capacity=${formatBytes(stage.inputCapacity)}`);
    console.log(`   Output: encoding=${stage.outputType.encoding === "utf8" ? "UTF-8" : "bytes"}, type=${stage.outputType.mediaType || "unspecified"}, capacity=${formatBytes(stage.outputCapacity)}`);
    console.log(`   Buffers: ${formatBytes(buffers)}`);
  });
  console.log(`Total declared buffer capacity: ${formatBytes(total)}`);
  plan.stages.forEach((stage, index) => {
    const overflow = capacityOverflow(plan.stages, index);
    if (!overflow) return;
    console.log(
      `   Note: step ${index + 1} ${displayText(stage.label)}: previous output capacity ${formatBytes(overflow.previous.outputCapacity)} exceeds this input capacity ${formatBytes(stage.inputCapacity)}; the run remains valid when the actual intermediate output fits`,
    );
  });
}

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(bytes(chunk));
  const length = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0);
  const out = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

const canonicalFormBoundary = "uuid-00000000-0000-0000-0000-000000000000";
export const canonicalFormContentType = `multipart/form-data;boundary=${canonicalFormBoundary}`;

function validateFormQuotedValue(value, label) {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code < 0x20 || code > 0x7e || value[index] === '"' || value[index] === "\\") {
      throw new Error(`multipart ${label} ${JSON.stringify(value)} must use printable ASCII without quotes or backslashes`);
    }
  }
}

function parseFormAssignment(value) {
  const equals = value.indexOf("=");
  if (equals <= 0) throw new Error(`-F requires <name=value>, got ${JSON.stringify(value)}`);
  const name = value.slice(0, equals);
  const rawValue = value.slice(equals + 1);
  validateFormQuotedValue(name, "field name");
  const fileMode = rawValue[0] === "@" || rawValue[0] === "<" ? rawValue[0] : "";
  if (!fileMode) return { name, value: rawValue, filePath: "", fileMode };
  const filePath = rawValue.slice(1);
  if (!filePath) throw new Error(`-F ${JSON.stringify(value)} has an empty file path`);
  return { name, value: "", filePath, fileMode };
}

function planMultipartFormInput(values, hosts = []) {
  const fields = values.map((value) => {
    const assignment = parseFormAssignment(value);
    const fileSourcePlan = assignment.filePath && assignment.filePath !== "-"
      ? sourcePlan(assignment.filePath, hosts)
      : undefined;
    return Object.freeze({ assignment: Object.freeze(assignment), sourcePlan: fileSourcePlan });
  });
  if (fields.filter(({ assignment }) => assignment.filePath === "-").length > 1) {
    throw new Error("only one -F field may read from stdin with @- or <-");
  }
  return Object.freeze({ fields: Object.freeze(fields) });
}

function canonicalFormFilename(filePath) {
  const filename = filePath.split(/[\\/]/).at(-1);
  if (!filename) throw new Error(`multipart file path ${JSON.stringify(filePath)} has no filename`);
  validateFormQuotedValue(filename, "filename");
  return filename;
}

function multipartBodyContainsBoundary(body) {
  const marker = Buffer.from(`\r\n--${canonicalFormBoundary}`);
  const source = Buffer.from(body.buffer, body.byteOffset, body.byteLength);
  for (let offset = 0; ;) {
    const index = source.indexOf(marker, offset);
    if (index < 0) return false;
    const after = index + marker.length;
    if (after + 2 <= source.length) {
      const suffix = source.subarray(after, after + 2);
      if (suffix.equals(Buffer.from("\r\n")) || suffix.equals(Buffer.from("--"))) return true;
    }
    offset = index + 1;
  }
}

export async function buildMultipartFormInput(values, { stdin, hosts = [], loadFile } = {}) {
  const formPlan = planMultipartFormInput(values, hosts);
  return buildMultipartFormInputFromPlan(formPlan, { stdin, loadFile });
}

async function buildMultipartFormInputFromPlan(formPlan, { stdin, loadFile } = {}) {
  const chunks = [];
  for (const { assignment, sourcePlan: fileSourcePlan } of formPlan.fields) {
    let body;
    let filename = "";
    if (!assignment.filePath) {
      body = encoder.encode(assignment.value);
    } else if (assignment.filePath === "-") {
      body = stdin === undefined ? await readStdin() : bytes(stdin);
      if (assignment.fileMode === "@") filename = "-";
    } else {
      try {
        body = bytes(await (loadFile
          ? loadFile(assignment.filePath, fileSourcePlan)
          : loadMultipartFile(assignment.filePath, fileSourcePlan)));
        if (assignment.fileMode === "@") filename = canonicalFormFilename(assignment.filePath);
      } catch (error) {
        throw new Error(`read -F ${assignment.name}=${assignment.fileMode}${assignment.filePath}: ${error.message ?? error}`);
      }
    }
    if (multipartBodyContainsBoundary(body)) {
      throw new Error(`-F field ${JSON.stringify(assignment.name)} contains the multipart boundary as a delimiter line`);
    }

    let header = `--${canonicalFormBoundary}\r\nContent-Disposition: form-data; name="${assignment.name}"`;
    if (filename) header += `; filename="${filename}"\r\nContent-Type: application/octet-stream`;
    chunks.push(encoder.encode(`${header}\r\n\r\n`), body, encoder.encode("\r\n"));
  }
  chunks.push(encoder.encode(`--${canonicalFormBoundary}--\r\n`));
  const length = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0);
  const output = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    output.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return Object.freeze({ bytes: output, contentType: canonicalFormContentType });
}

function parsePositiveInteger(value, label) {
  if (!/^\d+$/.test(String(value))) throw new Error(`${label} must be a positive integer`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) throw new Error(`${label} must be a positive integer`);
  return parsed;
}

function parseNonnegativeInteger(value, label) {
  if (!/^\d+$/.test(String(value))) throw new Error(`${label} must be a nonnegative integer`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) throw new Error(`${label} must be a nonnegative integer`);
  return parsed;
}

function parseBenchDuration(value) {
  const match = /^(\d+(?:\.\d+)?)(ns|us|µs|ms|s|m)$/.exec(String(value));
  if (!match) throw new Error(`invalid --benchtime ${value}; use a duration such as 250ms, 3s, or 1m`);
  const scale = { ns: 1, us: 1e3, "µs": 1e3, ms: 1e6, s: 1e9, m: 60e9 }[match[2]];
  const nanoseconds = Number(match[1]) * scale;
  if (!Number.isFinite(nanoseconds) || nanoseconds <= 0) throw new Error("--benchtime must be greater than zero");
  return nanoseconds;
}

function parseBenchCLI(argv) {
  const options = {
    input: "",
    inputFromCLI: false,
    formValues: [],
    runs: undefined,
    benchtime: 3e9,
    benchtimeLabel: "3s",
    warmup: 10,
    maxMemory: undefined,
  };
  const components = [];
  let runsSet = false;
  let benchtimeSet = false;
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--") {
      components.push(...argv.slice(index + 1));
      break;
    }
    if (arg === "-h" || arg === "--help") return { help: true };
    if (arg === "-i" || arg === "--input") {
      const value = argv[++index];
      if (value === undefined) throw new Error(`${arg} requires a path`);
      options.input = value;
      options.inputFromCLI = true;
    } else if (arg === "-F" || arg === "--form") {
      const value = argv[++index];
      if (value === undefined) throw new Error(`${arg} requires <name=value>`);
      parseFormAssignment(value);
      options.formValues.push(value);
    } else if (arg === "-r" || arg === "--runs") {
      options.runs = parsePositiveInteger(argv[++index], arg);
      runsSet = true;
    } else if (arg === "--warmup") {
      options.warmup = parseNonnegativeInteger(argv[++index], arg);
    } else if (arg === "--max-memory") {
      options.maxMemory = parseMaxMemory(argv[++index]);
    } else if (arg === "--benchtime") {
      options.benchtimeLabel = argv[++index];
      options.benchtime = parseBenchDuration(options.benchtimeLabel);
      benchtimeSet = true;
    } else if (arg.startsWith("--benchtime=")) {
      options.benchtimeLabel = arg.slice("--benchtime=".length);
      options.benchtime = parseBenchDuration(options.benchtimeLabel);
      benchtimeSet = true;
    } else if (arg === "-u" || arg === "--uniform") {
      components.push(arg);
      if (index + 1 >= argv.length) throw new Error(`${arg} requires <name=value>`);
      components.push(argv[++index]);
    } else if (arg.startsWith("-")) {
      throw new Error(`unknown option ${arg}`);
    } else {
      components.push(arg);
    }
  }
  if (runsSet && benchtimeSet) throw new Error("use either --runs or --benchtime, not both");
  if (options.inputFromCLI && options.formValues.length > 0) throw new Error("-F and -i are mutually exclusive");
  if (!options.inputFromCLI && options.formValues.length === 0) throw new Error("qipx bench requires -i <input> or -F <name=value>");
  if (options.inputFromCLI && !options.input) throw new Error("--input requires a path");
  const specs = parseStageArgs(components);
  if (specs.length === 0) throw new Error("qipx bench requires at least one component");
  return { help: false, options, specs };
}

function sameBytes(left, right) {
  if (left.byteLength !== right.byteLength) return false;
  for (let index = 0; index < left.byteLength; index += 1) {
    if (left[index] !== right[index]) return false;
  }
  return true;
}

function sameContentType(left, right) {
  return left.encoding === right.encoding && left.mediaType === right.mediaType;
}

function assertBenchmarkOutput(expected, actual, label, phase) {
  if (!sameContentType(expected.outputType, actual.outputType)) {
    throw new Error(`${label} ${phase} output type ${describeContentType(actual.outputType)} does not match baseline ${describeContentType(expected.outputType)}`);
  }
  if (!sameBytes(expected.outputBytes, actual.outputBytes)) {
    throw new Error(`${label} ${phase} output does not match baseline (${actual.outputBytes.byteLength} bytes, expected ${expected.outputBytes.byteLength})`);
  }
}

function percentile(sorted, fraction) {
  return sorted[Math.max(0, Math.ceil(sorted.length * fraction) - 1)];
}

function summarizeBenchmarkSamples(samples, measuredMean) {
  const sorted = [...samples].sort((a, b) => a - b);
  const mean = measuredMean ?? samples.reduce((sum, value) => sum + value, 0) / samples.length;
  const variance = samples.reduce((sum, value) => sum + (value - mean) ** 2, 0) / samples.length;
  return {
    mean,
    stddev: Math.sqrt(variance),
    min: sorted[0],
    p50: percentile(sorted, 0.5),
    p95: percentile(sorted, 0.95),
    max: sorted.at(-1),
  };
}

function formatDuration(nanoseconds) {
  if (nanoseconds < 1e3) return `${nanoseconds.toFixed(0)} ns`;
  if (nanoseconds < 1e6) return `${(nanoseconds / 1e3).toFixed(nanoseconds < 1e4 ? 2 : 1)} µs`;
  if (nanoseconds < 1e9) return `${(nanoseconds / 1e6).toFixed(nanoseconds < 1e7 ? 2 : 1)} ms`;
  return `${(nanoseconds / 1e9).toFixed(2)} s`;
}

function formatRate(value) {
  if (value >= 1e9) return `${(value / 1e9).toFixed(2)} billion`;
  if (value >= 1e6) return `${(value / 1e6).toFixed(2)} million`;
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: value < 100 ? 1 : 0 }).format(value);
}

function formatInputThroughput(inputSize, meanNanoseconds) {
  if (inputSize === 0) return "Input empty";
  const bytesPerSecond = inputSize * 1e9 / meanNanoseconds;
  const units = [[1024 ** 3, "GiB/s"], [1024 ** 2, "MiB/s"], [1024, "KiB/s"], [1, "bytes/s"]];
  const [scale, unit] = units.find(([threshold]) => bytesPerSecond >= threshold);
  const rate = bytesPerSecond / scale;
  const formatted = new Intl.NumberFormat("en-US", { maximumFractionDigits: rate < 10 ? 2 : 1 }).format(rate);
  return `Input throughput: ${formatted} ${unit} (${inputSize} bytes/render)`;
}

function sha256Hex(data) {
  return createHash("sha256").update(data).digest("hex");
}

function benchmarkSample(candidate, input, expected, targetNanoseconds) {
  let elapsed = 0;
  let renders = 0;
  do {
    const start = process.hrtime.bigint();
    const result = render(candidate.recipe, input);
    const renderElapsed = Number(process.hrtime.bigint() - start);
    assertBenchmarkOutput(expected, result, candidate.label, `run ${candidate.renderCount + renders + 1}`);
    elapsed += renderElapsed;
    renders += 1;
  } while (elapsed < targetNanoseconds);
  return { elapsed, renders, mean: elapsed / renders };
}

async function loadBenchmarkCandidate(spec, options, hosts) {
  const contract = newContentComponentContract({ label: spec.label, maxMemory: options.maxMemory });
  const wasm = await resolveSource(sourcePlan(spec.filePath, hosts), (candidate) => {
    wasmMustComplyWithComponentContract(candidate, contract);
  });

  const compileStart = process.hrtime.bigint();
  const module = new WebAssembly.Module(wasm);
  const compileNanoseconds = Number(process.hrtime.bigint() - compileStart);

  const instantiateStart = process.hrtime.bigint();
  const instance = new WebAssembly.Instance(module);
  const instantiateNanoseconds = Number(process.hrtime.bigint() - instantiateStart);

  const component = newComponent(instance, contract);
  const recipe = createRecipe([{ component, label: spec.label, uniforms: spec.uniforms }]);
  return {
    label: spec.label,
    wasm,
    component,
    recipe,
    compileNanoseconds,
    instantiateNanoseconds,
    samples: [],
    measuredNanoseconds: 0,
    renderCount: 0,
  };
}

function benchmarkRuntimeDescription() {
  const bunVersion = globalThis.Bun?.version;
  if (bunVersion) {
    const jscVersion = process.versions.webkit;
    return `Bun ${bunVersion}, JavaScriptCore${jscVersion ? ` ${jscVersion}` : ""}`;
  }
  return `Node.js ${process.versions.node}, V8 ${process.versions.v8}`;
}

function benchmarkGCOptInCommand() {
  const runtime = globalThis.Bun?.version ? "bun" : "node";
  const modulePath = process.argv[1] ? JSON.stringify(process.argv[1]) : "path/to/qipx.mjs";
  return `${runtime} --expose-gc ${modulePath} bench ...`;
}

function printBenchmarkReport(candidates, input, inputLabel, expected, options, collectedAfterWarmup) {
  const outputHash = sha256Hex(expected.outputBytes);
  console.log(candidates.length === 1 ? "Benchmark: baseline output captured" : "Benchmark: outputs match");
  console.log(`Input: ${displayText(inputLabel)} (${input.byteLength} bytes, sha256 ${sha256Hex(input)})`);
  console.log(`Output: ${describeContentType(expected.outputType)}, ${expected.outputBytes.byteLength} bytes`);
  console.log(`Output SHA-256: ${outputHash}`);
  console.log(`Warmup: ${options.warmup} runs/component`);
  if (collectedAfterWarmup) {
    console.log("GC preparation: manual collection after each component's warmup");
  } else {
    console.log("GC preparation: runtime-managed only");
    console.log(`GC opt-in: ${benchmarkGCOptInCommand()}`);
  }
  if (options.runs === undefined) console.log(`Measured: ${options.benchtimeLabel} target/component`);
  else console.log(`Measured: ${options.runs} runs/component`);
  console.log(`Runtime: ${benchmarkRuntimeDescription()}`);
  const cpu = cpus()[0]?.model;
  console.log(`Platform: ${platform()} ${arch()}${cpu ? `, ${cpu}` : ""}`);
  console.log("Boundary: uniforms, input/output copies, and render on one reused instance\n");

  const summaries = candidates.map((candidate) => summarizeBenchmarkSamples(candidate.samples, candidate.measuredNanoseconds / candidate.renderCount));
  const fastestMean = Math.min(...summaries.map((summary) => summary.mean));
  const nameWidth = Math.max("Implementation".length, ...candidates.map((candidate) => displayText(basename(candidate.label)).length));
  const headers = ["Implementation".padEnd(nameWidth), "Mean".padStart(11), "p50".padStart(11), "p95".padStart(11), "Stddev".padStart(11), "Relative".padStart(10)];
  console.log(headers.join("  "));
  candidates.forEach((candidate, index) => {
    const summary = summaries[index];
    console.log([
      displayText(basename(candidate.label)).padEnd(nameWidth),
      formatDuration(summary.mean).padStart(11),
      formatDuration(summary.p50).padStart(11),
      formatDuration(summary.p95).padStart(11),
      formatDuration(summary.stddev).padStart(11),
      `${(summary.mean / fastestMean).toFixed(2)}x`.padStart(10),
    ].join("  "));
  });
  console.log("");

  candidates.forEach((candidate, index) => {
    const summary = summaries[index];
    const rendersPerSecond = 1e9 / summary.mean;
    const memoryBytes = candidate.component.exports.memory.buffer.byteLength;
    console.log(`${index + 1}. ${displayText(candidate.label)}`);
    console.log(`   Time: ${formatDuration(summary.mean)} ± ${formatDuration(summary.stddev)} [min ${formatDuration(summary.min)}, p50 ${formatDuration(summary.p50)}, p95 ${formatDuration(summary.p95)}, max ${formatDuration(summary.max)}]`);
    console.log(`   Throughput: ${formatRate(rendersPerSecond)} renders/s`);
    if (options.runs === undefined) console.log(`   Samples: ${candidate.samples.length}; renders: ${candidate.renderCount}`);
    console.log(`   ${formatInputThroughput(input.byteLength, summary.mean)}`);
    console.log(`   Compile: ${formatDuration(candidate.compileNanoseconds)}; instantiate: ${formatDuration(candidate.instantiateNanoseconds)}`);
    console.log(`   Linear memory: ${formatBytes(memoryBytes)}`);
    console.log(`   Capacity: input ${formatBytes(candidate.component.inputCapacity)}, output ${formatBytes(candidate.component.outputCapacity)}`);
    console.log(`   Wasm: ${candidate.wasm.byteLength} bytes, gzip ${gzipSync(candidate.wasm, { level: 9 }).byteLength} bytes`);
    const variation = summary.stddev / summary.mean;
    if (variation >= 0.1) console.log(`   Warning: standard deviation is ${(variation * 100).toFixed(1)}% of the mean; repeat without competing CPU-heavy work.`);
    console.log("");
  });

  if (candidates.length > 1) {
    let fastest = 0;
    let slowest = 0;
    for (let index = 1; index < candidates.length; index += 1) {
      if (summaries[index].mean < summaries[fastest].mean) fastest = index;
      if (summaries[index].mean > summaries[slowest].mean) slowest = index;
    }
    console.log(`Fastest: ${displayText(candidates[fastest].label)}`);
    if (fastest !== slowest) console.log(`${displayText(candidates[fastest].label)} was ${(summaries[slowest].mean / summaries[fastest].mean).toFixed(2)}x faster than ${displayText(candidates[slowest].label)} by mean time.`);
  }
}

async function benchCommand(argv, hosts) {
  const parsed = parseBenchCLI(argv);
  if (parsed.help) {
    console.log(benchUsage());
    return;
  }
  const { options, specs } = parsed;
  const collectAfterWarmup = typeof globalThis.gc === "function";
  let input;
  let inputLabel;
  if (options.formValues.length > 0) {
    const form = await buildMultipartFormInput(options.formValues, { hosts });
    input = form.bytes;
    inputLabel = `multipart form (${options.formValues.length} field${options.formValues.length === 1 ? "" : "s"})`;
  } else {
    input = options.input === "-" ? await readStdin() : await readFile(options.input);
    inputLabel = options.input === "-" ? "stdin" : options.input;
  }
  const candidates = [];
  for (const spec of specs) candidates.push(await loadBenchmarkCandidate(spec, options, hosts));

  const expected = render(candidates[0].recipe, input);
  for (let index = 1; index < candidates.length; index += 1) {
    assertBenchmarkOutput(expected, render(candidates[index].recipe, input), candidates[index].label, "check");
  }

  const minimumSamples = options.runs ?? 10;
  const maximumSamples = options.runs ?? 1_000_000;
  const sampleTarget = options.runs === undefined ? 1e6 : 0;
  for (const candidate of candidates) {
    for (let warmup = 0; warmup < options.warmup; warmup += 1) {
      assertBenchmarkOutput(expected, render(candidate.recipe, input), candidate.label, `warmup ${warmup + 1}`);
    }
    if (collectAfterWarmup) globalThis.gc();

    for (let sample = 0; sample < maximumSamples; sample += 1) {
      const measured = benchmarkSample(candidate, input, expected, sampleTarget);
      candidate.samples.push(measured.mean);
      candidate.measuredNanoseconds += measured.elapsed;
      candidate.renderCount += measured.renders;
      const completedSamples = sample + 1;
      if (options.runs !== undefined && completedSamples >= options.runs) break;
      if (options.runs === undefined && completedSamples >= minimumSamples && candidate.measuredNanoseconds >= options.benchtime) break;
      if (completedSamples === maximumSamples) throw new Error(`--benchtime produced more than ${maximumSamples} samples; use --runs for explicit control`);
    }
  }

  printBenchmarkReport(candidates, input, inputLabel, expected, options, collectAfterWarmup);
}

/** @private Shared implementation for the package's unexported CLI module. */
export const __cliInternals = Object.freeze({
  displayText,
  usage,
  tuiUsage,
  parseInvocation,
  complyCommand,
  benchCommand,
  dryRunCommand,
  prepareRunPipeline,
  parseFormAssignment,
  planMultipartFormInput,
  buildMultipartFormInput,
  buildMultipartFormInputFromPlan,
  loadMultipartFile,
  resolveStageInputType,
  nextContentType,
  applyUniforms,
  runStage,
  readStdin,
  runPreparedPipeline,
});
