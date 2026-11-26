import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  ChannelClient, ChannelError, ChannelTimeline, formatUpdateBody, parseEntry, parseFieldLine, SSEParser,
} from "../npm/qipgui/qip-channel.mjs";
import { createChannelStageLoader, parseArgs, runGUI } from "../npm/qipgui/qipgui.mjs";
import { createChannelServer } from "../tools/qipgui-channel-server.mjs";

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(check, label = "condition") {
  for (let tries = 0; tries < 400; tries += 1) {
    if (await check()) return;
    await wait(10);
  }
  assert.fail(`timed out waiting for ${label}`);
}

async function startServer(t, options, modulePath = "gui/calculator.wasm", input) {
  const host = createChannelServer(options);
  await host.listen(0);
  t.after(() => host.close());
  const channel = host.createChannel(host.addModule(await readFile(modulePath)), input);
  return { host, channel };
}

const post = (url, body, headers = { "content-type": "text/event-stream" }) =>
  fetch(`${url}/events`, { method: "POST", headers, body });

const KEY = { type: "key", keysym: 97, flags: 1 };
const POINTER = { type: "pointer", mask: 1, x: 42, y: 18 };

// Reads a whole stream that the server ends, or the entries that arrive within a short time.
async function readLog(url, query = "", headers = {}, times = []) {
  const abort = new AbortController();
  const response = await fetch(`${url}/events${query}`, { headers, signal: abort.signal });
  if (!response.ok) return { status: response.status, entries: [] };
  const parser = new SSEParser();
  const entries = [];
  const timer = setTimeout(() => abort.abort(), 150);
  try {
    for await (const chunk of response.body) {
      for (const event of parser.push(Buffer.from(chunk).toString())) {
        if (event.event === "time") times.push({ after: entries.length, event });
        else entries.push(parseEntry(event, { loopback: true }));
      }
    }
  } catch (error) {
    if (error.name !== "AbortError") throw error;
  }
  clearTimeout(timer);
  return { status: 200, entries };
}

test("the SSE parser keeps data lines apart and drops an event that was cut off", () => {
  const parser = new SSEParser();
  const text = "id: 42\nevent: update\ndata: time_ms=1830&update_id=f8d1c2\ndata: type=key&keysym=97&flags=1\n" +
    "data: type=pointer&mask=1&x=42&y=18\n\n: comment\n\nid: 43\nevent: closed\ndata: reason=li";
  // Any split of the bytes gives the same events.
  const events = [...parser.push(text.slice(0, 31)), ...parser.push(text.slice(31, 90)), ...parser.push(text.slice(90))];
  assert.equal(events.length, 1);
  assert.ok(parser.partial);
  assert.deepEqual(parseEntry(events[0]), {
    seq: 42, type: "update", time: 1830n, updateID: "f8d1c2",
    inputs: [{ type: "key", keysym: 97, flags: 1 }, { type: "pointer", mask: 1, x: 42, y: 18 }],
  });
  assert.equal(formatUpdateBody("f8d1c2", [KEY, POINTER]),
    "event: update\ndata: update_id=f8d1c2\ndata: type=key&keysym=97&flags=1\ndata: type=pointer&mask=1&x=42&y=18\n\n");
});

