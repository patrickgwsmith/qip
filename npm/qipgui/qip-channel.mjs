// The client side of the qipgui shared channel protocol (docs/qipgui-sync-protocol.md):
// the SSE reader and writer, field lines, entry checks, a log reader that reconnects from
// the last applied sequence number, and a sender that posts one batch at a time. It knows
// nothing about terminals or GUI components, so other hosts can use it too.

import { createHash, randomBytes } from "node:crypto";

export const MAX_BATCH_INPUTS = 64;
const MAX_PENDING_INPUTS = 1024;
const MAX_MODULE_BYTES = 16 * 1024 * 1024;
const POST_TIMEOUT_MS = 5000;
const I64_MAX = (1n << 63n) - 1n;

// An error that reconnecting cannot fix: the client must stop and tell the user.
export class ChannelError extends Error {}

// Reads one application/x-www-form-urlencoded field line. The first value of a name wins.
export function parseFieldLine(line) {
  if (line === "" || /[\r\n]/.test(line)) throw new ChannelError("a field line is empty or has a line break");
  const fields = new Map();
  for (const [name, value] of new URLSearchParams(line)) {
    if (!fields.has(name)) fields.set(name, value);
  }
  return fields;
}

export function formatFieldLine(fields) {
  return new URLSearchParams(Object.entries(fields).map(([name, value]) => [name, String(value)])).toString();
}

// Splits a text/event-stream into events. Each event keeps its data lines as a list, so a
// batch is never joined into one string. An event without a blank line after it stays in
// the buffer and is dropped when the stream ends.
export class SSEParser {
  constructor() {
    this.buffer = "";
    this.event = null;
  }

  // True when the stream stopped inside an event or a line.
  get partial() {
    return this.buffer !== "" || this.event !== null;
  }

  push(text) {
    this.buffer += text;
    const events = [];
    for (;;) {
      const match = /\r\n|\n|\r(?!$)/.exec(this.buffer);
      if (!match) break;
      const line = this.buffer.slice(0, match.index);
      this.buffer = this.buffer.slice(match.index + match[0].length);
      if (line === "") {
        if (this.event) events.push(this.event);
        this.event = null;
        continue;
      }
      if (line.startsWith(":")) continue;
      const colon = line.indexOf(":");
      const name = colon < 0 ? line : line.slice(0, colon);
      let value = colon < 0 ? "" : line.slice(colon + 1);
      if (value.startsWith(" ")) value = value.slice(1);
      this.event ??= { id: null, event: null, data: [] };
      if (name === "data") this.event.data.push(value);
      else if (name === "event") this.event.event = value;
      else if (name === "id") this.event.id = value;
    }
    return events;
  }
}

// Writes one SSE event. id is left out of a POST body.
export function formatEvent({ id = null, event, data }) {
  return (id === null ? "" : `id: ${id}\n`) + `event: ${event}\n` + data.map((line) => `data: ${line}\n`).join("") + "\n";
}

function required(fields, name) {
  const value = fields.get(name);
  if (value === undefined) throw new ChannelError(`the ${name} field is missing`);
  return value;
}

function i32(fields, name) {
  const text = required(fields, name);
  const value = /^-?[0-9]{1,10}$/.test(text) ? Number(text) : NaN;
  if (!(value >= -2147483648 && value <= 2147483647)) throw new ChannelError(`${name} is not an i32 decimal integer`);
  return value;
}

function timeMS(fields) {
  const text = required(fields, "time_ms");
  if (!/^[0-9]{1,19}$/.test(text)) throw new ChannelError("time_ms is not a decimal integer");
  const value = BigInt(text);
  if (value < 1n || value > I64_MAX) throw new ChannelError("time_ms is outside 1 to the i64 maximum");
  return value;
}

const BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

function base64(text, name) {
  if (!BASE64.test(text)) throw new ChannelError(`${name} is not base64 with padding`);
  return Buffer.from(text, "base64");
}

const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);

