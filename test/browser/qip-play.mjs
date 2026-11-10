// Real-browser regression test for <qip-play>, driven by agent-browser.
//
//   node --test test/browser/qip-play.mjs
//   QIP_PLAY_UPDATE_GOLDEN=1 node --test test/browser/qip-play.mjs
//
// It serves the repo, opens test/browser/qip-play.html, sends real pointer and
// keyboard input, and compares canvas pixel hashes, SVG markup hashes and stats
// text against qip-play.golden.json. Only the DOM that <qip-play> builds is
// inspected, so the test holds across refactors of the element's internals.
// It is skipped when agent-browser is not installed.

import assert from "node:assert/strict";
import { execFile, spawnSync } from "node:child_process";
import { promisify } from "node:util";
import { createReadStream, existsSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { extname, join, normalize, resolve, sep } from "node:path";
import test from "node:test";

const ROOT = resolve(new URL("../..", import.meta.url).pathname);
const GOLDEN_PATH = join(ROOT, "test/browser/qip-play.golden.json");
const UPDATE = process.env.QIP_PLAY_UPDATE_GOLDEN === "1";
const SESSION = "qip-play-test-" + process.pid;
const HAS_AGENT_BROWSER = spawnSync("agent-browser", ["--version"]).status === 0;

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".wasm": "application/wasm",
  ".svg": "image/svg+xml",
};

function serve() {
  const server = createServer((request, response) => {
    const path = normalize(decodeURIComponent(new URL(request.url, "http://x").pathname));
    const file = join(ROOT, path);
    if (!file.startsWith(ROOT + sep) || !existsSync(file) || !statSync(file).isFile()) {
      response.writeHead(404).end("not found");
      return;
    }
    response.writeHead(200, { "content-type": MIME[extname(file)] || "application/octet-stream" });
    createReadStream(file).pipe(response);
  });
  return new Promise((done) => server.listen(0, "127.0.0.1", () => done(server)));
}

const run = promisify(execFile);

// Async on purpose: the page is served from this process, so blocking the
// event loop while agent-browser waits would deadlock the page load.
async function browser(...args) {
  return (await run("agent-browser", ["--session", SESSION, ...args], { encoding: "utf8" })).stdout;
}

async function evaluate(script) {
  const child = run("agent-browser", ["--session", SESSION, "--json", "eval", "--stdin"], { encoding: "utf8" });
  child.child.stdin.end(script);
  const parsed = JSON.parse((await child).stdout);
  if (!parsed.success) throw new Error("eval failed: " + parsed.error);
  return parsed.data.result;
}

const probe = (ids) => evaluate(`window.qipPlayProbe(${JSON.stringify(ids ?? null)})`);
const pause = (ms) => new Promise((done) => setTimeout(done, ms));

// Settles after input: waits until two probes in a row agree.
async function settle(ids) {
  let previous = JSON.stringify(await probe(ids));
  for (let i = 0; i < 20; i++) {
    await pause(80);
    const next = JSON.stringify(await probe(ids));
    if (next === previous) return JSON.parse(next);
    previous = next;
  }
  return JSON.parse(previous);
}

async function clickAt(id, fx, fy, button = "left") {
  const { [id]: entry } = await probe([id]);
  const x = Math.round(entry.rect.left + entry.rect.width * fx);
  const y = Math.round(entry.rect.top + entry.rect.height * fy);
  await browser("mouse", "move", String(x), String(y));
  await browser("mouse", "down", button);
  await browser("mouse", "up", button);
}