test("entries follow the field rules of the protocol", () => {
  assert.equal(parseFieldLine("a=1&a=2&b=x+y%26").get("a"), "1");
  assert.equal(parseFieldLine("a=1&a=2&b=x+y%26").get("b"), "x y&");
  const entry = (event, ...data) => parseEntry({ id: "7", event, data });
  const integrity = "sha256-EXAMPLExCALCULATORxMODULExDIGESTxNOTxREALxA%3D";
  const module = entry("module", `time_ms=1&url=https%3A%2F%2Fexample.org%2Fgui%2Fcalculator.wasm&integrity=${integrity}&input=aGVsbG8%3D&later=1`);
  assert.equal(module.url, "https://example.org/gui/calculator.wasm");
  assert.equal(Buffer.from(module.input).toString(), "hello");
  assert.deepEqual(entry("closed", "reason=limit"), { seq: 7, type: "closed", reason: "limit" });
  for (const [type, ...data] of [
    ["update", "time_ms=5&update_id=a"],                                   // no inputs
    ["update", "time_ms=0&update_id=a", "type=key&keysym=1&flags=1"],      // time_ms below 1
    ["update", "time_ms=5&update_id=a b", "type=key&keysym=1&flags=1"],    // bad update_id
    ["update", "time_ms=5&update_id=a", "type=key&keysym=+1&flags=1"],     // "+" is a space
    ["update", "time_ms=5&update_id=a", "type=key&keysym=4294967296&flags=1"],
    ["update", "time_ms=5&update_id=a", "type=pointer&mask=1&x=1"],        // y is missing
    ["update", "time_ms=5&update_id=a", "type=wheel&x=1"],
    ["module", `time_ms=1&url=http%3A%2F%2Fexample.org%2Fa.wasm&integrity=${integrity}`], // not HTTPS
    ["module", "time_ms=1&url=https%3A%2F%2Fexample.org%2Fa.wasm&integrity=sha256-AAAA"],
    ["module", `time_ms=1&url=https%3A%2F%2Fexample.org%2Fa.wasm&integrity=${integrity}&input=a`],
    ["closed", "other=1"],
    ["snapshot", "a=1"],
    ["update"],
  ]) assert.throws(() => entry(type, ...data), ChannelError, `${type} ${data.join(" | ")}`);
  assert.throws(() => parseEntry({ id: null, event: "closed", data: ["reason=x"] }), ChannelError);
  // A loopback HTTP module is only accepted when the channel itself is on loopback.
  const local = `time_ms=1&url=http%3A%2F%2F127.0.0.1%3A1%2Fa.wasm&integrity=${integrity}`;
  assert.throws(() => entry("module", local), ChannelError);
  assert.equal(parseEntry({ id: "0", event: "module", data: [local] }, { loopback: true }).url, "http://127.0.0.1:1/a.wasm");
  assert.throws(() => new ChannelClient({ url: "http://example.org/v1/channels/x", apply() {} }), /HTTPS/);
});

test("connect arguments", () => {
  assert.deepEqual(parseArgs(["connect", "--view", "https://sync.example.org/v1/channels/abc", "raster.wasm", "-u", "a=1"]), {
    components: [{ path: "raster.wasm", uniforms: ["a=1"] }], hosts: [], size: "auto", transport: "direct", stats: false,
    connect: "https://sync.example.org/v1/channels/abc", view: true, yes: false,
  });
  assert.throws(() => parseArgs(["connect"]), /channel URL/);
  assert.throws(() => parseArgs(["connect", "https://x.example/c", "-i", "file"]), /-i/);
  assert.throws(() => parseArgs(["connect", "https://x.example/c", "-u", "a=1"]), /transform/);
  assert.throws(() => parseArgs(["gui.wasm", "--view"]), /unknown option/);
});

test("the server orders input, answers retries with the first result, and rejects bad batches", async (t) => {
  const { channel } = await startServer(t);
  const body = formatUpdateBody("first", [KEY, POINTER]);
  const accepted = await post(channel.writeURL, body);
  assert.equal(accepted.status, 202);
  const result = parseFieldLine((await accepted.text()).trim());
  assert.equal(result.get("seq"), "1");

  const retry = await post(channel.writeURL, body);
  assert.equal(retry.status, 202);
  assert.deepEqual([...parseFieldLine((await retry.text()).trim())], [...result]);
  assert.equal((await post(channel.writeURL, formatUpdateBody("first", [KEY]))).status, 409);

  assert.equal((await post(channel.readURL, formatUpdateBody("reader", [KEY]))).status, 403);
  assert.equal((await post(channel.writeURL.replace(/.$/, "-"), body)).status, 404);
  for (const bad of [
    body.slice(0, -1),                                             // no empty line at the end
    body + body.replace("first", "second"),                        // two events
    body.replaceAll("\n", "\r\n"),                                 // CRLF
    body.replace("event: update", "event: module"),
    `id: 9\n${body}`,
    body.replace("update_id=first", "time_ms=5&update_id=other"),
    "event: update\ndata: update_id=empty\n\n",                    // no inputs
    formatUpdateBody("bad id!", [KEY]),
    "event: update\ndata: update_id=bad\ndata: type=key&keysym=x&flags=1\n\n",
  ]) assert.equal((await post(channel.writeURL, bad)).status, 400, JSON.stringify(bad));
  assert.equal((await post(channel.writeURL, body, { "content-type": "text/plain" })).status, 400);
  assert.equal((await post(channel.writeURL, formatUpdateBody("big", Array(257).fill(KEY)))).status, 400);

  // The log holds one entry per accepted batch, with the lines of the batch unchanged.
  const { entries } = await readLog(channel.readURL);
  assert.deepEqual(entries.map(({ seq, type }) => [seq, type]), [[0, "module"], [1, "update"]]);
  assert.equal(entries[1].updateID, "first");
  assert.equal(String(entries[1].time), result.get("time_ms"));
  assert.deepEqual(entries[1].inputs, [KEY, POINTER]);
  assert.ok(entries[1].time > entries[0].time);
});

