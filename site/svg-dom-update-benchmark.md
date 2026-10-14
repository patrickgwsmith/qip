# SVG DOM Update Benchmark

This page measures how fast the browser can show each new frame of an SVG
component. It runs the component directly, records sequences of real frames,
and replays each sequence through eight ways to put SVG output into the page.

`<qip-play svg-inline>` currently parses each frame with `DOMParser` and swaps
the whole tree with `replaceChildren`. morphdom and React instead patch the
existing nodes, so text selection, hover state and CSS transitions on
unchanged elements survive a render. This page shows what that costs or saves.

Pick a component:

| Component | Elements per frame | Scenarios |
| --- | --- | --- |
| [OpenAI vs Anthropic ARR chart](/chart-openai-anthropic-arr) | about 80 | Scale tween, hover sweep, arrow keys |
| The same chart, keyed by part | about 100 | Scale tween, hover sweep, arrow keys |
| Orders data grid: 1,000 rows, 17 rendered, keyed by order | about 190 | Scroll, sort, type to filter, hover rows |
| Date range picker: two months, keyed by date and month | about 290 | Month paging, stay preview, arrow keys |

The keyed chart draws the same chart, but wraps each part in a `<g>` with a
`data-key` and `data-rev`: the title, each button, the plot frame, each axis,
each series, the selection, the tooltip and the detail panel. The selected
point's larger dot and ring move into their own group, so a hover that moves
the selection leaves both series unchanged. The axes fade by the group's
`opacity`, so a scale tween leaves their tick marks unchanged. It uses about 25
more elements than the plain chart, and only this page uses it.

The grid and the date picker are shaped like components that React apps
commonly build by hand. Their rows, days and month panels carry a `data-key`
attribute. morphdom and React use it as the node key, as a React developer
would with `key`.

Each keyed element also carries `data-rev`, an FNV-1a digest of its content
that the component writes as it renders. The element's own attributes are left
out of the digest, so a grid row that only scrolls to a new position or changes
its hover fill keeps its digest. Two strategies use it:

- **morphdom + data-rev** still parses the whole frame, but skips the children
  of any element whose `data-rev` is unchanged.
- **Chunks at data-key** is a glue layer that never parses the whole frame. It
  scans the markup string for tags, splits it at `data-key` elements, and
  parses only the chunks whose `data-rev` changed, in one `DOMParser` call.
  Elements that only changed their own attributes are patched in place.

**Chunks at structural elements** uses the same glue without help from the
renderer. It splits at `data-key` and `id` elements, SVG groups, HTML
landmarks and block elements, custom elements and significant ARIA roles, and
compares each chunk's markup with the last frame's instead of a digest.
Unkeyed chunks match by position.

## Try the components

Both components run live below through `<qip-play svg-inline>`, the current
`replaceChildren` path. Click one to focus it, then use the keyboard.

The orders grid sorts when you click a column header. Type to filter,
Backspace to remove a character and Escape to clear the filter. The Up and Down
arrows, Page Up, Page Down, Home and End move the cursor.

<qip-play class="svg-bench-demo" aria-label="Orders data grid" canvas-width="min(100%, 820px)" svg-inline svg-width="820" svg-height="540">
  <source src="/gui/data-grid-svg.wasm" type="application/wasm" />
</qip-play>

In the date range picker, click a check-in day, then hover to preview the stay
and click a check-out day. Arrow keys move between days, Page Up and Page Down
change month, Enter or Space chooses the focused day, and Escape clears the
selection.

<qip-play class="svg-bench-demo" aria-label="Check-in and check-out date picker" canvas-width="min(100%, 820px)" svg-inline svg-width="820" svg-height="480">
  <source src="/gui/date-range-picker-svg.wasm" type="application/wasm" />
</qip-play>

## Recorded results

Mean milliseconds per frame from one run in headless Chrome, 20 rounds per
scenario. Shorter bars are faster. The chart is drawn by
[`name-group-value-to-svg-bars.wasm`](/text/csv/name-group-value-to-svg-bars.wasm).

<figure class="svg-bench-chart">
  <div id="svg-bench-recorded-chart" role="img" aria-label="Bar chart of mean milliseconds per frame for five update strategies across six scenarios"></div>
  <figcaption>The React columns are timed from prepared trees, so React never parses markup. The other strategies parse the markup inside the timed region.</figcaption>
</figure>

## Run the benchmark

Running the benchmark adds a chart of your own results below the tables.

<style>
@font-face {
  font-family: "QIP Chart Inter";
  src: url("/fonts/InterDisplay-Bold.ttf") format("truetype");
  font-style: normal;
  font-weight: 700;
  font-display: swap;
}
.svg-bench-controls { display: flex; flex-wrap: wrap; gap: 0.75rem 1.25rem; align-items: center; margin: 1rem 0; }
.svg-bench-controls input[type="number"] { width: 5rem; }
.svg-bench-previews { display: grid; grid-template-columns: repeat(auto-fill, minmax(15rem, 1fr)); gap: 1rem; margin: 1rem 0; }
.svg-bench-previews figure { margin: 0; }
.svg-bench-previews figcaption { font-size: 0.875rem; margin-bottom: 0.25rem; }
.svg-bench-surface { aspect-ratio: var(--svg-bench-ratio, 820 / 540); width: 100%; }
.svg-bench-surface svg { font-family: "QIP Chart Inter", Inter, sans-serif; }
.svg-bench-demo svg { font-family: "QIP Chart Inter", Inter, sans-serif; }
.svg-bench-chart { margin: 1rem 0; }
.svg-bench-chart svg { display: block; width: 100%; height: auto; }
.svg-bench-chart figcaption { font-size: 0.875rem; margin-top: 0.25rem; }
.svg-bench-results table { width: 100%; font-variant-numeric: tabular-nums; }
.svg-bench-results td:not(:first-child), .svg-bench-results th:not(:first-child) { text-align: right; }
</style>