// Channel and module URLs use HTTPS. Plain HTTP is only accepted for a loopback host, and
// only when the caller permits it, so a local test server works without certificates.
export function checkedURL(text, { loopback = false, name = "url" } = {}) {
  let url;
  try {
    url = new URL(text);
  } catch {
    throw new ChannelError(`${name} is not an absolute URL`);
  }
  if (url.username || url.password) throw new ChannelError(`${name} must not hold a user name or password`);
  if (url.protocol === "https:") return url;
  if (url.protocol === "http:" && loopback && LOOPBACK_HOSTS.has(url.hostname)) return url;
  throw new ChannelError(`${name} must use HTTPS`);
}

export function isLoopbackHTTP(url) {
  return url.protocol === "http:" && LOOPBACK_HOSTS.has(url.hostname);
}

export function validUpdateID(text) {
  return /^[A-Za-z0-9_-]{1,64}$/.test(text);
}

function moduleFields(fields, options) {
  const integrity = required(fields, "integrity");
  if (!integrity.startsWith("sha256-") || base64(integrity.slice(7), "integrity").length !== 32) {
    throw new ChannelError("integrity is not sha256- and a base64 SHA-256 digest");
  }
  return { url: checkedURL(required(fields, "url"), options).href, integrity };
}

// Reads one input line of an update: a key or a pointer event.
export function parseInputLine(line) {
  const fields = parseFieldLine(line);
  const type = required(fields, "type");
  if (type === "key") return { type, keysym: i32(fields, "keysym"), flags: i32(fields, "flags") };
  if (type === "pointer") return { type, mask: i32(fields, "mask"), x: i32(fields, "x"), y: i32(fields, "y") };
  throw new ChannelError(`unknown input type ${type}`);
}

export function formatInputLine(input) {
  return input.type === "key"
    ? formatFieldLine({ type: "key", keysym: input.keysym, flags: input.flags })
    : formatFieldLine({ type: "pointer", mask: input.mask, x: input.x, y: input.y });
}

// The body of a POST: one update event with no id and no time_ms.
export function formatUpdateBody(updateID, inputs) {
  return formatEvent({ event: "update", data: [formatFieldLine({ update_id: updateID }), ...inputs.map(formatInputLine)] });
}

// Checks one SSE event from the log and converts its fields to their types.
export function parseEntry(event, options = {}) {
  if (event.id === null || !/^(?:0|[1-9][0-9]{0,15})$/.test(event.id) || !Number.isSafeInteger(Number(event.id))) {
    throw new ChannelError("a log entry has no valid sequence number");
  }
  const seq = Number(event.id);
  if (!event.data.length) throw new ChannelError(`entry ${seq} has no data lines`);
  const type = event.event;
  try {
    const first = parseFieldLine(event.data[0]);
    if (type === "update") {
      const updateID = required(first, "update_id");
      if (!validUpdateID(updateID)) throw new ChannelError("update_id is not valid");
      if (event.data.length < 2) throw new ChannelError("an update has no inputs");
      return { seq, type, time: timeMS(first), updateID, inputs: event.data.slice(1).map(parseInputLine) };
    }
    if (type === "module") {
      const input = base64(first.get("input") ?? "", "input");
      return { seq, type, time: timeMS(first), ...moduleFields(first, options), input: new Uint8Array(input) };
    }
    if (type === "prefetch") return { seq, type, ...moduleFields(first, options) };
    if (type === "closed") return { seq, type, reason: required(first, "reason") };
  } catch (error) {
    if (error instanceof ChannelError) throw new ChannelError(`entry ${seq} is not valid: ${error.message}`);
    throw error;
  }
  throw new ChannelError(`entry ${seq} has the unknown type ${type ?? "(none)"}; this client cannot continue`);
}

// Reads a time event: the server's channel clock, sent outside the log. It has no id.
export function parseTimeEvent(event) {
  if (event.id !== null || event.data.length !== 1) throw new ChannelError("a time event must have no id and one data line");
  return timeMS(parseFieldLine(event.data[0]));
}

