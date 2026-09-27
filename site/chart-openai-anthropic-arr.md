# OpenAI vs Anthropic ARR

Switch between the KTX2 and SVG renderers to compare the same reported
milestones. The SVG version has selectable text and vector marks.

The selected series, milestone, and scale are retained as component state.
Events can change that state without replacing the displayed chart until the
host calls `render`.

<style>
@font-face {
  font-family: "QIP Chart Inter";
  src: url("/fonts/InterDisplay-Bold.ttf") format("truetype");
  font-style: normal;
  font-weight: 700;
  font-display: swap;
}
#arr-svg-chart svg { font-family: "QIP Chart Inter", Inter, sans-serif; }
.arr-renderers { display: flex; gap: 1rem; margin: 1rem 0; }
.arr-renderers label { display: inline-flex; align-items: center; gap: 0.35rem; cursor: pointer; }
</style>

<fieldset class="arr-renderers" aria-label="Chart renderer">
  <label><input type="radio" name="arr-renderer" value="ktx2" checked> KTX2</label>
  <label><input type="radio" name="arr-renderer" value="svg"> SVG</label>
</fieldset>

<div id="arr-ktx-panel">
  <qip-play id="arr-ktx-chart" canvas-width="min(100%, 820px)" canvas-height="auto">
    <source src="/gui/openai-anthropic-arr.wasm" type="application/wasm" />
  </qip-play>
</div>
<div id="arr-svg-panel" hidden>
  <qip-play id="arr-svg-chart" aria-label="OpenAI and Anthropic revenue run rate chart" canvas-width="min(100%, 820px)" svg-inline svg-width="820" svg-height="540">
    <source src="/gui/openai-anthropic-arr-svg.wasm" type="application/wasm" />
  </qip-play>
</div>

<script type="module">
const shortcuts = new Set(["l", "o", "a", "1", "2", "ArrowLeft", "ArrowRight"]);
const renderers = document.querySelectorAll('input[name="arr-renderer"]');
const panels = {
  ktx2: document.querySelector("#arr-ktx-panel"),
  svg: document.querySelector("#arr-svg-panel"),
};

for (const radio of renderers) {
  radio.addEventListener("change", () => {
    panels.ktx2.hidden = radio.value !== "ktx2";
    panels.svg.hidden = radio.value !== "svg";
  });
}

function forwardChartShortcut(event) {
  const pageFocused = event.target === document.body || event.target === document.documentElement;
  const rendererFocused = event.target.matches?.('input[name="arr-renderer"]');
  if (!pageFocused && !rendererFocused) return;
  if (event.ctrlKey || event.altKey || event.metaKey) return;
  const key = event.key.length === 1 ? event.key.toLowerCase() : event.key;
  if (rendererFocused && key.startsWith("Arrow")) return;
  const selected = document.querySelector('input[name="arr-renderer"]:checked')?.value;
  const chart = panels[selected]?.querySelector("canvas, [role='img']");
  if (!shortcuts.has(key) || !chart) return;

  event.preventDefault();
  chart.dispatchEvent(new KeyboardEvent(event.type, {
    key: event.key,
    code: event.code,
    repeat: event.repeat,
    shiftKey: event.shiftKey,
    bubbles: true,
    cancelable: true,
  }));
}

document.addEventListener("keydown", forwardChartShortcut);
document.addEventListener("keyup", forwardChartShortcut);
</script>

<hr>

A reported annualized-revenue overlay for OpenAI and Anthropic, tracking public run-rate milestones from 2023 through August 2026.

Keyboard shortcuts work when the page, renderer choice, or chart has focus.

Controls:

- Hover a point to see its amount and date in a tooltip; use the arrow keys to inspect other milestones
- `1` or `O`: latest OpenAI point
- `2` or `A`: latest Anthropic point
- `L`: animate between linear and log scale over 300 milliseconds

Data notes:

- These are reported private-company ARR or annualized revenue run-rate milestones, not audited financial statements.
- OpenAI points use the company's published 2023-2025 ARR milestones and public reporting through August 2026. Bloomberg reported the latest run rate at more than $40 billion.
- Anthropic points use public reporting for 2025-2026 run-rate milestones. Bloomberg reported that the latest run rate reached $65 billion by the end of July 2026.
- Anthropic and OpenAI do not necessarily classify partner and cloud-reseller revenue the same way, so the overlay is best read as directional growth rather than a strict accounting comparison.

Sources include [Bloomberg on OpenAI](https://news.bloomberglaw.com/artificial-intelligence/openais-revenue-run-rate-tops-40-billion-ahead-of-ipo), [Bloomberg on Anthropic](https://news.bloomberglaw.com/business-and-practice/anthropic-revenue-run-rate-surpasses-65-billion-ahead-of-ipo), [OpenAI](https://openai.com/index/a-business-that-scales-with-the-value-of-intelligence/), [Anthropic](https://www.anthropic.com/news/google-broadcom-partnership-compute), [Financial Times](https://www.ft.com/content/1ffc5fe7-6872-42a0-8b98-dc685f9c33c6), [Financial Times May 2026](https://www.ft.com/content/fd0aec4a-50d1-4594-b489-7420bd0b4268), [Reuters](https://www.reuters.com/business/openai-reaches-12-billion-annualized-revenue-run-rate-information-reports-2025-07-30/), [The Guardian](https://www.theguardian.com/technology/2026/feb/12/anthropic-funding-round), [Axios](https://www.axios.com/2026/04/13/anthropic-revenue-growth-ai), [MarketWatch OpenAI](https://www.marketwatch.com/story/openai-is-now-bringing-in-2-billion-a-month-and-3-more-highlights-from-its-latest-update-b00f4141), and [MarketWatch Anthropic](https://www.marketwatch.com/story/anthropic-just-set-the-stage-for-a-blockbuster-ipo-beating-openai-to-the-punch-4cde9d9f).