test("qip-play renders, handles input and pauses offscreen in a real browser", {
  skip: HAS_AGENT_BROWSER ? false : "agent-browser is not installed",
  timeout: 120_000,
}, async () => {
  const server = await serve();
  const golden = UPDATE || !existsSync(GOLDEN_PATH) ? {} : JSON.parse(readFileSync(GOLDEN_PATH, "utf8"));
  const recorded = {};
  const check = (key, value) => {
    recorded[key] = value;
    if (!UPDATE) assert.deepEqual(value, golden[key], key);
  };
  try {
    await browser("set", "viewport", "1000", "1600");
    await browser("open", `http://127.0.0.1:${server.address().port}/test/browser/qip-play.html`);
    for (let i = 0; i < 100 && !await evaluate("window.qipPlayReady?.()"); i++) await pause(100);
    const initial = await settle();

    // Structure that does not depend on golden values.
    assert.equal(initial.calc.surface, "canvas");
    assert.equal(initial.calc.cssWidth, 240);
    assert.equal(initial.calc.statsMaxWidth, "240px");
    assert.equal(initial.calc.touchAction, "none");
    assert.equal(initial.calc.tabIndex, 0);
    assert.equal(initial["klondike-img"].surface, "img");
    assert.equal(initial["klondike-img"].draggable, false);
    assert.equal(initial["klondike-img"].blob, true);
    assert.equal(initial["klondike-img"].alt, "Interactive SVG editor");
    assert.equal(initial["klondike-inline"].surface, "div");
    assert.equal(initial["klondike-inline"].role, "img");
    assert.equal(initial["klondike-inline"].label, "Klondike");
    assert.equal(initial["klondike-inline"].aspectRatio, "1000 / 760");
    assert.equal(initial["klondike-inline"].userSelect, "none");
    assert.equal(initial["klondike-inline"].rootName, "svg");
    assert.equal(initial["klondike-inline"].cssHeight, 228);
    assert.match(initial.duotone.stats, /\ndesktop \| wasm .* \| render +\d+ # ms\nduotone \| wasm /);
    assert.match(initial.resize.stats, /\nresize \| .*\| source ktx2-r8g8b8a8-srgb-resize-/);
    assert.match(initial.missing.error, /^Play error: failed to fetch module .*does-not-exist\.wasm \(404\)$/);
    assert.match(initial["text-output"].error, /^Play error: /);

    for (const [id, entry] of Object.entries(initial)) {
      if (id === "flurry") continue; // animated, so its pixels are not stable
      const { rect, renders, ...stable } = entry;
      check("initial " + id, stable);
    }

    // Keyboard: focus without clicking, so no pointer press reaches the calculator.
    await browser("focus", "#calc canvas");
    const afterKeys = [];
    for (const key of ["7", "+", "5", "Enter"]) {
      await browser("press", key);
      afterKeys.push((await settle(["calc"])).calc.hash);
    }
    assert.notEqual(afterKeys[0], initial.calc.hash, "a digit key redraws the calculator");
    assert.notEqual(afterKeys[3], afterKeys[2], "Enter evaluates");
    check("calc keys", afterKeys);
    // Backspace and a held key that auto-repeats.
    await browser("press", "Backspace");
    check("calc backspace", (await settle(["calc"])).calc.hash);
    await browser("keydown", "9");
    await pause(450);
    await browser("keyup", "9");
    check("calc held 9", (await settle(["calc"])).calc.hash);

    // Pointer: press the calculator's keys by position.
    const presses = [];
    for (const [fx, fy] of [[0.15, 0.9], [0.4, 0.9], [0.85, 0.9], [0.15, 0.55]]) {
      await clickAt("calc", fx, fy);
      presses.push((await settle(["calc"])).calc.hash);
    }
    check("calc clicks", presses);

    // Known gap, recorded rather than asserted: pointer coordinates are scaled
    // to the last step's output (600x600 here), not mapped back to the first
    // step's 220x220, so this press can miss the key under the cursor.
    await clickAt("resize", 0.15, 0.55);
    const resized = (await settle(["resize"])).resize;
    check("resize click", { hash: resized.hash, stats: resized.stats });

    // SVG surfaces: click the stock pile in both presentation modes.
    for (const id of ["klondike-img", "klondike-inline"]) {
      await clickAt(id, 0.08, 0.14);
      const after = (await settle([id]))[id];
      assert.notEqual(after.hash, initial[id].hash, id + " redraws after a click");
      check("click " + id, after.hash);
    }

    // Right-click on a canvas: the browser menu is only suppressed when the
    // component accepts the press, which cannot be observed headlessly, so this
    // only checks that it does not break later input.
    await clickAt("calc", 0.5, 0.5, "right");
    await settle(["calc"]);

    // Timed animation advances while visible and pauses offscreen.
    await browser("scrollintoview", "#flurry");
    await pause(300);
    const firstFlurry = (await probe(["flurry"])).flurry;
    await pause(500);
    const visibleFlurry = (await probe(["flurry"])).flurry;
    assert.ok(visibleFlurry.renders > firstFlurry.renders + 5, "flurry animates while visible");
    await browser("scrollintoview", "#offscreen-anchor");
    await pause(300);
    const hiddenStart = (await probe(["flurry"])).flurry.renders;
    await pause(500);
    const hiddenEnd = (await probe(["flurry"])).flurry.renders;
    assert.ok(hiddenEnd - hiddenStart <= 1, `flurry pauses offscreen (${hiddenStart} -> ${hiddenEnd})`);
    await browser("scrollintoview", "#flurry");
    await pause(500);
    assert.ok((await probe(["flurry"])).flurry.renders > hiddenEnd + 5, "flurry resumes onscreen");

    const pageErrors = JSON.parse(await browser("--json", "errors")).data;
    assert.deepEqual(pageErrors?.errors ?? [], [], "no uncaught page errors");

    if (UPDATE) writeFileSync(GOLDEN_PATH, JSON.stringify(recorded, null, 2) + "\n");
  } finally {
    try { await browser("close"); } catch {}
    server.close();
  }
});