test("cursors, module replay start, closing and deletion", async (t) => {
  const { host, channel } = await startServer(t);
  for (const id of ["a", "b", "c"]) assert.equal((await post(channel.writeURL, formatUpdateBody(id, [KEY]))).status, 202);
  const seqs = async (...args) => (await readLog(channel.readURL, ...args)).entries.map(({ seq }) => seq);
  assert.deepEqual(await seqs("?after=1"), [2, 3]);
  assert.deepEqual(await seqs("", { "last-event-id": "2" }), [3]);
  assert.equal((await readLog(channel.readURL, "?after=99")).status, 400);
  assert.equal((await readLog(channel.readURL, "?after=-1")).status, 400);

  // A stream with no cursor starts at the most recent module entry.
  channel.appendPrefetch(host.addModule(await readFile("gui/snake.wasm")));
  channel.appendModule(host.addModule(await readFile("gui/snake.wasm")));
  await post(channel.writeURL, formatUpdateBody("d", [KEY]));
  assert.deepEqual(await seqs(), [5, 6]);
  assert.deepEqual(await seqs("?after=3"), [4, 5, 6]);

  // A closed channel refuses input, even a new batch, but stays readable.
  channel.close("operator");
  assert.equal((await post(channel.writeURL, formatUpdateBody("e", [KEY]))).status, 410);
  assert.equal((await post(channel.writeURL, formatUpdateBody("d", [KEY]))).status, 202, "a retry still gets its first result");
  const closed = (await readLog(channel.readURL)).entries;
  assert.deepEqual(closed.map(({ type }) => type), ["module", "update", "closed"]);
  assert.equal(closed.at(-1).reason, "operator");

  host.deleteChannel(channel);
  assert.equal((await readLog(channel.readURL)).status, 404);
  assert.equal((await post(channel.writeURL, formatUpdateBody("f", [KEY]))).status, 404);
});

test("the server reports the capability type with Allow on HEAD, GET and POST", async (t) => {
  const { host, channel } = await startServer(t);
  const events = (url, method) => fetch(`${url}/events`, { method });
  for (const [url, allow] of [[channel.readURL, "GET"], [channel.writeURL, "GET, POST"]]) {
    const head = await events(url, "HEAD");
    assert.equal(head.status, 200);
    assert.equal(head.headers.get("allow"), allow);
    assert.equal(head.headers.get("content-type"), "text/event-stream");
    assert.equal((await head.arrayBuffer()).byteLength, 0);
    assert.equal(channel.streams.size, 0, "HEAD does not register a stream");
    const get = await fetch(`${url}/events`, { signal: AbortSignal.timeout(500) });
    assert.equal(get.headers.get("allow"), allow);
    await get.body.cancel();
    await until(() => channel.streams.size === 0, "the cancelled stream to close");
    const put = await events(url, "PUT");
    assert.equal(put.status, 405);
    assert.equal(put.headers.get("allow"), allow);
  }
  assert.equal((await fetch(`${channel.readURL}/events?after=99`, { method: "HEAD" })).status, 400, "HEAD checks the cursor like GET");

  const refused = await post(channel.readURL, formatUpdateBody("a", [KEY]));
  assert.equal(refused.status, 403);
  assert.equal(refused.headers.get("allow"), "GET");
  const accepted = await post(channel.writeURL, formatUpdateBody("a", [KEY]));
  assert.equal(accepted.status, 202);
  assert.equal(accepted.headers.get("allow"), "GET, POST");

  // A closed channel takes no input, so every capability says GET.
  channel.close("operator");
  const gone = await post(channel.writeURL, formatUpdateBody("b", [KEY]));
  assert.equal(gone.status, 410);
  assert.equal(gone.headers.get("allow"), "GET");
  assert.equal((await post(channel.writeURL, formatUpdateBody("a", [KEY]))).headers.get("allow"), "GET", "a retry after closing");
  assert.equal((await events(channel.writeURL, "HEAD")).headers.get("allow"), "GET");
  host.deleteChannel(channel);
  const missing = await events(channel.writeURL, "HEAD");
  assert.equal(missing.status, 404);
  assert.equal(missing.headers.get("allow"), null);
});

