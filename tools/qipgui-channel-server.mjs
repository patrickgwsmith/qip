#!/usr/bin/env node

// A local test server for the qipgui shared channel protocol
// (docs/qipgui-sync-protocol.md). It keeps the log in memory, so "stored durably" here
// only means "kept until the process exits". It serves the modules it is given at
// content-addressed URLs, over plain HTTP on a loopback address.
//
//   node tools/qipgui-channel-server.mjs gui/calculator.wasm
//   node npm/qipgui/qipgui.mjs connect <the URL it prints>
//
// While it runs, it reads commands from stdin:
//
//   module <file.wasm> [input-file]   switch the channel to another module
//   prefetch <file.wasm>              tell clients to load a module early
//   drop                              cut every open stream, so clients reconnect
//   close [reason]                    close the channel
//   quit

import { createHash, randomBytes } from "node:crypto";
import { realpathSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import process from "node:process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

import {
  ChannelError, formatEvent, parseFieldLine, parseInputLine, SSEParser, validUpdateID,
} from "../npm/qipgui/qip-channel.mjs";

export const DEFAULT_LIMITS = {
  moduleInputBytes: 1024 * 1024,
  batchBytes: 64 * 1024,
  batchInputs: 256,
  batchesPerSecond: 240,
  lifetimeMS: 24 * 60 * 60 * 1000,
  logEntries: 100_000,
};

// Each keepalive carries a time event, so idle clients keep their channel clock close.
const KEEPALIVE_MS = 5_000;
const SLOW_STREAM_BYTES = 4 * 1024 * 1024;

class HTTPError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

// Reads a POST body with the same SSE parser that a client uses for the log.
export function parseUpdateBody(text, limits = DEFAULT_LIMITS) {
  if (text.includes("\r")) throw new HTTPError(400, "each line must end with one LF");
  if (!text.endsWith("\n\n")) throw new HTTPError(400, "the body does not end with an empty line");
  const parser = new SSEParser();
  const events = parser.push(text);
  if (events.length !== 1 || parser.partial) throw new HTTPError(400, "the body must hold one event");
  const [event] = events;
  if (event.event !== "update") throw new HTTPError(400, "the event field must be update");
  if (event.id !== null) throw new HTTPError(400, "the body must not have an id field");
  if (event.data.length < 2) throw new HTTPError(400, "a batch needs an update_id line and one or more inputs");
  if (event.data.length - 1 > limits.batchInputs) throw new HTTPError(400, "the batch has too many inputs");
  try {
    const first = parseFieldLine(event.data[0]);
    if (first.has("time_ms")) throw new HTTPError(400, "the body must not have a time_ms field");
    const updateID = first.get("update_id") ?? "";
    if (!validUpdateID(updateID)) throw new HTTPError(400, "update_id is missing or not valid");
    event.data.slice(1).forEach(parseInputLine);
    return { updateID, lines: event.data };
  } catch (error) {
    if (error instanceof ChannelError) throw new HTTPError(400, error.message);
    throw error;
  }
}

class Channel {
  constructor({ limits, prune, log, keepaliveMS }) {
    this.limits = limits;
    this.keepaliveMS = keepaliveMS;
    this.prune = prune;
    this.log = log;
    this.read = randomBytes(24).toString("base64url");
    this.write = randomBytes(24).toString("base64url");
    this.entries = []; // { seq, type, text }
    this.nextSeq = 0;
    this.lastTime = 0;
    this.startedAt = performance.now();
    this.updates = new Map(); // update_id -> { body, seq, time }
    this.streams = new Set();
    this.closed = false;
    this.tokens = limits.batchesPerSecond;
    this.refilledAt = performance.now();
    this.lifetime = setTimeout(() => this.close("limit"), limits.lifetimeMS);
    this.lifetime.unref();
  }

  // Strictly increasing, even when two requests arrive in the same millisecond.
  nextTime() {
    this.lastTime = Math.max(this.lastTime + 1, Math.floor(performance.now() - this.startedAt) + 1);
    return this.lastTime;
  }

  // The current channel time, outside the log. It is never before the last entry.
  timeEvent() {
    const time = Math.max(this.lastTime, Math.floor(performance.now() - this.startedAt) + 1);
    return formatEvent({ event: "time", data: [`time_ms=${time}`] });
  }

  append(type, data) {
    if (this.closed) throw new HTTPError(410, "the channel is closed");
    const seq = this.nextSeq++;
    const entry = { seq, type, text: formatEvent({ id: seq, event: type, data }) };
    if (type === "module" && this.prune) this.entries = [];
    this.entries.push(entry);
    if (type === "closed") this.closed = true;
    this.log(`seq ${seq} ${type}${type === "update" ? ` (${data.length - 1} inputs)` : ""}`);
    for (const stream of this.streams) {
      stream.write(entry.text);
      if (type === "closed") stream.end();
      else if (stream.writableLength > SLOW_STREAM_BYTES) stream.destroy();
    }
    if (type === "closed") {
      this.streams.clear();
      clearTimeout(this.lifetime);
    } else if (this.entries.length >= this.limits.logEntries - 1) this.close("limit");
    return seq;
  }

  appendModule({ url, integrity }, input = new Uint8Array()) {
    if (input.byteLength > this.limits.moduleInputBytes) throw new Error("the module input is too large");
    const fields = new URLSearchParams({ time_ms: String(this.nextTime()), url, integrity });
    if (input.byteLength) fields.set("input", Buffer.from(input).toString("base64"));
    return this.append("module", [fields.toString()]);
  }

  appendPrefetch({ url, integrity }) {
    return this.append("prefetch", [new URLSearchParams({ url, integrity }).toString()]);
  }

  close(reason = "operator") {
    if (!this.closed) this.append("closed", [new URLSearchParams({ reason }).toString()]);
  }

  // Cuts every open stream without closing the channel.
  dropStreams() {
    for (const stream of this.streams) stream.destroy();
    this.streams.clear();
  }

  post(body) {
    const { updateID, lines } = parseUpdateBody(body, this.limits);
    const stored = this.updates.get(updateID);
    if (stored) {
      if (stored.body !== body) throw new HTTPError(409, "the update_id is in use with a different body");
      return stored;
    }
    if (this.closed) throw new HTTPError(410, "the channel is closed");
    const now = performance.now();
    this.tokens = Math.min(this.limits.batchesPerSecond, this.tokens + (now - this.refilledAt) / 1000 * this.limits.batchesPerSecond);
    this.refilledAt = now;
    if (this.tokens < 1) throw new HTTPError(429, "the input rate is too high");
    this.tokens -= 1;
    const time = this.nextTime();
    const result = { body, time, seq: -1 };
    // Stored with the entry and before it goes out, so a retry never makes a second entry.
    this.updates.set(updateID, result);
    result.seq = this.append("update", [`time_ms=${time}&${lines[0]}`, ...lines.slice(1)]);
    return result;
  }

  // Selects the replay range and registers the live stream in one synchronous step.
  subscribe(response, cursor) {
    let start = 0;
    if (cursor === null) start = this.entries.findLastIndex((entry) => entry.type === "module");
    else {
      if (cursor >= this.nextSeq) throw new HTTPError(400, "the cursor is after the end of the log");
      // A cursor from before the removed entries gets everything that is left, which
      // starts at the most recent module entry.
      start = this.entries.findIndex((entry) => entry.seq > cursor);
      if (start < 0) start = this.entries.length;
    }
    response.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-store" });
    response.write(": qipgui channel\n\n");
    for (const entry of this.entries.slice(Math.max(start, 0))) response.write(entry.text);
    if (this.closed) return response.end();
    // After the replay, so a client does not run wakes past entries that it has not read.
    response.write(this.timeEvent());
    this.streams.add(response);
    const keepalive = setInterval(() => response.write(this.timeEvent()), this.keepaliveMS);
    response.on("close", () => {
      clearInterval(keepalive);
      this.streams.delete(response);
    });
  }
}

async function readBody(request, limit) {
  const chunks = [];
  let length = 0;
  for await (const chunk of request) {
    length += chunk.byteLength;
    if (length > limit) throw new HTTPError(400, "the body is too large");
    chunks.push(chunk);
  }
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks, length));
  } catch {
    throw new HTTPError(400, "the body is not UTF-8");
  }
}