// Runs the log of a channel together with the wakes that its component asks for, in
// channel time order, so that every client reaches the same state.
//
//   reset(moduleEntry)        make a new instance of the module and give it its input
//   update(time, inputs)      run one update; returns { wake, accepted }, where wake is
//                             the bigint that finish_update returned
//
// A wake that is earlier than the next log entry is part of the shared history, because
// all clients run it at the same time with the same state. A client runs wakes ahead of
// the log (advanceTo) so that animations play between entries. If an entry then arrives
// with a time_ms that is not after the last update that ran, the timeline makes a new
// instance and replays from the module entry. Replays do not render.
export class ChannelTimeline {
  constructor({ reset, update }) {
    this.reset = reset;
    this.update = update;
    this.module = null;
    this.entries = [];
    this.ran = 0n;
    this.wake = null;
    this.offset = null;
    this.replays = 0;
  }

  // Estimates the channel clock from a time that the server sent at local time localMS.
  // The estimate is behind the server by the shortest delay seen, so wakes rarely run
  // past an entry that is still on its way.
  observe(time, localMS) {
    const offset = Number(time) - localMS;
    if (this.offset === null || offset > this.offset) this.offset = offset;
  }

  now(localMS) {
    return this.offset === null ? null : BigInt(Math.floor(localMS + this.offset));
  }

  run(time, inputs) {
    const { wake, accepted } = this.update(time, inputs);
    if (typeof wake !== "bigint" || wake < time) throw new ChannelError("the component returned a wake time that is not valid");
    this.ran = time;
    this.wake = wake > time ? wake : null;
    return accepted;
  }

  // Runs the wakes that are earlier than time. Returns how many ran.
  wakesBefore(time) {
    let count = 0;
    while (this.wake !== null && this.wake < time) {
      this.run(this.wake, []);
      count += 1;
    }
    return count;
  }

  startModule(entry) {
    this.module = entry;
    this.entries = [];
    this.reset(entry);
    this.run(entry.time, []);
  }

  // Applies an update entry. Returns true when the frame can have changed.
  applyUpdate(entry) {
    this.entries.push(entry);
    if (entry.time <= this.ran) {
      this.replay();
      return true;
    }
    const woke = this.wakesBefore(entry.time) > 0;
    return this.run(entry.time, entry.inputs) || woke;
  }

  replay() {
    this.replays += 1;
    this.reset(this.module);
    this.run(this.module.time, []);
    for (const entry of this.entries) {
      this.wakesBefore(entry.time);
      this.run(entry.time, entry.inputs);
    }
  }

  // Runs the wakes up to and including time. Returns true if one ran.
  advanceTo(time) {
    return this.wakesBefore(time + 1n) > 0;
  }
}

// Downloads a module and stops unless its bytes have the SHA-256 digest in integrity.
export async function fetchModule({ url, integrity }, { fetch = globalThis.fetch, signal } = {}) {
  const timeout = AbortSignal.timeout(30_000);
  const response = await fetch(url, { signal: signal ? AbortSignal.any([signal, timeout]) : timeout });
  if (!response.ok) throw new ChannelError(`${url} returned HTTP ${response.status}`);
  const chunks = [];
  let length = 0;
  for await (const chunk of response.body ?? []) {
    length += chunk.byteLength;
    if (length > MAX_MODULE_BYTES) throw new ChannelError(`${url} exceeds 16 MiB`);
    chunks.push(chunk);
  }
  const bytes = Buffer.concat(chunks, length);
  if (`sha256-${createHash("sha256").update(bytes).digest("base64")}` !== integrity) {
    throw new ChannelError(`${url} does not have the digest that the channel gives`);
  }
  return bytes;
}

const sleep = (ms, signal) => new Promise((resolve) => {
  if (signal.aborted) return resolve();
  const timer = setTimeout(done, ms);
  function done() {
    clearTimeout(timer);
    signal.removeEventListener("abort", done);
    resolve();
  }
  signal.addEventListener("abort", done);
});