test("the server limits the input rate and the log size", async (t) => {
  const { channel } = await startServer(t, { limits: { batchesPerSecond: 2, logEntries: 5 } });
  const statuses = [];
  for (const id of ["a", "b", "c"]) statuses.push((await post(channel.writeURL, formatUpdateBody(id, [KEY]))).status);
  assert.deepEqual(statuses, [202, 202, 429]);
  await wait(600);
  assert.equal((await post(channel.writeURL, formatUpdateBody("c", [KEY]))).status, 202);
  // The fifth entry is the closed entry.
  const { entries } = await readLog(channel.readURL);
  assert.deepEqual(entries.map(({ type }) => type), ["module", "update", "update", "update", "closed"]);
  assert.equal(entries.at(-1).reason, "limit");
});

function collector(url, options = {}) {
  const entries = [];
  const statuses = [];
  const client = new ChannelClient({
    url, retryMS: 10, ...options,
    apply: async (entry) => { entries.push(entry); },
    onStatus: (status) => statuses.push(status),
  });
  return { client, entries, statuses, done: client.run() };
}

test("clients apply only the log, confirm their own batches, and reconnect without loss", async (t) => {
  const { host, channel } = await startServer(t);
  const editor = collector(channel.writeURL);
  const viewer = collector(channel.readURL);
  const watcher = collector(channel.writeURL, { view: true });
  t.after(() => [editor, viewer, watcher].forEach(({ client }) => client.stop()));
  await until(() => viewer.entries.length === 1 && editor.entries.length === 1);

  editor.client.send([KEY]);
  assert.equal(editor.entries.length, 1, "sending applies nothing");
  await until(() => viewer.entries.length === 2 && editor.entries.length === 2, "the first update");
  assert.equal(editor.client.status.role, "editor");

  // A read capability gets 403 and then stops sending. --view never sends.
  viewer.client.send([KEY]);
  watcher.client.send([KEY]);
  await until(() => viewer.client.status.role === "viewer");
  viewer.client.send([KEY]);
  await wait(50);
  assert.equal(channel.nextSeq, 2);
  assert.equal(watcher.client.status.role, "view-only");

  // Entries that arrive while a client is cut off come in after it reconnects.
  channel.dropStreams();
  for (let index = 0; index < 20; index += 1) editor.client.send([{ type: "key", keysym: 48 + index, flags: 1 }]);
  await until(() => channel.nextSeq > 2 && editor.client.pending.length === 0 && !editor.client.inflight, "all batches posted");
  await until(() => viewer.entries.length === channel.nextSeq && editor.entries.length === channel.nextSeq, "catch-up");
  assert.deepEqual(viewer.entries, editor.entries);
  assert.deepEqual(viewer.entries.map(({ seq }) => seq), [...Array(channel.nextSeq).keys()]);
  // One editor's inputs keep their order across batches.
  assert.deepEqual(editor.entries.slice(2).flatMap(({ inputs }) => inputs.map(({ keysym }) => keysym)), [...Array(20).keys()].map((n) => 48 + n));
  assert.ok(viewer.statuses.some(({ connection }) => connection === "reconnecting"));

  // Pointer moves that wait for the same batch collapse to the latest position.
  const before = channel.nextSeq;
  for (let x = 0; x < 50; x += 1) editor.client.send([{ type: "pointer", mask: 0, x, y: 0 }]);
  await until(() => editor.entries.at(-1).inputs?.at(-1).x === 49, "the last pointer position");
  assert.ok(channel.nextSeq - before <= 3, "50 moves take at most a few batches");

  channel.close("operator");
  await Promise.all([editor.done, viewer.done, watcher.done]);
  assert.equal(viewer.entries.at(-1).type, "closed");
  assert.equal(viewer.client.status.connection, "closed");
  editor.client.send([KEY]);
  assert.equal(editor.client.pending.length, 0, "a closed channel takes no input");
  void host;
});

