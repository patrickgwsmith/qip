// Compares <qip-play>'s two SVG presentation paths in headless Chrome:
// "blob" (Blob + object URL into an <img>, the default) and "inline"
// (DOMParser + replaceChildren, the svg-inline attribute). Frames come from
// gui/qip-logo-creature.wasm's intro animation; a "heavy" set repeats each
// frame's shapes to see how the cost scales with markup size.
//
// Usage: node tools/bench-qip-play-svg-present.mjs [--rounds N] [--chrome PATH]
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const args = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : fallback;
};
const rounds = Number(arg("--rounds", 4));
const chromePath = arg("--chrome", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome");
const port = 9300 + Math.floor(Math.random() * 500);

// Capture the intro animation, one frame per 15 ms step, as <qip-play> would.
const bytes = await readFile("gui/qip-logo-creature.wasm");
const e = new WebAssembly.Instance(new WebAssembly.Module(bytes), {}).exports;
e.uniform_set_seed(7);
e.uniform_set_intro(1);
const read = () => {
  const result = BigInt.asUintN(64, e.render(0));
  return new TextDecoder().decode(new Uint8Array(e.memory.buffer, Number(result >> 32n), Number(result & 0xffffffffn)));
};
const frames = [read()];
for (let time = 1; time < 4000; time += 15) {
  e.begin_update_at(BigInt(time));
  e.finish_update();
  frames.push(read());
}
const heavy = frames.map((svg) => {
  const open = svg.indexOf(">") + 1;
  const close = svg.lastIndexOf("</svg>");
  return svg.slice(0, open) + svg.slice(open, close).repeat(50) + svg.slice(close);
});
const avgBytes = (set) => Math.round(set.reduce((n, s) => n + s.length, 0) / set.length);

const page = String.raw`
const enc = new TextEncoder();
const sets = {};
window.loadSet = (name, svgs) => { sets[name] = svgs.map((s) => enc.encode(s)); };
const nextPaint = () => new Promise((r) => requestAnimationFrame(() => setTimeout(r, 0)));

function surface(kind, w, h) {
  document.body.replaceChildren();
  const el = document.createElement(kind === "inline" ? "div" : "img");
  el.style.cssText = "display:block;width:" + w + "px;height:" + h + "px";
  document.body.append(el);
  return el;
}

// Same steps as qip-play.js _presentSVGOutput, minus stats bookkeeping.
function presentInline(el, source) {
  const markup = new TextDecoder("utf-8", { fatal: true }).decode(source);
  const root = new DOMParser().parseFromString(markup, "image/svg+xml").documentElement;
  root.style.display = "block";
  root.style.width = "100%";
  root.style.height = "100%";
  el.replaceChildren(root);
  return null;
}
function presentBlob(el, source, state) {
  const blob = new Blob([source.slice()], { type: "image/svg+xml" });
  const nextURL = URL.createObjectURL(blob);
  const previousURL = state.url;
  state.url = nextURL;
  const loaded = new Promise((resolve) => {
    el.onload = () => { if (previousURL) URL.revokeObjectURL(previousURL); resolve(); };
    el.onerror = resolve;
  });
  el.src = nextURL;
  return loaded;
}

// latency: present, wait for the frame to be on screen, then present the next.
// paced: present one frame per rAF, like an animation, and record frame gaps.
window.runCase = async (kind, setName, w, h, mode) => {
  const set = sets[setName];
  const el = surface(kind, w, h);
  const state = { url: "" };
  const present = kind === "inline" ? presentInline : presentBlob;
  // Warm up on a few frames.
  for (let i = 0; i < 10; i++) { await present(el, set[i], state); await nextPaint(); }
  const sync = [], visible = [], gaps = [];
  let late = 0;
  const t0 = performance.now();
  if (mode === "latency") {
    for (const source of set) {
      const a = performance.now();
      const loaded = present(el, source, state);
      sync.push(performance.now() - a);
      if (loaded) await loaded;
      await nextPaint();
      visible.push(performance.now() - a);
    }
  } else {
    let pending = null;
    let last = 0;
    await new Promise((done) => {
      let i = 0;
      const tick = (now) => {
        if (last) gaps.push(now - last);
        last = now;
        if (pending) late++; // previous <img> load hadn't finished by this frame
        if (i === set.length) return done();
        const a = performance.now();
        const loaded = present(el, set[i++], state);
        sync.push(performance.now() - a);
        if (loaded) { pending = loaded; loaded.then(() => { pending = null; }); }
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    });
  }
  const total = performance.now() - t0;
  if (state.url) URL.revokeObjectURL(state.url);
  return { sync, visible, gaps, late, total };
};
`;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const profile = await mkdtemp(join(tmpdir(), "qip-svg-bench-"));
const chrome = spawn(chromePath, [
  "--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`,
  "--window-size=1000,800", "--no-first-run", "about:blank",
], { stdio: "ignore" });
let ws;
try {
  let target;
  for (let i = 0; i < 50 && !target; i++) {
    await sleep(200);
    try { target = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).find((t) => t.type === "page"); } catch {}
  }
  if (!target) throw new Error("Chrome did not start");
  ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener("open", r));
  let id = 0;
  const pending = new Map();
  ws.addEventListener("message", (m) => { const d = JSON.parse(m.data); if (d.id) pending.get(d.id)?.(d); });
  const send = (method, params = {}) => new Promise((r) => { const n = ++id; pending.set(n, r); ws.send(JSON.stringify({ id: n, method, params })); });
  const evaluate = async (expression) => {
    const r = await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
    if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails).slice(0, 500));
    return r.result?.result?.value;
  };
  const metrics = async () => Object.fromEntries((await send("Performance.getMetrics")).result.metrics.map((m) => [m.name, m.value]));
  await send("Page.enable");
  await send("Performance.enable");
  await send("Page.navigate", { url: "data:text/html,<body style='margin:0;background:%23222'>" });
  await sleep(500);
  await evaluate(page);
  await evaluate(`loadSet("small", ${JSON.stringify(frames)})`);
  await evaluate(`loadSet("heavy", ${JSON.stringify(heavy)})`);

  const median = (v) => { const s = [...v].sort((a, b) => a - b); return s.length ? s[Math.floor(s.length / 2)] : NaN; };
  const p95 = (v) => { const s = [...v].sort((a, b) => a - b); return s.length ? s[Math.min(s.length - 1, Math.ceil(s.length * 0.95) - 1)] : NaN; };
  const f = (n) => (Number.isFinite(n) ? n.toFixed(3) : "-");

  console.log(`Chrome ${(await (await fetch(`http://127.0.0.1:${port}/json/version`)).json()).Browser}, ${frames.length} frames, ${rounds} rounds`);
  console.log(`small: ${avgBytes(frames)} B/frame, heavy: ${avgBytes(heavy)} B/frame\n`);
  const cases = [];
  for (const mode of ["latency", "paced"]) {
    for (const setName of ["small", "heavy"]) {
      for (const [w, h] of [[80, 60], [800, 600]]) cases.push({ mode, setName, w, h });
    }
  }
  console.log("mode     set    size     path    sync med  sync p95  visible med  visible p95  gap p95  late  main-thread ms/frame");
  for (const c of cases) {
    const acc = { blob: { sync: [], visible: [], gaps: [], late: 0, task: 0 }, inline: { sync: [], visible: [], gaps: [], late: 0, task: 0 } };
    for (let r = 0; r < rounds; r++) {
      // Alternate order each round so neither path always runs warm.
      for (const kind of r % 2 ? ["inline", "blob"] : ["blob", "inline"]) {
        const before = await metrics();
        const out = await evaluate(`runCase(${JSON.stringify(kind)}, ${JSON.stringify(c.setName)}, ${c.w}, ${c.h}, ${JSON.stringify(c.mode)})`);
        const after = await metrics();
        const a = acc[kind];
        a.sync.push(...out.sync); a.visible.push(...out.visible); a.gaps.push(...out.gaps); a.late += out.late;
        a.task += (after.TaskDuration - before.TaskDuration) * 1000;
      }
    }
    for (const kind of ["blob", "inline"]) {
      const a = acc[kind];
      const n = frames.length * rounds;
      console.log([
        c.mode.padEnd(8), c.setName.padEnd(6), `${c.w}x${c.h}`.padEnd(8), kind.padEnd(7),
        f(median(a.sync)).padStart(8), f(p95(a.sync)).padStart(9),
        f(median(a.visible)).padStart(12), f(p95(a.visible)).padStart(12),
        f(p95(a.gaps)).padStart(8), String(a.late).padStart(5), f(a.task / n).padStart(21),
      ].join(" "));
    }
  }
} finally {
  ws?.close();
  chrome.kill();
  await sleep(300);
  await rm(profile, { recursive: true, force: true });
}