<div class="svg-bench-controls">
  <label>Component <select id="svg-bench-component">
    <option value="chart">ARR chart</option>
    <option value="chart-keyed">ARR chart, keyed</option>
    <option value="grid">Orders data grid</option>
    <option value="dates">Date range picker</option>
  </select></label>
  <label>Rounds <input id="svg-bench-rounds" type="number" min="1" max="500" value="20"></label>
  <button id="svg-bench-run" type="button" disabled>Run benchmark</button>
  <output id="svg-bench-status" aria-live="polite">Loading the component…</output>
</div>

<div id="svg-bench-previews" class="svg-bench-previews"></div>

<div id="svg-bench-results" class="svg-bench-results"></div>

<script type="module">
import morphdom from "/vendor/morphdom-2.7.8.mjs";
import { Fragment, cloneElement, createElement, createRoot, memo, useLayoutEffect, useState, version as reactVersion } from "/vendor/react-dom-19.3.0.mjs";
import { contentComponent, contentTypeUTF8 } from "/qip-runner.js";

const SVG_NS = "http://www.w3.org/2000/svg";
const KEY_DOWN = 1;
const XK = { enter: 0xFF0D, backspace: 0xFF08, escape: 0xFF1B, left: 0xFF51, up: 0xFF52, right: 0xFF53, down: 0xFF54, pageUp: 0xFF55, pageDown: 0xFF56 };

const statusEl = document.querySelector("#svg-bench-status");
const runButton = document.querySelector("#svg-bench-run");
const roundsInput = document.querySelector("#svg-bench-rounds");
const componentSelect = document.querySelector("#svg-bench-component");
const previewsEl = document.querySelector("#svg-bench-previews");
const resultsEl = document.querySelector("#svg-bench-results");

// Mean ms per frame from one headless Chrome run, 20 rounds per scenario.
const RECORDED_CSV = `name,group,value
Grid: hover,DOMParser + replaceChildren,0.76
Grid: hover,DOMParser + morphdom + data-rev,0.25
Grid: hover,"Chunks at data-key, data-rev",0.072
Grid: hover,"React app, useState",0.088
Grid: hover,"React app, useState + memo rows",0.042
Grid: scroll,DOMParser + replaceChildren,0.79
Grid: scroll,DOMParser + morphdom + data-rev,0.33
Grid: scroll,"Chunks at data-key, data-rev",0.21
Grid: scroll,"React app, useState",0.18
Grid: scroll,"React app, useState + memo rows",0.15
Grid: sort,DOMParser + replaceChildren,0.72
Grid: sort,DOMParser + morphdom + data-rev,0.74
Grid: sort,"Chunks at data-key, data-rev",0.70
Grid: sort,"React app, useState",0.68
Grid: sort,"React app, useState + memo rows",0.71
Dates: stay preview,DOMParser + replaceChildren,0.85
Dates: stay preview,DOMParser + morphdom + data-rev,0.37
Dates: stay preview,"Chunks at data-key, data-rev",0.13
Dates: stay preview,"React app, useState",0.15
Dates: stay preview,"React app, useState + memo rows",0.049
Dates: month paging,DOMParser + replaceChildren,0.90
Dates: month paging,DOMParser + morphdom + data-rev,0.83
Dates: month paging,"Chunks at data-key, data-rev",0.56
Dates: month paging,"React app, useState",0.54
Dates: month paging,"React app, useState + memo rows",0.49
Chart: hover sweep,DOMParser + replaceChildren,0.28
Chart: hover sweep,DOMParser + morphdom + data-rev,0.26
Chart: hover sweep,"Chunks at data-key, data-rev",0.28
Chart: hover sweep,"React app, useState",0.10
Chart: hover sweep,"React app, useState + memo rows",0.10
`;

const barsModule = await WebAssembly.compileStreaming(fetch("/text/csv/name-group-value-to-svg-bars.wasm"));
const renderBars = contentComponent(contentTypeUTF8("text/csv"), barsModule, contentTypeUTF8("image/svg+xml"));