test("a POST that gets no answer is sent again with the same ID and makes one entry", async (t) => {
  const { channel } = await startServer(t);
  let lost = 2;
  const bodies = [];
  const flaky = async (url, options = {}) => {
    if (options.method !== "POST") return fetch(url, options);
    bodies.push(options.body);
    if (lost-- > 0) {
      // The server stores the first one, but its answer never reaches the client.
      if (lost === 1) await fetch(url, options);
      throw new TypeError("fetch failed");
    }
    return fetch(url, options);
  };
  const editor = collector(channel.writeURL, { fetch: flaky });
  t.after(() => editor.client.stop());
  editor.client.send([KEY]);
  await until(() => !editor.client.inflight && editor.client.pending.length === 0 && editor.entries.length === 2);
  await wait(50);
  assert.equal(channel.nextSeq, 2, "one entry");
  assert.ok(bodies.length >= 1 && new Set(bodies).size === 1, "every attempt has the same body");
});

test("a stale cursor after the server removes old entries restarts at the module entry", async (t) => {
  const { host, channel } = await startServer(t, { prune: true });
  const viewer = collector(channel.readURL);
  t.after(() => viewer.client.stop());
  await post(channel.writeURL, formatUpdateBody("a", [KEY]));
  await until(() => viewer.entries.length === 2);
  // While the viewer is away the server appends 2 and 3, switches the module at 4, which
  // removes 0 to 3, and appends 5.
  const real = viewer.client.fetch;
  let hold = true;
  viewer.client.fetch = async (...args) => { while (hold) await wait(5); return real(...args); };
  channel.dropStreams();
  await post(channel.writeURL, formatUpdateBody("b", [KEY]));
  await post(channel.writeURL, formatUpdateBody("c", [KEY]));
  channel.appendModule(host.addModule(await readFile("gui/snake.wasm")));
  await post(channel.writeURL, formatUpdateBody("d", [KEY]));
  hold = false;
  await until(() => viewer.entries.at(-1).seq === 5);
  assert.deepEqual(viewer.entries.map(({ seq, type }) => [seq, type]), [[0, "module"], [1, "update"], [4, "module"], [5, "update"]]);
});

test("a log that does not start with a module, or has an unknown entry, stops the client", async () => {
  const stream = (text) => async () => new Response(text, { headers: { "content-type": "text/event-stream" } });
  const run = (text) => collector("https://sync.example.org/v1/channels/x", { fetch: stream(text) }).done;
  await assert.rejects(run("id: 3\nevent: update\ndata: time_ms=5&update_id=a\ndata: type=key&keysym=1&flags=1\n\n"), /does not start with a module/);
  const module = "id: 0\nevent: module\ndata: time_ms=1&url=https%3A%2F%2Fexample.org%2Fa.wasm&integrity=sha256-EXAMPLExCALCULATORxMODULExDIGESTxNOTxREALxA%3D\n\n";
  await assert.rejects(run(`${module}id: 1\nevent: snapshot\ndata: a=1\n\n`), /unknown type snapshot/);
  await assert.rejects(run(`${module}id: 1\nevent: update\ndata: time_ms=5&update_id=a\n\n`), /not valid/);
  const missing = collector("https://sync.example.org/v1/channels/x", { fetch: async () => new Response("", { status: 404 }) });
  await assert.rejects(missing.done, /does not exist/);
});

class FakeTTY extends EventEmitter {
  constructor() {
    super();
    this.isTTY = true;
    this.isRaw = false;
    this.columns = 100;
    this.rows = 30;
    this.chunks = [];
  }
  setRawMode(value) { this.isRaw = value; }
  resume() {}
  pause() {}
  write(value, callback) {
    this.chunks.push(String(value));
    if (String(value).includes("a=q")) {
      queueMicrotask(() => this.input?.emit("data", Buffer.from("\x1b_Gi=31;OK\x1b\\\x1b[4;600;1000t\x1b[6;20;10t\x1b[?62;c")));
    }
    callback?.();
    return true;
  }
}