// Reads the log of one channel and sends input to it.
//
//   apply(entry)     async; called for each entry in sequence order, one at a time
//   onStatus(status) called when the connection, the role or the message changes
//   onTime(time)     called with the bigint time_ms of each time event
//   view             never send input, whatever the capability permits
//
// The role starts as "unknown": a capability is opaque, so the client learns that it is an
// editor from the first accepted batch and that it is a viewer from the first 403.
export class ChannelClient {
  constructor({ url, apply, onStatus = () => {}, onTime = () => {}, view = false, fetch = globalThis.fetch, retryMS = 250 }) {
    const channelURL = checkedURL(url, { loopback: true, name: "the channel URL" });
    if (channelURL.search || channelURL.hash) throw new ChannelError("the channel URL must not have a query or a fragment");
    this.host = channelURL.host;
    // Module URLs on a loopback HTTP server are only followed for a channel that is on one.
    this.loopback = isLoopbackHTTP(channelURL);
    this.eventsURL = `${channelURL.href.replace(/\/+$/, "")}/events`;
    this.apply = apply;
    this.onStatus = onStatus;
    this.onTime = onTime;
    this.fetch = fetch;
    this.retryMS = retryMS;
    this.status = { connection: "connecting", role: view ? "view-only" : "unknown", seq: null, message: "" };
    this.applied = null;
    this.pending = [];
    this.inflight = null;
    this.pumping = false;
    this.stopper = new AbortController();
  }

  setStatus(changes) {
    Object.assign(this.status, changes);
    this.onStatus({ ...this.status, host: this.host });
  }

  get canSend() {
    const { role, connection } = this.status;
    return (role === "unknown" || role === "editor") && connection !== "closed" && !this.stopper.signal.aborted;
  }

  stop() {
    this.stopper.abort();
  }

  // Resolves after the closed entry or stop(). Rejects when the client cannot continue.
  async run() {
    const { signal } = this.stopper;
    let failures = 0;
    while (!signal.aborted) {
      const before = this.applied;
      let problem = "";
      try {
        if (await this.readStream()) return;
      } catch (error) {
        if (error instanceof ChannelError) {
          this.stop();
          throw error;
        }
        problem = error?.cause?.code ?? error?.message ?? String(error);
      }
      if (signal.aborted) return;
      failures = this.applied === before ? failures + 1 : 0;
      this.setStatus({ connection: "reconnecting", message: problem });
      await sleep(Math.min(this.retryMS * 2 ** Math.min(failures, 5), 5000), signal);
    }
  }

  // Reads one stream to its end. Returns true after the closed entry.
  async readStream() {
    const cursor = this.applied;
    const reader = new AbortController();
    const signal = AbortSignal.any([reader.signal, this.stopper.signal]);
    const response = await this.fetch(this.eventsURL + (cursor === null ? "" : `?after=${cursor}`), {
      headers: { accept: "text/event-stream" }, redirect: "error", signal,
    });
    try {
      if (response.status === 404) throw new ChannelError("the channel does not exist or the server deleted it");
      if (response.status >= 400 && response.status < 500 && response.status !== 429) {
        throw new ChannelError(`the server refused the log request with HTTP ${response.status}`);
      }
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      if (!(response.headers.get("content-type") ?? "").toLowerCase().startsWith("text/event-stream")) {
        throw new ChannelError("the server did not answer with text/event-stream");
      }
      this.setStatus({ connection: "connected", message: "" });
      const parser = new SSEParser();
      const decoder = new TextDecoder();
      let first = true;
      for await (const chunk of response.body) {
        for (const event of parser.push(decoder.decode(chunk, { stream: true }))) {
          if (event.event === "time") {
            this.onTime(parseTimeEvent(event));
            continue;
          }
          const entry = parseEntry(event, { loopback: this.loopback });
          const wasFirst = first;
          first = false;
          if (this.applied === null) {
            if (entry.type !== "module") throw new ChannelError("the log does not start with a module entry");
          } else if (entry.seq <= this.applied) {
            continue;
          } else if (entry.seq !== this.applied + 1 && entry.type !== "module") {
            // A module entry discards all state before it, so a gap before one is harmless:
            // the server removed entries that the cursor asked for. Any other gap at the
            // start of a stream means the server cannot supply the entries.
            if (wasFirst) throw new ChannelError(`the server does not have the log entries after ${this.applied}`);
            return false;
          }
          await this.apply(entry);
          if (this.stopper.signal.aborted) return false;
          this.applied = entry.seq;
          if (entry.type === "update" && entry.updateID === this.inflight?.id) this.confirm();
          if (entry.type === "closed") {
            this.pending = [];
            this.setStatus({ connection: "closed", seq: entry.seq, message: entry.reason });
            this.stop();
            return true;
          }
          this.setStatus({ seq: entry.seq });
        }
      }
      return false;
    } finally {
      reader.abort();
    }
  }