function csvField(value) {
  const text = String(value);
  return /[",\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

function showBars(target, csv) {
  const svg = new DOMParser().parseFromString(renderBars(csv), "image/svg+xml").documentElement;
  // The component titles every chart generically; the figure supplies the label.
  svg.querySelector("title")?.remove();
  svg.setAttribute("aria-hidden", "true");
  target.replaceChildren(svg);
}

try {
  showBars(document.querySelector("#svg-bench-recorded-chart"), RECORDED_CSV);
} catch (error) {
  document.querySelector("#svg-bench-recorded-chart").textContent = "Could not draw the chart: " + (error?.message ?? error);
}

// Matches qip-play _presentSVGOutput for svg-inline.
function styleRoot(root) {
  root.style.display = "block";
  root.style.width = "100%";
  root.style.height = "100%";
  return root;
}

function parseSVG(markup) {
  const root = new DOMParser().parseFromString(markup, "image/svg+xml").documentElement;
  if (root.localName !== "svg" || root.namespaceURI !== SVG_NS) throw new Error("frame has no SVG root");
  return styleRoot(root);
}

function nodeKey(node) {
  return node.nodeType === Node.ELEMENT_NODE ? node.getAttribute("data-key") || undefined : undefined;
}

function cssPropertyName(name) {
  return name.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
}

function reactProps(el) {
  const props = {};
  for (const attr of el.attributes) {
    const name = attr.name;
    if (name === "xmlns") continue;
    if (name === "style") {
      props.style = {};
      for (const property of el.style) props.style[cssPropertyName(property)] = el.style.getPropertyValue(property);
    } else if (name === "class") {
      props.className = attr.value;
    } else if (name.startsWith("aria-") || name.startsWith("data-")) {
      props[name] = attr.value;
    } else {
      props[cssPropertyName(name)] = attr.value;
    }
  }
  const key = nodeKey(el);
  if (key) props.key = key;
  return props;
}

// Plain trees stand in for the elements a JSX component would return. Keyed
// subtrees keep their inner markup as a fallback identity for memoized rows.
function domToTree(el) {
  const children = [];
  for (const child of el.childNodes) {
    if (child.nodeType === Node.ELEMENT_NODE) children.push(domToTree(child));
    else if (child.nodeType === Node.TEXT_NODE) children.push(child.data);
  }
  const key = nodeKey(el);
  return { type: el.localName, props: reactProps(el), children, key, content: key ? el.innerHTML : "" };
}

// With memoRows, each keyed element renders its children through a memoized
// component, so React skips a row or day whose data-rev is unchanged, as a
// React.memo row skips when its props are equal. The keyed element's own
// attributes stay with the parent, so position and hover fill can change
// without re-rendering the row's content.
function treeToReact(node, memoRows) {
  if (typeof node === "string") return node;
  const children = memoRows && node.key
    ? [createElement(KeyedContent, { node })]
    : node.children.map((child) => treeToReact(child, memoRows));
  return createElement(node.type, node.props, ...children);
}

function sameContent(previous, next) {
  const rev = previous.node.props["data-rev"];
  return rev !== undefined ? rev === next.node.props["data-rev"] : previous.node.content === next.node.content;
}

const KeyedContent = memo(function KeyedContent({ node }) {
  return createElement(Fragment, null, ...node.children.map((child) => treeToReact(child, true)));
}, sameContent);

// A stateful app: the frame lives in useState and an event handler on the SVG
// sets it, so React schedules the update by event priority instead of being
// forced with flushSync. Key presses and clicks commit in a microtask after
// the event; pointer moves commit in a scheduler task. A layout effect tells
// the benchmark when the commit is done.
function App({ owner, initial }) {
  const [tree, setTree] = useState(initial);
  useLayoutEffect(() => owner.committed(), [tree]);
  const show = () => setTree(owner.nextTree);
  return cloneElement(treeToReact(tree, owner.memoRows), { onKeyDown: show, onClick: show, onPointerMove: show });
}

// The input that would produce each scenario's frames in a real app.
function inputEvent(scenarioID) {
  if (scenarioID === "hover" || scenarioID === "preview") return new PointerEvent("pointermove", { bubbles: true });
  if (scenarioID === "sort") return new MouseEvent("click", { bubbles: true });
  return new KeyboardEvent("keydown", { bubbles: true, key: "ArrowDown" });
}

// Sets the next frame from an input event and resolves when React commits it.
function applyReact(strategy, tree) {
  if (tree === strategy.nextTree) return;
  strategy.nextTree = tree;
  const committed = new Promise((resolve) => { strategy.committed = resolve; });
  if (strategy.mounted) {
    strategy.surface.firstElementChild.dispatchEvent(inputEvent(currentScenarioID));
  } else {
    strategy.mounted = true;
    strategy.reactRoot.render(createElement(App, { owner: strategy, initial: tree }));
  }
  return committed;
}

// Chunked patching: a glue layer that splits each frame's markup at boundary
// elements with a tag scanner, without building a DOM. Each boundary keeps the
// DOM nodes it produced last frame. A boundary whose identity is unchanged is
// skipped, so only changed chunks are parsed, in one DOMParser call per frame.
// Markup between boundaries is a "run", reused when its text is unchanged.
const START_OR_END_TAG = /<(\/?)([A-Za-z_][\w:.-]*)((?:\s+[^\s=\/>]+(?:\s*=\s*(?:"[^"]*"|'[^']*'))?)*)\s*(\/?)>/y;
const ATTRIBUTE = /([^\s=\/>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'))?/g;
const ATTRIBUTE_NS = { xlink: "http://www.w3.org/1999/xlink", xml: "http://www.w3.org/XML/1998/namespace" };

function attributeValue(attrs, name) {
  const match = new RegExp(`\\s${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)')`).exec(attrs);
  return match ? decodeEntities(match[1] ?? match[2]) : undefined;
}

function decodeEntities(value) {
  if (!value.includes("&")) return value;
  const named = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };
  return value.replace(/&(?:#(\d+)|#x([\da-fA-F]+)|(amp|lt|gt|quot|apos));/g, (_, dec, hex, name) =>
    name ? named[name] : String.fromCodePoint(dec ? Number(dec) : parseInt(hex, 16)));
}

function parseAttributes(attrs) {
  const map = new Map();
  for (const match of attrs.matchAll(ATTRIBUTE)) map.set(match[1], decodeEntities(match[2] ?? match[3] ?? ""));
  return map;
}

// Boundaries by data-key, as rendered by the grid and date picker.
function keyedBoundary(tag, attrs) {
  return attributeValue(attrs, "data-key");
}

// Boundaries by element kind, for output that has no keys. HTML landmarks,
// blocks, custom elements and significant ARIA roles split HTML output; SVG
// groups split SVG output. Unkeyed boundaries match by position, like React
// children without a key.
const STRUCTURAL_TAGS = new Set([
  "g", "svg", "a", "symbol", "switch", "foreignObject",
  "header", "nav", "main", "aside", "footer", "section", "article", "form", "fieldset", "dialog", "details",
  "table", "thead", "tbody", "tfoot", "tr", "ul", "ol", "li", "figure",
]);
const STRUCTURAL_ROLES = new Set(["row", "gridcell", "listitem", "option", "tab", "tabpanel", "region", "group", "dialog", "navigation", "main", "banner", "contentinfo", "complementary"]);

function structuralBoundary(tag, attrs) {
  const key = attributeValue(attrs, "data-key") ?? attributeValue(attrs, "id");
  if (key !== undefined) return key;
  if (STRUCTURAL_TAGS.has(tag) || tag.includes("-")) return null;
  const role = attributeValue(attrs, "role");
  return role !== undefined && STRUCTURAL_ROLES.has(role) ? null : undefined;
}

// Returns the root of a tree of boundaries and the elements that contain them.
// `boundary` returns a key, null for a positional boundary, or undefined.
function splitMarkup(markup, boundary) {
  const stack = [];
  let root = null;
  let pos = 0;
  const flushRun = (frame, end) => {
    if (frame.count > 0) frame.items.push({ run: markup.slice(frame.runStart, end), count: frame.count });
    frame.count = 0;
  };
  const close = (frame, closeStart, end) => {
    const parent = frame.parent;
    if (frame.key === undefined && !frame.structural && parent) {
      parent.count++;
      return;
    }
    flushRun(frame, closeStart);
    const node = {
      tag: frame.tag,
      key: frame.key,
      attrs: frame.attrs,
      rev: attributeValue(frame.attrs, "data-rev"),
      outer: markup.slice(frame.start, end),
      inner: markup.slice(frame.openEnd, closeStart),
      items: frame.items,
      el: null,
    };
    if (!parent) {
      root = node;
      return;
    }
    if (node.key === undefined || node.key === null) node.key = `#${node.tag}:${parent.positional++}`;
    flushRun(parent, frame.start);
    parent.items.push(node);
    parent.runStart = end;
    parent.structural = true;
  };
  while (pos < markup.length) {
    const top = stack.at(-1);
    const lt = markup.indexOf("<", pos);
    if (lt !== pos && top) top.count++;
    if (lt < 0) break;
    if (markup.startsWith("<!--", lt) || markup.startsWith("<![CDATA[", lt) || markup[lt + 1] === "?" || markup[lt + 1] === "!") {
      const terminator = markup.startsWith("<!--", lt) ? "-->" : markup.startsWith("<![CDATA[", lt) ? "]]>" : ">";
      pos = markup.indexOf(terminator, lt) + terminator.length;
      if (top) top.count++;
      continue;
    }
    START_OR_END_TAG.lastIndex = lt;
    const match = START_OR_END_TAG.exec(markup);
    if (!match) throw new Error("unexpected markup at offset " + lt);
    pos = START_OR_END_TAG.lastIndex;
    if (match[1]) {
      close(stack.pop(), lt, pos);
      continue;
    }
    const frame = {
      tag: match[2], attrs: match[3], key: boundary(match[2], match[3]), parent: top,
      start: lt, openEnd: pos, runStart: pos, count: 0, items: [], positional: 0, structural: false,
    };
    if (match[4]) close(frame, pos, pos);
    else stack.push(frame);
  }
  if (!root || stack.length) throw new Error("unbalanced markup");
  return root;
}

// Points each boundary and run at the DOM nodes parsed from its markup.
function attachNodes(node, el) {
  node.el = el;
  let child = el.firstChild;
  for (const item of node.items) {
    if (item.run !== undefined) {
      item.nodes = [];
      for (let i = 0; i < item.count; i++, child = child.nextSibling) item.nodes.push(child);
    } else {
      attachNodes(item, child);
      child = child.nextSibling;
    }
  }
}

function updateAttributes(el, fromAttrs, toAttrs) {
  const from = parseAttributes(fromAttrs);
  const to = parseAttributes(toAttrs);
  for (const [name, value] of to) {
    if (name.startsWith("xmlns") || from.get(name) === value) continue;
    const prefix = name.includes(":") ? name.slice(0, name.indexOf(":")) : "";
    if (prefix) el.setAttributeNS(ATTRIBUTE_NS[prefix] ?? null, name, value);
    else el.setAttribute(name, value);
  }
  for (const name of from.keys()) {
    if (!name.startsWith("xmlns") && !to.has(name)) el.removeAttribute(name);
  }
}

function createChunkPatcher(surface, { boundary, useRev }) {
  let current = null;
  let fresh = [];
  let placements = [];

  const unchanged = (from, to) =>
    useRev && from.rev !== undefined && to.rev !== undefined ? from.rev === to.rev : from.inner === to.inner;

  // Walks matched boundaries, collecting chunks to parse and children to place.
  function patch(from, to) {
    to.el = from.el;
    if (to.attrs !== from.attrs) {
      updateAttributes(to.el, from.attrs, to.attrs);
      if (to === current) styleRoot(to.el);
    }
    if (unchanged(from, to)) {
      to.items = from.items;
      return;
    }
    const keyed = new Map();
    const runs = [];
    for (const item of from.items) {
      if (item.run !== undefined) runs.push(item);
      else keyed.set(item.key, item);
    }
    let runIndex = 0;
    for (const item of to.items) {
      if (item.run !== undefined) {
        const previous = runs[runIndex++];
        if (previous && previous.run === item.run) item.nodes = previous.nodes;
        else fresh.push(item);
      } else {
        const previous = keyed.get(item.key);
        if (previous && previous.tag === item.tag) {
          keyed.delete(item.key);
          patch(previous, item);
        } else {
          fresh.push(item);
        }
      }
    }
    placements.push(to);
  }

  function parseFresh() {
    if (fresh.length === 0) return;
    const body = fresh.map((item) => "<g>" + (item.run ?? item.outer) + "</g>").join("");
    const wrapper = parseSVG(`<svg xmlns="${SVG_NS}" xmlns:xlink="${ATTRIBUTE_NS.xlink}">${body}</svg>`);
    let group = wrapper.firstElementChild;
    for (const item of fresh) {
      if (item.run !== undefined) item.nodes = [...group.childNodes];
      else attachNodes(item, group.firstElementChild);
      group = group.nextElementSibling;
    }
  }

  // Removes stale children first, so surviving children keep their order and
  // only new or reordered ones are inserted.
  function place(node) {
    const wanted = [];
    for (const item of node.items) {
      if (item.run !== undefined) wanted.push(...item.nodes);
      else wanted.push(item.el);
    }
    const keep = new Set(wanted);
    for (let child = node.el.firstChild; child; ) {
      const next = child.nextSibling;
      if (!keep.has(child)) child.remove();
      child = next;
    }
    let ref = node.el.firstChild;
    for (const child of wanted) {
      if (child === ref) ref = ref.nextSibling;
      else node.el.insertBefore(child, ref);
    }
  }

  return function apply(markup) {
    const next = splitMarkup(markup, boundary);
    const previous = current;
    current = next;
    if (!previous || surface.firstElementChild !== previous.el || previous.tag !== next.tag) {
      const root = parseSVG(markup);
      attachNodes(next, root);
      surface.replaceChildren(root);
      return;
    }
    fresh = [];
    placements = [];
    patch(previous, next);
    parseFresh();
    for (const node of placements) place(node);
  };
}

// Compares rendered DOM without depending on attribute order or style syntax.
function canonical(node) {
  if (node.nodeType === Node.TEXT_NODE) return JSON.stringify(node.data);
  if (node.nodeType !== Node.ELEMENT_NODE) return "";
  const attrs = [...node.attributes]
    .filter((attr) => attr.name !== "xmlns" && attr.name !== "style")
    .map((attr) => attr.name + "=" + JSON.stringify(attr.value))
    .sort();
  const style = [...node.style].sort().map((property) => property + ":" + node.style.getPropertyValue(property));
  const children = [...node.childNodes].map(canonical).join("");
  return `<${node.namespaceURI} ${node.localName} ${attrs.join(" ")} style="${style.join(";")}">${children}</>`;
}

async function openSession(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error("failed to fetch " + url + " (" + response.status + ")");
  const { instance } = await WebAssembly.instantiate(await response.arrayBuffer(), {});
  const exports = instance.exports;
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let nowMS = 0;

  function render() {
    const packed = exports.render(0);
    const len = Number(packed & 0xFFFFFFFFn);
    const ptr = Number((packed >> 32n) & 0x7FFFFFFFn);
    if ((packed >> 63n) !== 0n) throw new Error("component render failed");
    return decoder.decode(new Uint8Array(exports.memory.buffer, ptr, len));
  }

  function update(event) {
    nowMS += 16;
    exports.begin_update_at(BigInt(nowMS));
    const changed = event ? event(exports) : 0;
    const wakeMS = Number(exports.finish_update());
    return { changed: changed !== 0, wakeMS, nowMS };
  }

  const initial = render();
  let current = initial;
  let scenarioBefore = initial;
  let frames = [];

  return {
    initial,
    get current() { return current; },
    begin() {
      scenarioBefore = current;
      frames = [];
    },
    // Records a frame when the event changes state, or always for timed frames.
    step(event, always = false) {
      const result = update(event);
      if (result.changed || always) {
        current = render();
        if (current !== (frames.at(-1) ?? scenarioBefore)) frames.push(current);
      }
      return result;
    },
    key(code) {
      return this.step((x) => x.key_event(code, KEY_DOWN));
    },
    type(text) {
      for (const char of text) this.key(char.charCodeAt(0));
    },
    click(point) {
      return this.step((x) => x.pointer_event(1, point.x, point.y) | x.pointer_event(0, point.x, point.y));
    },
    move(x, y) {
      return this.step((e) => e.pointer_event(0, x, y));
    },
    end(id, label) {
      return {
        id,
        label,
        before: scenarioBefore,
        frames,
        trees: frames.map((frame) => domToTree(parseSVG(frame))),
        beforeTree: domToTree(parseSVG(scenarioBefore)),
      };
    },
  };
}

// Finds the centre of a keyed group's nth rect in SVG coordinates.
function centerOf(markup, key, rectIndex = 0) {
  const group = parseSVG(markup).querySelector(`[data-key="${key}"]`);
  if (!group) throw new Error("no element keyed " + key);
  const box = group.querySelectorAll(":scope > rect")[rectIndex];
  let x = Number(box.getAttribute("x")) + Number(box.getAttribute("width")) / 2;
  let y = Number(box.getAttribute("y")) + Number(box.getAttribute("height")) / 2;
  for (let el = box.parentElement; el; el = el.parentElement) {
    const match = /translate\(([-\d.]+)[ ,]+([-\d.]+)\)/.exec(el.getAttribute("transform") || "");
    if (match) {
      x += Number(match[1]);
      y += Number(match[2]);
    }
  }
  return { x: Math.round(x), y: Math.round(y) };
}

async function captureChart(url = "/gui/openai-anthropic-arr-svg.wasm") {
  const s = await openSession(url);
  const scenarios = [];

  s.begin();
  for (let toggle = 0; toggle < 2; toggle++) {
    let { wakeMS, nowMS } = s.key("l".charCodeAt(0));
    while (wakeMS > nowMS) ({ wakeMS, nowMS } = s.step(null, true));
  }
  scenarios.push(s.end("tween", "Scale tween"));

  s.begin();
  let row = 0;
  for (let y = 120; y <= 420; y += 20, row++) {
    for (let step = 0; step <= 138; step++) s.move(row % 2 === 0 ? 70 + step * 5 : 760 - step * 5, y);
  }
  s.move(0, 0);
  scenarios.push(s.end("hover", "Hover sweep"));

  s.begin();
  for (const series of ["o", "a"]) {
    s.key(series.charCodeAt(0));
    for (let i = 0; i < 14; i++) s.key(XK.left);
    for (let i = 0; i < 14; i++) s.key(XK.right);
  }
  scenarios.push(s.end("arrows", "Arrow keys"));
  return { initial: s.initial, scenarios };
}

async function captureGrid() {
  const s = await openSession("/gui/data-grid-svg.wasm");
  const scenarios = [];

  s.begin();
  for (let i = 0; i < 80; i++) s.key(XK.down);
  scenarios.push(s.end("scroll", "Scroll with Down arrow"));

  s.begin();
  for (let col = 1; col <= 6; col++) {
    const header = centerOf(s.current, "h" + (col % 6));
    s.click(header);
    s.click(header);
  }
  scenarios.push(s.end("sort", "Sort each column both ways"));

  s.begin();
  s.type("pending");
  for (let i = 0; i < 7; i++) s.key(XK.backspace);
  s.type("north");
  s.key(XK.escape);
  scenarios.push(s.end("filter", "Type to filter"));

  s.begin();
  const firstRow = centerOf(s.current, s.current.match(/data-key="(o\d+)"/)[1]);
  const bodyTop = firstRow.y - 12;
  const bodyBottom = bodyTop + 17 * 24;
  for (let y = bodyTop; y < bodyBottom; y += 4) s.move(400, y);
  for (let y = bodyBottom - 4; y >= bodyTop; y -= 4) s.move(400, y);
  s.move(0, 0);
  scenarios.push(s.end("hover", "Hover rows"));
  return { initial: s.initial, scenarios };
}

async function captureDates() {
  const s = await openSession("/gui/date-range-picker-svg.wasm");
  const scenarios = [];

  s.begin();
  for (let i = 0; i < 12; i++) s.key(XK.pageDown);
  for (let i = 0; i < 12; i++) s.key(XK.pageUp);
  scenarios.push(s.end("paging", "Month paging"));

  s.begin();
  // Check in on the first bookable day from 12 October; booked days have a strike line.
  const checkIn = [...parseSVG(s.current).querySelectorAll('[data-key^="d"]')]
    .find((day) => day.getAttribute("data-key") >= "d20261012" && !day.querySelector("line"));
  s.click(centerOf(s.current, checkIn.getAttribute("data-key"), 1));
  const days = [...s.current.matchAll(/data-key="(d\d{8})"/g)].map((match) => match[1]);
  for (const day of days) {
    const cell = centerOf(s.current, day, 1);
    s.move(cell.x, cell.y);
  }
  s.move(0, 0);
  scenarios.push(s.end("preview", "Preview a stay"));

  s.begin();
  s.key(XK.escape);
  for (const [key, count] of [[XK.right, 30], [XK.down, 4], [XK.left, 30], [XK.up, 4]]) {
    for (let i = 0; i < count; i++) s.key(key);
  }
  scenarios.push(s.end("arrows", "Arrow keys"));
  return { initial: s.initial, scenarios };
}

const components = {
  chart: { label: "ARR chart", capture: captureChart },
  "chart-keyed": { label: "keyed ARR chart", capture: () => captureChart("/gui/openai-anthropic-arr-keyed-svg.wasm") },
  grid: { label: "orders data grid", capture: captureGrid },
  dates: { label: "date range picker", capture: captureDates },
};

const morphdomOptions = { getNodeKey: (node) => nodeKey(node) || node.id };

// morphdom updates an element's attributes before asking about its children,
// so compare data-rev first and remember the elements whose content matched.
const sameRev = new WeakSet();
const morphdomRevOptions = {
  ...morphdomOptions,
  onBeforeElUpdated(from, to) {
    const rev = to.getAttribute("data-rev");
    if (rev !== null && from.getAttribute("data-rev") === rev) sameRev.add(from);
    else sameRev.delete(from);
    return true;
  },
  onBeforeElChildrenUpdated: (from) => !sameRev.has(from),
};

let currentScenarioID = "";

const strategies = [
  {
    id: "replace",
    label: "DOMParser + replaceChildren",
    note: "current qip-play path",
    apply(markup) {
      this.surface.replaceChildren(parseSVG(markup));
    },
  },
  {
    id: "innerhtml",
    label: "innerHTML",
    note: "HTML parser",
    apply(markup) {
      this.surface.innerHTML = markup;
      styleRoot(this.surface.firstElementChild);
    },
  },
  {
    id: "morphdom",
    label: "DOMParser + morphdom",
    note: "morphdom 2.7.8, keyed by data-key",
    apply(markup) {
      const next = parseSVG(markup);
      const current = this.surface.firstElementChild;
      if (current) morphdom(current, next, morphdomOptions);
      else this.surface.replaceChildren(next);
    },
  },
  {
    id: "morphdom-rev",
    label: "DOMParser + morphdom + data-rev",
    note: "as morphdom, but skips the children of elements whose data-rev is unchanged",
    apply(markup) {
      const next = parseSVG(markup);
      const current = this.surface.firstElementChild;
      if (current) morphdom(current, next, morphdomRevOptions);
      else this.surface.replaceChildren(next);
    },
  },
  {
    id: "chunks-rev",
    label: "Chunks at data-key, data-rev",
    note: "splits the string at data-key elements and parses only those whose data-rev changed",
    apply(markup) {
      this.chunks ??= createChunkPatcher(this.surface, { boundary: keyedBoundary, useRev: true });
      this.chunks(markup);
    },
  },
  {
    id: "chunks-structural",
    label: "Chunks at structural elements",
    note: "splits the string at data-key, id, SVG groups, HTML landmarks, blocks, custom elements and ARIA roles; parses only chunks whose markup changed",
    apply(markup) {
      this.chunks ??= createChunkPatcher(this.surface, { boundary: structuralBoundary, useRev: false });
      this.chunks(markup);
    },
  },
  {
    id: "react-state",
    label: "React app, useState",
    note: `React ${reactVersion}; an input event sets the frame in useState and the whole tree re-renders`,
    memoRows: false,
    apply(markup, tree) {
      return applyReact(this, tree);
    },
  },
  {
    id: "react-memo",
    label: "React app, useState + memo rows",
    note: "as React app, useState, but keyed rows and days are React.memo components compared by data-rev",
    memoRows: true,
    apply(markup, tree) {
      return applyReact(this, tree);
    },
  },
];

const requestedID = new URLSearchParams(location.search).get("component");
const componentID = Object.hasOwn(components, requestedID ?? "") ? requestedID : "chart";
const component = components[componentID];
componentSelect.value = componentID;
componentSelect.addEventListener("change", () => {
  const url = new URL(location.href);
  url.searchParams.set("component", componentSelect.value);
  location.assign(url);
});

for (const strategy of strategies) {
  const figure = document.createElement("figure");
  const caption = document.createElement("figcaption");
  caption.textContent = strategy.label;
  strategy.surface = document.createElement("div");
  strategy.surface.className = "svg-bench-surface";
  strategy.surface.setAttribute("role", "img");
  strategy.surface.setAttribute("aria-label", `The ${component.label} rendered with ${strategy.label}`);
  figure.append(caption, strategy.surface);
  previewsEl.append(figure);
  if (strategy.id.startsWith("react")) strategy.reactRoot = createRoot(strategy.surface);
}

function forceLayout(strategy) {
  return strategy.surface.getBoundingClientRect().width;
}

function nextFrame() {
  return new Promise((resolve) => requestAnimationFrame(() => resolve()));
}

function shuffled(items) {
  const copy = items.slice();
  for (let i = copy.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [copy[i], copy[j]] = [copy[j], copy[i]];
  }
  return copy;
}

// Counts new elements, and existing elements that were reinserted elsewhere.
function classifyAdded(node, counts, seen) {
  if (node.nodeType !== Node.ELEMENT_NODE) return;
  if (seen.has(node)) {
    counts.moved++;
    return;
  }
  seen.add(node);
  counts.created++;
  for (const child of node.children) classifyAdded(child, counts, seen);
}

// Replays one scenario untimed, checking output and counting DOM mutations.
async function verifyScenario(strategy, scenario, reference) {
  await strategy.apply(scenario.before, scenario.beforeTree);
  const seen = new WeakSet([strategy.surface, ...strategy.surface.querySelectorAll("*")]);
  const counts = { created: 0, moved: 0, attributes: 0, text: 0 };
  const count = (records) => {
    for (const record of records) {
      if (record.type === "childList") {
        for (const node of record.addedNodes) classifyAdded(node, counts, seen);
      } else if (record.type === "attributes") {
        counts.attributes++;
      } else {
        counts.text++;
      }
    }
  };
  // React strategies commit asynchronously, so the callback can see records first.
  const observer = new MutationObserver(count);
  observer.observe(strategy.surface, { subtree: true, childList: true, attributes: true, characterData: true });
  let mismatch = -1;
  for (const [i, markup] of scenario.frames.entries()) {
    await strategy.apply(markup, scenario.trees[i]);
    count(observer.takeRecords());
    if (mismatch < 0 && canonical(strategy.surface.firstElementChild) !== reference[i]) mismatch = i;
  }
  observer.disconnect();
  return { counts, mismatch };
}

function formatMS(value) {
  return Number.isFinite(value) ? value.toFixed(3) : "–";
}

function renderResults(results, rounds) {
  resultsEl.replaceChildren();
  const heading = document.createElement("h2");
  heading.textContent = "Results";
  const env = document.createElement("p");
  env.textContent = `The ${component.label}, ${rounds} rounds per scenario in ${navigator.userAgent}.`;
  resultsEl.append(heading, env);

  for (const { scenario, rows } of results) {
    const subheading = document.createElement("h3");
    const elements = parseSVG(scenario.frames[0]).querySelectorAll("*").length + 1;
    subheading.textContent = `${scenario.label} (${scenario.frames.length} frames, ${elements} elements)`;
    const table = document.createElement("table");
    table.innerHTML = "<thead><tr><th>Strategy</th><th>Mean ms</th><th>Fastest round ms</th><th>Slowest round ms</th><th>vs current</th><th>Elements created</th><th>Elements moved</th><th>Attr changes</th><th>Text changes</th><th>Output</th></tr></thead>";
    const body = document.createElement("tbody");
    const baseline = rows.find((row) => row.strategy.id === "replace").mean;
    for (const row of rows) {
      const tr = document.createElement("tr");
      const perFrame = (count) => (count / scenario.frames.length).toFixed(1);
      const cells = [
        row.strategy.label,
        formatMS(row.mean),
        formatMS(row.fastest),
        formatMS(row.slowest),
        (row.mean / baseline).toFixed(2) + "×",
        perFrame(row.counts.created),
        perFrame(row.counts.moved),
        perFrame(row.counts.attributes),
        perFrame(row.counts.text),
        row.mismatch < 0 ? "matches" : "differs at frame " + row.mismatch,
      ];
      for (const cell of cells) {
        const td = document.createElement("td");
        td.textContent = cell;
        tr.append(td);
      }
      tr.firstChild.title = row.strategy.note;
      body.append(tr);
    }
    table.append(body);
    resultsEl.append(subheading, table);
  }
  const note = document.createElement("p");
  note.textContent = "All times are per frame. Fastest and slowest are the per-frame averages of single rounds. Mutation columns are per-frame averages from a separate, untimed pass.";
  resultsEl.append(note);

  let csv = "name,group,value\n";
  for (const { scenario, rows } of results) {
    for (const row of rows) {
      if (Number.isFinite(row.mean)) csv += [scenario.label, row.strategy.label, row.mean.toFixed(3)].map(csvField).join(",") + "\n";
    }
  }
  const figure = document.createElement("figure");
  figure.className = "svg-bench-chart";
  const chart = document.createElement("div");
  chart.setAttribute("role", "img");
  chart.setAttribute("aria-label", `Bar chart of mean milliseconds per frame for each strategy across the ${component.label} scenarios`);
  const caption = document.createElement("figcaption");
  caption.textContent = "Mean ms per frame from this run. Shorter bars are faster.";
  figure.append(chart, caption);
  resultsEl.append(figure);
  try {
    showBars(chart, csv);
  } catch (error) {
    chart.textContent = "Could not draw the chart: " + (error?.message ?? error);
  }
}

async function runBenchmark(captured) {
  const rounds = Math.max(1, Math.min(500, Number(roundsInput.value) || 20));
  runButton.disabled = true;
  componentSelect.disabled = true;
  const results = [];
  try {
    for (const scenario of captured.scenarios) {
      const reference = scenario.frames.map((frame) => canonical(parseSVG(frame)));
      const timings = new Map(strategies.map((strategy) => [strategy, []]));
      currentScenarioID = scenario.id;
      // React strategies return a promise that resolves on commit; await only those.
      const replay = async (strategy, timed) => {
        // Start each round from the frame before the scenario, untimed.
        let pending = strategy.apply(scenario.before, scenario.beforeTree);
        if (pending) await pending;
        forceLayout(strategy);
        // Time whole rounds: browsers coarsen performance.now() to about 0.1 ms.
        const start = performance.now();
        for (let i = 0; i < scenario.frames.length; i++) {
          pending = strategy.apply(scenario.frames[i], scenario.trees[i]);
          if (pending) await pending;
          forceLayout(strategy);
        }
        if (timed) timings.get(strategy).push((performance.now() - start) / scenario.frames.length);
      };

      statusEl.value = `${scenario.label}: warming up…`;
      for (const strategy of strategies) await replay(strategy, false);
      await nextFrame();

      for (let round = 0; round < rounds; round++) {
        statusEl.value = `${scenario.label}: round ${round + 1} of ${rounds}`;
        for (const strategy of shuffled(strategies)) {
          await replay(strategy, true);
          await nextFrame();
        }
      }

      const rows = [];
      for (const strategy of strategies) {
        const perFrame = timings.get(strategy);
        const mean = perFrame.reduce((sum, value) => sum + value, 0) / perFrame.length;
        rows.push({ strategy, mean, fastest: Math.min(...perFrame), slowest: Math.max(...perFrame), ...await verifyScenario(strategy, scenario, reference) });
      }
      results.push({ scenario, rows });
      renderResults(results, rounds);
    }
    statusEl.value = "Done.";
  } catch (error) {
    statusEl.value = "Benchmark failed: " + (error?.message ?? error);
    throw error;
  } finally {
    runButton.disabled = false;
    componentSelect.disabled = false;
  }
}

try {
  const captured = await component.capture();
  const first = parseSVG(captured.initial);
  const [, , width, height] = first.getAttribute("viewBox").split(/\s+/).map(Number);
  for (const strategy of strategies) {
    strategy.surface.style.setProperty("--svg-bench-ratio", `${width} / ${height}`);
    await strategy.apply(captured.initial, domToTree(first));
  }
  const counts = captured.scenarios.map((scenario) => `${scenario.label.toLowerCase()} ${scenario.frames.length}`).join(", ");
  statusEl.value = `Ready. Captured frames: ${counts}.`;
  runButton.disabled = false;
  runButton.addEventListener("click", () => runBenchmark(captured));
} catch (error) {
  statusEl.value = "Could not load the component: " + (error?.message ?? error);
  throw error;
}
</script>

## Reading the results

- **Mean ms** is the cost of one frame update: parse, DOM work, and the style
  and layout that the page forces after each update. It excludes paint. A 60 Hz
  frame has a budget of about 16.7 ms.
- **Elements created** shows how much of the tree each strategy rebuilds. The
  two full-replacement strategies create every element on every frame.
- **Elements moved** counts existing elements reinserted at a new position.
  Scrolling the grid or paging the date picker keeps the surviving keyed rows
  and panels in order, so both libraries remove and add at the ends and move
  nothing. When a filter reorders the visible rows, morphdom moves a few of
  them; React's keyed diff avoids most of those moves.
- **React app, useState** approximates a stateful JSX component. An `<App>`
  holds the frame in `useState`, and an input event dispatched on the SVG
  calls the setter: `keydown` for keyboard scenarios, `click` for sorting and
  `pointermove` for hover. React schedules the update by that event's
  priority, without `flushSync`, and the time includes waiting for the commit:
  a microtask for keys and clicks, a scheduler task for pointer moves. The
  elements come from trees prepared before timing, so React never parses
  markup. **React app, useState + memo rows** also renders each keyed row,
  day and month through a `React.memo` component compared by `data-rev`, so a
  hover re-renders only the rows it touches.
- The chunk strategies parse whole chunks, so **Elements created** counts every
  element in a changed day or row. The plain chart has no keys, so its chunks
  are its SVG groups, and most of them change in every frame. Compare it with
  the keyed chart to see what keying the same drawing is worth.
- **Output** compares each strategy's DOM with a fresh parse of the same frame,
  ignoring attribute order and style syntax.

Each round starts from the frame before the scenario, untimed, so every
strategy patches the same first change.

The components are [`gui/data-grid-svg.wasm`](/gui/data-grid-svg.wasm) and
[`gui/date-range-picker-svg.wasm`](/gui/date-range-picker-svg.wasm), plus the
chart's [`gui/openai-anthropic-arr-svg.wasm`](/gui/openai-anthropic-arr-svg.wasm)
and its keyed copy
[`gui/openai-anthropic-arr-keyed-svg.wasm`](/gui/openai-anthropic-arr-keyed-svg.wasm).
The vendored modules are built by `make -C benchmarks/svg-dom-update vendor`.