// Runs qipgui connect against a fake terminal and keeps the stages it loads.
function terminal(url, { view = false } = {}) {
  const stdin = new FakeTTY();
  const stdout = new FakeTTY();
  stdout.input = stdin;
  const loader = createChannelStageLoader();
  const stages = [];
  const tracking = { prefetch: (entry) => loader.prefetch(entry), load: async (entry) => { stages.push(await loader.load(entry)); return stages.at(-1); } };
  const state = { stage: null, timeline: null };
  const onStage = (stage, timeline) => Object.assign(state, { stage, timeline });
  const running = runGUI({ stdin, stdout, channel: { url, view, loader: tracking, retryMS: 10, onStage } });
  const frame = () => renderBytes(state.stage);
  const frames = () => stdout.chunks.filter((chunk) => chunk.includes("a=T")).length;
  return { stdin, stdout, running, stages, state, frame, frames, text: () => stdout.chunks.join("") };
}

function renderBytes(stage) {
  const { exports } = stage.component;
  const packed = BigInt.asUintN(64, exports.render(0));
  return Buffer.from(new Uint8Array(exports.memory.buffer, Number(packed >> 32n), Number(packed & 0xffff_ffffn)));
}

// A timeline that runs a stage with no terminal, as a plain replay of a log.
function plainTimeline(first) {
  const box = { stage: null };
  box.timeline = new ChannelTimeline({
    reset(entry) {
      box.stage = box.stage ? box.stage.fresh() : first;
      const { exports } = box.stage.component;
      if (entry.input.byteLength) new Uint8Array(exports.memory.buffer, exports.input_ptr(), entry.input.byteLength).set(entry.input);
      exports.render(entry.input.byteLength);
    },
    update(time, inputs) {
      const { exports } = box.stage.component;
      exports.begin_update_at(time);
      for (const event of inputs) {
        if (event.type === "key") exports.key_event(event.keysym, event.flags);
        else exports.pointer_event(event.mask, event.x, event.y);
      }
      return { wake: exports.finish_update(), accepted: true };
    },
  });
  return box;
}

// The frame that a plain replay of the log shows after the updates and wakes up to time.
async function replayTo(entries, time) {
  const module = entries.findLast((entry) => entry.type === "module" && entry.time <= time);
  const box = plainTimeline(await createChannelStageLoader().load(module));
  box.timeline.startModule(module);
  for (const entry of entries) {
    if (entry.type === "update" && entry.seq > module.seq && entry.time <= time) box.timeline.applyUpdate(entry);
  }
  box.timeline.advanceTo(time);
  assert.equal(box.timeline.ran <= time, true);
  return renderBytes(box.stage);
}

test("two qipgui terminals on one channel show the same state as a replay of the log", async (t) => {
  const { host, channel } = await startServer(t);
  const editor = terminal(channel.writeURL);
  const viewer = terminal(channel.readURL);
  const errors = [];
  for (const { running } of [editor, viewer]) running.catch((error) => errors.push(error));
  await until(() => editor.frames() >= 1 && viewer.frames() >= 1, "first frames");
  const blank = editor.frame();

  // Keys typed in the editor reach the server, not the local component.
  editor.stdin.emit("data", Buffer.from("12+30\r"));
  editor.stdin.emit("data", Buffer.from("\x1b[<0;40;40M\x1b[<0;40;40m"));
  // Input in the viewer's terminal changes nothing.
  viewer.stdin.emit("data", Buffer.from("999"));
  await until(() => channel.nextSeq >= 2 && channel.streams.size === 2);
  await wait(150);
  assert.notDeepEqual(editor.frame(), blank, "the calculator shows the input");
  assert.deepEqual(viewer.frame(), editor.frame());
  assert.ok(viewer.frames() >= 2, "the viewer draws the update");
  assert.match(editor.text(), /connect 127\.0\.0\.1:\d+ · editor: your input is sent · seq \d+/);
  assert.match(viewer.text(), /connect 127\.0\.0\.1:\d+ · viewer · seq \d+/);

  // A client that joins late replays the log to the same state.
  const late = terminal(channel.readURL, { view: true });
  late.running.catch((error) => errors.push(error));
  await until(() => late.frames() >= 1 && late.stages.length === 1);
  await wait(50);
  assert.deepEqual(late.frame(), editor.frame());
  assert.match(late.text(), /view only/);

  // So does a plain replay of the stored log against a new instance.
  const { entries } = await readLog(channel.readURL);
  const loader = createChannelStageLoader();
  const { exports } = (await loader.load(entries[0])).component;
  exports.render(0);
  for (const entry of entries) {
    exports.begin_update_at(entry.time);
    for (const event of entry.inputs ?? []) {
      if (event.type === "key") exports.key_event(event.keysym, event.flags);
      else exports.pointer_event(event.mask, event.x, event.y);
    }
    assert.equal(exports.finish_update(), entry.time);
  }
  const packed = BigInt.asUintN(64, exports.render(0));
  assert.deepEqual(Buffer.from(new Uint8Array(exports.memory.buffer, Number(packed >> 32n), Number(packed & 0xffff_ffffn))), editor.frame());

  // The server switches the module: every terminal replaces its component.
  const paint = host.addModule(await readFile("gui/paint.wasm"));
  channel.appendPrefetch(paint);
  channel.appendModule(paint);
  await until(() => [editor, viewer, late].every(({ stages }) => stages.length === 2), "module switch");
  editor.stdin.emit("data", Buffer.from("\x1b[<0;200;200M\x1b[<32;260;240M\x1b[<0;260;240m"));
  const seq = channel.nextSeq;
  await until(() => channel.nextSeq > seq);
  await wait(150);
  assert.deepEqual(viewer.frame(), editor.frame());
  assert.deepEqual(late.frame(), editor.frame());

  // Closing keeps the last frame and says so. The terminals stay up until Ctrl-C.
  channel.close("operator");
  await until(() => /channel closed \(operator\)/.test(viewer.text()), "closed status");
  for (const { stdin } of [editor, viewer, late]) stdin.emit("data", Buffer.from("\x03"));
  await Promise.all([editor.running, viewer.running, late.running].map((running) => running.catch(() => {})));
  assert.deepEqual(errors, []);
  assert.ok(editor.text().endsWith("\x1b[?1049l"), "restores the screen");
  process.exitCode = 0;
});

