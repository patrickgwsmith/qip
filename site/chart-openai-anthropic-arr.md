# OpenAI vs Anthropic ARR

The selected series, milestone, and scale are retained as component state.
Events can change that state without replacing the published KTX2 chart until
the host calls `render`.

<qip-play canvas-width="820px" canvas-height="auto">
  <source src="/interactive/openai-anthropic-arr.wasm" type="application/wasm" />
</qip-play>

<script type="module">
const shortcuts = new Set(["l", "o", "a", "1", "2", "ArrowLeft", "ArrowRight"]);

function forwardChartShortcut(event) {
  if (event.target !== document.body && event.target !== document.documentElement) return;
  if (event.ctrlKey || event.altKey || event.metaKey) return;
  const key = event.key.length === 1 ? event.key.toLowerCase() : event.key;
  const chart = document.querySelector("qip-play canvas");
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

Keyboard shortcuts work when the page or chart has focus.

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