  confirm() {
    this.inflight.confirmed = true;
    this.inflight.abort.abort();
    if (this.status.role === "unknown") this.setStatus({ role: "editor" });
  }

  // Queues inputs for the next batch. Nothing is applied here: an input changes shared
  // state only when it arrives in the log.
  send(inputs) {
    if (!this.canSend) return;
    for (const input of inputs) {
      const last = this.pending.at(-1);
      // Only the latest position of a pointer that keeps the same buttons matters.
      if (input.type === "pointer" && last?.type === "pointer" && last.mask === input.mask) this.pending[this.pending.length - 1] = input;
      else if (this.pending.length < MAX_PENDING_INPUTS) this.pending.push(input);
      else this.setStatus({ message: "input dropped: the server is not confirming it" });
    }
    this.pump();
  }

  async pump() {
    if (this.pumping) return;
    this.pumping = true;
    try {
      while (this.pending.length && this.canSend) {
        const inputs = this.pending.splice(0, MAX_BATCH_INPUTS);
        this.inflight = { id: randomBytes(12).toString("base64url"), confirmed: false, abort: new AbortController() };
        await this.post(this.inflight, formatUpdateBody(this.inflight.id, inputs));
        this.inflight = null;
      }
    } finally {
      this.pumping = false;
    }
  }

  // Sends one batch until the server answers or the batch arrives in the log.
  async post(batch, body) {
    const stop = this.stopper.signal;
    for (let attempt = 0; !batch.confirmed && !stop.aborted; attempt += 1) {
      let status = 0;
      try {
        const response = await this.fetch(this.eventsURL, {
          method: "POST", headers: { "content-type": "text/event-stream" }, body, redirect: "error",
          signal: AbortSignal.any([batch.abort.signal, stop, AbortSignal.timeout(POST_TIMEOUT_MS)]),
        });
        status = response.status;
        await response.body?.cancel();
      } catch {
        // A timeout or a network failure: the batch stays pending.
      }
      if (batch.confirmed || stop.aborted) return;
      if (status === 202) {
        if (this.status.role === "unknown") this.setStatus({ role: "editor" });
        return;
      }
      if (status === 403) {
        this.pending = [];
        return this.setStatus({ role: "viewer" });
      }
      if (status === 410) {
        // The log reader shows the closed entry. Input that is not in the log is lost.
        this.pending = [];
        return this.setStatus({ role: "viewer", message: "the channel is closed; input that was not confirmed is lost" });
      }
      if (status === 404) {
        this.pending = [];
        return this.setStatus({ role: "viewer", message: "the channel no longer accepts input" });
      }
      if (status === 400 || status === 409) return this.setStatus({ message: `the server rejected an input batch (HTTP ${status})` });
      this.setStatus({ message: status ? `sending again (HTTP ${status})` : "sending again" });
      await sleep(Math.min(this.retryMS * 2 ** Math.min(attempt, 5), 5000), AbortSignal.any([batch.abort.signal, stop]));
    }
  }
}