test("a module that does not match its digest stops qipgui", async (t) => {
  const { host, channel } = await startServer(t);
  const good = host.addModule(await readFile("gui/calculator.wasm"));
  const other = host.addModule(await readFile("gui/paint.wasm"));
  channel.appendModule({ url: good.url, integrity: other.integrity });
  await assert.rejects(terminal(channel.readURL, { view: true }).running, /does not have the digest/);
  process.exitCode = 0;
});

const SNAKE_UP = { type: "key", keysym: 0xff52, flags: 1 };
const SNAKE_LEFT = { type: "key", keysym: 0xff51, flags: 1 };
const entryAt = (seq, time, inputs) => ({ seq, type: "update", time: BigInt(time), updateID: `u${seq}`, inputs });

test("wakes that run ahead of the log are replayed when an earlier entry arrives", async () => {
  const data = await readFile("gui/snake.wasm");
  const module = { seq: 0, type: "module", time: 1n, input: new Uint8Array() };
  const fetchless = async () => new Response(data);
  const loaderFor = () => createChannelStageLoader({ fetch: fetchless });
  const integrity = `sha256-${(await import("node:crypto")).createHash("sha256").update(data).digest("base64")}`;
  const moduleEntry = { ...module, url: "https://example.org/snake.wasm", integrity };
  const updates = [entryAt(1, 500, [SNAKE_UP]), entryAt(2, 1300, [SNAKE_LEFT])];

  // The reference applies each entry before any wake after it.
  const reference = plainTimeline(await loaderFor().load(moduleEntry));
  reference.timeline.startModule(moduleEntry);
  for (const entry of updates) reference.timeline.applyUpdate(entry);
  reference.timeline.advanceTo(2000n);

  // This client runs its wakes to 900 before the first entry arrives, and to 1700 before
  // the second. Each entry is then earlier than the wakes that ran, so it replays.
  const ahead = plainTimeline(await loaderFor().load(moduleEntry));
  ahead.timeline.startModule(moduleEntry);
  assert.ok(ahead.timeline.advanceTo(900n), "snake asks for wakes");
  ahead.timeline.applyUpdate(updates[0]);
  assert.equal(ahead.timeline.replays, 1);
  ahead.timeline.advanceTo(1700n);
  ahead.timeline.applyUpdate(updates[1]);
  assert.equal(ahead.timeline.replays, 2);
  ahead.timeline.advanceTo(2000n);
  assert.equal(ahead.timeline.ran, reference.timeline.ran);
  assert.deepEqual(renderBytes(ahead.stage), renderBytes(reference.stage));
  // Without the replay, the keys would apply after wakes that should follow them.
  const stale = plainTimeline(await loaderFor().load(moduleEntry));
  stale.timeline.startModule(moduleEntry);
  stale.timeline.advanceTo(900n);
  stale.timeline.run(901n, updates[0].inputs);
  stale.timeline.advanceTo(1700n);
  stale.timeline.run(1701n, updates[1].inputs);
  stale.timeline.advanceTo(2000n);
  assert.notDeepEqual(renderBytes(stale.stage), renderBytes(reference.stage));

  // A client that stays behind the log never replays and gets the same state.
  const behind = plainTimeline(await loaderFor().load(moduleEntry));
  behind.timeline.startModule(moduleEntry);
  behind.timeline.advanceTo(400n);
  for (const entry of updates) behind.timeline.applyUpdate(entry);
  behind.timeline.advanceTo(2000n);
  assert.equal(behind.timeline.replays, 0);
  assert.deepEqual(renderBytes(behind.stage), renderBytes(reference.stage));

  // The clock estimate keeps the smallest delay that it sees.
  const clock = new ChannelTimeline({ reset() {}, update: (time) => ({ wake: time, accepted: false }) });
  assert.equal(clock.now(0), null);
  clock.observe(1000n, 50);
  clock.observe(1100n, 200);
  assert.equal(clock.now(300), 1250n);
  assert.throws(() => new ChannelTimeline({ reset() {}, update: () => ({ wake: 0n }) }).startModule(moduleEntry), /wake time/);
});

