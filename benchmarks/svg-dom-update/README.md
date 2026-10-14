# SVG DOM Update

Browser benchmark at `/svg-dom-update-benchmark`
(`site/svg-dom-update-benchmark.md`). It replays frames from four SVG
components through `DOMParser` + `replaceChildren`, `innerHTML`, morphdom,
a stateful React app (`useState`, with and without `React.memo` rows), and a
glue layer that splits the markup string into chunks and parses only the
chunks that changed. The grid, date picker and keyed chart write a `data-rev`
digest on each `data-key` element for morphdom and the chunk glue to use:

- `gui/openai-anthropic-arr-svg.wasm`: the ARR chart.
- `gui/openai-anthropic-arr-keyed-svg.wasm`: a copy of the chart for this
  benchmark only, with a `data-key` and `data-rev` on each part.
- `gui/data-grid-svg.wasm`: a virtualized, sortable, filterable orders grid.
- `gui/date-range-picker-svg.wasm`: a two-month check-in and check-out picker.

Add `?component=chart-keyed`, `?component=grid` or `?component=dates` to the page URL to pick one.

This directory only builds the vendored modules in `site/vendor/`:

```sh
make -C benchmarks/svg-dom-update vendor
```

Pinned versions are in `package.json` and the `Makefile`.