// Returns a server with no channels. Call listen() first, then addModule() and
// createChannel(). Request logs never hold a capability.
export function createChannelServer({ limits = {}, prune = false, log = () => {}, keepaliveMS = KEEPALIVE_MS } = {}) {
  limits = { ...DEFAULT_LIMITS, ...limits };
  const capabilities = new Map(); // capability -> { channel, write }
  const modules = new Map(); // "<hex>.wasm" -> bytes
  let origin = "";

  const handle = async (request, response) => {
    const url = new URL(request.url, "http://localhost");
    const module = /^\/modules\/([0-9a-f]{64}\.wasm)$/.exec(url.pathname);
    if (module) {
      const bytes = modules.get(module[1]);
      if (!bytes || request.method !== "GET") throw new HTTPError(404, "not found");
      response.writeHead(200, { "content-type": "application/wasm", "content-length": bytes.byteLength, "cache-control": "immutable, max-age=31536000" });
      return response.end(bytes);
    }
    const route = /^\/v1\/channels\/([A-Za-z0-9_-]+)\/events$/.exec(url.pathname);
    const access = route && capabilities.get(route[1]);
    if (!access) throw new HTTPError(404, "not found");
    const { channel, write } = access;
    if (request.method === "GET") {
      const text = url.searchParams.get("after") ?? request.headers["last-event-id"] ?? null;
      if (text !== null && !/^(?:0|[1-9][0-9]{0,15})$/.test(text)) throw new HTTPError(400, "the cursor is not valid");
      return channel.subscribe(response, text === null ? null : Number(text));
    }
    if (request.method !== "POST") throw new HTTPError(405, "use GET or POST");
    if (!write) throw new HTTPError(403, "the capability is a read capability");
    if ((request.headers["content-type"] ?? "").split(";")[0].trim().toLowerCase() !== "text/event-stream") {
      throw new HTTPError(400, "the Content-Type must be text/event-stream");
    }
    const { seq, time } = channel.post(await readBody(request, limits.batchBytes));
    response.writeHead(202, { "content-type": "application/x-www-form-urlencoded" });
    response.end(`seq=${seq}&time_ms=${time}\n`);
  };

  const server = createServer((request, response) => {
    handle(request, response).catch((error) => {
      const status = error instanceof HTTPError ? error.status : 500;
      if (status === 500) log(`error: ${error.stack ?? error}`);
      if (response.headersSent) return response.destroy();
      response.writeHead(status, { "content-type": "text/plain; charset=utf-8", connection: "close" });
      response.end(`${error instanceof HTTPError ? error.message : "server error"}\n`);
    });
  });

  return {
    server,
    async listen(port = 0, host = "127.0.0.1") {
      await new Promise((resolve, reject) => server.once("error", reject).listen(port, host, resolve));
      origin = `http://${host.includes(":") ? `[${host}]` : host}:${server.address().port}`;
      return origin;
    },
    // Stores module bytes and returns the url and integrity for a module or prefetch entry.
    addModule(bytes) {
      const hash = createHash("sha256").update(bytes);
      const name = `${hash.copy().digest("hex")}.wasm`;
      modules.set(name, Buffer.from(bytes));
      return { url: `${origin}/modules/${name}`, integrity: `sha256-${hash.digest("base64")}` };
    },
    createChannel(module, input) {
      const channel = new Channel({ limits, prune, log, keepaliveMS });
      capabilities.set(channel.read, { channel, write: false });
      capabilities.set(channel.write, { channel, write: true });
      channel.appendModule(module, input);
      channel.readURL = `${origin}/v1/channels/${channel.read}`;
      channel.writeURL = `${origin}/v1/channels/${channel.write}`;
      return channel;
    },
    // Deletes a channel: its capabilities then return 404.
    deleteChannel(channel) {
      channel.close();
      capabilities.delete(channel.read);
      capabilities.delete(channel.write);
    },
    async close() {
      for (const { channel } of capabilities.values()) {
        clearTimeout(channel.lifetime);
        channel.dropStreams();
      }
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}

async function main(args) {
  let port = 8787;
  let prune = false;
  let inputPath = null;
  let modulePath = null;
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--port") port = Number(args[++index]);
    else if (arg === "--prune") prune = true;
    else if (arg === "-i" || arg === "--input") inputPath = args[++index];
    else if (arg.startsWith("-") || modulePath) throw new Error("usage: qipgui-channel-server.mjs [--port n] [--prune] [-i input] <gui.wasm>");
    else modulePath = arg;
  }
  if (!modulePath || !Number.isInteger(port)) throw new Error("usage: qipgui-channel-server.mjs [--port n] [--prune] [-i input] <gui.wasm>");
  const log = (line) => process.stderr.write(`${line}\n`);
  const host = createChannelServer({ prune, log });
  await host.listen(port);
  const channel = host.createChannel(host.addModule(await readFile(modulePath)), inputPath ? await readFile(inputPath) : undefined);
  process.stdout.write(
    `View:  node npm/qipgui/qipgui.mjs connect ${channel.readURL}\n` +
    `Edit:  node npm/qipgui/qipgui.mjs connect ${channel.writeURL}\n` +
    `Commands: module <file.wasm> [input-file], prefetch <file.wasm>, drop, close [reason], quit\n`,
  );
  for await (const line of createInterface({ input: process.stdin })) {
    const [command, ...rest] = line.trim().split(/\s+/);
    try {
      if (command === "module" && rest[0]) {
        channel.appendModule(host.addModule(await readFile(rest[0])), rest[1] ? await readFile(rest[1]) : undefined);
      } else if (command === "prefetch" && rest[0]) channel.appendPrefetch(host.addModule(await readFile(rest[0])));
      else if (command === "drop") channel.dropStreams();
      else if (command === "close") channel.close(rest.join(" ") || "operator");
      else if (command === "quit") break;
      else if (command) log("commands: module <file.wasm> [input-file], prefetch <file.wasm>, drop, close [reason], quit");
    } catch (error) {
      log(error.message ?? String(error));
    }
  }
  await host.close();
}

if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(error.message ?? error);
    process.exitCode = 1;
  });
}