test("the server sends its channel time after the replay and with each keepalive", async (t) => {
  const { channel } = await startServer(t, { keepaliveMS: 40 });
  await post(channel.writeURL, formatUpdateBody("a", [KEY]));
  const times = [];
  const { entries } = await readLog(channel.readURL, "", {}, times);
  assert.equal(entries.length, 2);
  assert.ok(times.length >= 2, "a time event after the replay and one or more keepalives");
  assert.equal(times[0].after, 2);
  assert.equal(times[0].event.id, null);
  const values = times.map(({ event }) => BigInt(parseFieldLine(event.data[0]).get("time_ms")));
  assert.ok(values[0] >= entries[1].time);
  assert.ok(values.every((value, index) => index === 0 || value >= values[index - 1]));
});

test("a timed component animates in every terminal and matches a replay of the log", async (t) => {
  const { channel } = await startServer(t, { keepaliveMS: 100 }, "gui/snake.wasm");
  const editor = terminal(channel.writeURL);
  const viewer = terminal(channel.readURL, { view: true });
  const errors = [];
  for (const { running } of [editor, viewer]) running.catch((error) => errors.push(error));
  await until(() => editor.state.timeline?.ran > 300n && viewer.state.timeline?.ran > 300n, "wakes before any input");
  const framesBefore = viewer.frames();
  await wait(400);
  assert.ok(viewer.frames() > framesBefore, "the viewer draws wakes with no new entries");

  editor.stdin.emit("data", Buffer.from("\x1b[A"));
  await until(() => channel.nextSeq >= 2, "the editor's key in the log");
  await wait(300);
  editor.stdin.emit("data", Buffer.from("\x1b[D"));
  await until(() => channel.nextSeq >= 3, "the second key in the log");
  await wait(300);
  assert.deepEqual(errors, []);

  // Each terminal shows what a plain replay shows at the last time that it ran.
  const { entries } = await readLog(channel.readURL);
  for (const { state } of [editor, viewer]) {
    const { ran } = state.timeline;
    assert.ok(ran > entries.at(-1).time, "wakes ran after the last entry");
    assert.deepEqual(state.stage && renderBytes(state.stage), await replayTo(entries, ran));
  }

  channel.close("operator");
  await until(() => /channel closed/.test(viewer.text()) && /channel closed/.test(editor.text()));
  const { ran } = viewer.state.timeline;
  await wait(300);
  assert.equal(viewer.state.timeline.ran, ran, "no wakes run after the closed entry");
  for (const { stdin } of [editor, viewer]) stdin.emit("data", Buffer.from("\x03"));
  await Promise.all([editor.running, viewer.running].map((running) => running.catch(() => {})));
  assert.deepEqual(errors, []);
  process.exitCode = 0;
});
