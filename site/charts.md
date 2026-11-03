# Charts

Chart-focused QIP components:

- [Time series CSV to SVG polylines](/text/csv/time-series-csv-to-svg-polylines.wasm) renders a `date` or UTC `timestamp` column plus one or more numeric columns as a vector SVG chart. [Exponential moving average](/image/svg+xml/svg-polylines-exponential-moving-average.wasm) and [rolling mean](/image/svg+xml/svg-polylines-rolling-mean.wasm) transform every emitted data polyline independently. [Add mean lines](/image/svg+xml/svg-polylines-add-mean-lines.wasm) adds a same-colour dashed arithmetic mean for each polyline.
- [Fiscal quarter CSV to SVG bars](/text/csv/fiscal-quarter-csv-to-svg-bars.wasm) renders one bar per fiscal quarter (`FY2026Q4`). Separate passes add a [y axis](/image/svg+xml/svg-bars-add-y-axis.wasm) with round-step gridlines, a [quarter x axis](/image/svg+xml/svg-bars-add-quarter-x-axis.wasm) (`Q1`–`Q4` with `’26` under each fiscal year), and a [rolling mean](/image/svg+xml/svg-bars-add-rolling-mean.wasm) line, such as a four-quarter average.
- Quarterly revenue from SEC filings: [Apple (AAPL)](/charts/AAPL), [Alphabet (GOOG)](/charts/GOOG), [NVIDIA (NVDA)](/charts/NVDA)
- [OpenAI vs Anthropic ARR (KTX2 and SVG)](/chart-openai-anthropic-arr), with an [SVG DOM update benchmark](/svg-dom-update-benchmark)
- [Shutterstock Earnings Overlay](/play-shutterstock-earnings)

## CSV to SVG polylines

These examples run in the browser. They plot NVIDIA's reported quarterly
revenue, in USD millions, from April 2020 through April 2026. The series shows
the 2022 slowdown followed by the AI infrastructure expansion. [NVIDIA's Q1 fiscal 2027 results](https://nvidianews.nvidia.com/news/nvidia-announces-financial-results-for-first-quarter-fiscal-2027)
report the latest point and the comparable prior-year result. The first CSV
column is `date` or a UTC `timestamp`; every following numeric column becomes
a data polyline. The SVG keeps those polylines in value space, so the next
example can smooth the series without changing the chart layout.

<style>
.time-series-examples {
  display: grid;
  gap: 1.5rem;
}
.time-series-example {
  display: grid;
  gap: 0.75rem;
}
.time-series-example textarea {
  box-sizing: border-box;
  width: 100%;
  resize: vertical;
  font: 0.875rem/1.35 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
}
.time-series-example output {
  display: block;
  overflow: auto;
  border: 1px solid CanvasText;
}
.time-series-example output img {
  display: block;
  width: min(100%, 640px);
  height: auto;
}
</style>

<div class="time-series-examples">
  <form class="time-series-example" aria-labelledby="time-series-raw-heading">
    <h3 id="time-series-raw-heading">NVIDIA quarterly revenue since 2020</h3>
    <qip-edit>
      <qip-step name="chart">
        <source src="/text/csv/time-series-csv-to-svg-polylines.wasm" type="application/wasm" data-uniform-x_axis_tick_year_interval="1" />
      </qip-step>
      <label>CSV
        <textarea name="input" rows="10" spellcheck="false">date,revenue_usd_millions
2020-04-26,3080
2020-07-26,3866
2020-10-25,4726
2021-01-31,5003
2021-05-02,5661
2021-08-01,6507
2021-10-31,7103
2022-01-30,7643
2022-05-01,8288
2022-07-31,6704
2022-10-30,5931
2023-01-29,6051
2023-04-30,7192
2023-07-30,13507
2023-10-29,18120
2024-01-28,22103
2024-04-28,26044
2024-07-28,30040
2024-10-27,35082
2025-01-26,39331
2025-04-27,44062
2025-07-27,46743
2025-10-26,57006
2026-01-25,68127
2026-04-26,81615
</textarea>
      </label>
      <output name="output"><img alt="NVIDIA quarterly revenue since 2020 as an SVG line chart" /></output>
    </qip-edit>
<copy-code>

```sh
cat series.csv | npx @qip.dev/qipx qip.dev run \
  text/csv/time-series-csv-to-svg-polylines.wasm -u x_axis_tick_year_interval=1 \
  > chart.svg
```

</copy-code>
  </form>

  <form class="time-series-example" aria-labelledby="time-series-ema-heading">
    <h3 id="time-series-ema-heading">NVIDIA quarterly revenue, EMA window 3, with a mean line</h3>
    <qip-edit>
      <qip-step name="chart">
        <source src="/text/csv/time-series-csv-to-svg-polylines.wasm" type="application/wasm" data-uniform-x_axis_tick_year_interval="1" />
      </qip-step>
      <qip-step name="mean-lines">
        <source src="/image/svg+xml/svg-polylines-add-mean-lines.wasm" type="application/wasm" />
      </qip-step>
      <qip-step name="exponential-moving-average">
        <source src="/image/svg+xml/svg-polylines-exponential-moving-average.wasm" type="application/wasm" data-uniform-window_size="3" />
      </qip-step>
      <label>CSV
        <textarea name="input" rows="10" spellcheck="false">date,revenue_usd_millions
2020-04-26,3080
2020-07-26,3866
2020-10-25,4726
2021-01-31,5003
2021-05-02,5661
2021-08-01,6507
2021-10-31,7103
2022-01-30,7643
2022-05-01,8288
2022-07-31,6704
2022-10-30,5931
2023-01-29,6051
2023-04-30,7192
2023-07-30,13507
2023-10-29,18120
2024-01-28,22103
2024-04-28,26044
2024-07-28,30040
2024-10-27,35082
2025-01-26,39331
2025-04-27,44062
2025-07-27,46743
2025-10-26,57006
2026-01-25,68127
2026-04-26,81615
</textarea>
      </label>
      <output name="output"><img alt="NVIDIA quarterly revenue after an exponential moving average, with a dashed mean line" /></output>
    </qip-edit>
<copy-code>

```sh
cat series.csv | npx @qip.dev/qipx qip.dev run \
  text/csv/time-series-csv-to-svg-polylines.wasm -u x_axis_tick_year_interval=1 \
  image/svg+xml/svg-polylines-add-mean-lines.wasm \
  image/svg+xml/svg-polylines-exponential-moving-average.wasm -u window_size=3 \
  > chart-ema-with-mean.svg
```

</copy-code>
  </form>
</div>

## Fiscal quarter CSV to SVG bars

Quarterly earnings read best as one bar per reported quarter, labelled by
fiscal quarter, with a trailing four-quarter average to smooth seasonality. The
CSV has a `fiscal_quarter` column (`FY2027Q1`) and one value column. Rows must
be consecutive quarters. Fiscal years are whatever the company reports:
NVIDIA's fiscal 2027 began in February 2026.

Text around each number is the label format. `$81.615B` makes the y axis print
`$20B`, `$40B` and so on. Every row must use the same prefix and suffix. The
bars component writes the prefix, suffix, plot area and value domain to
`data-*` attributes on the root `<svg>`. Each later pass reads those
attributes, so you can add or remove passes independently:

- `svg-bars-add-y-axis` draws labelled gridlines behind the bars at the
  domain's round step. The `tick_count` uniform picks a different step.
- `svg-bars-add-quarter-x-axis` labels each bar `Q1`–`Q4` and adds `’27`
  under each fiscal year's first quarter.
- `svg-bars-add-rolling-mean` draws the trailing mean of `window_size` bars
  (default 4). The line starts at the first full window.

<div class="time-series-examples">
  <form class="time-series-example" aria-labelledby="fiscal-quarter-bars-heading">
    <h3 id="fiscal-quarter-bars-heading">NVIDIA quarterly revenue with a four-quarter average</h3>
    <qip-edit>
      <qip-step name="bars">
        <source src="/text/csv/fiscal-quarter-csv-to-svg-bars.wasm" type="application/wasm" />
      </qip-step>
      <qip-step name="y-axis">
        <source src="/image/svg+xml/svg-bars-add-y-axis.wasm" type="application/wasm" />
      </qip-step>
      <qip-step name="quarter-x-axis">
        <source src="/image/svg+xml/svg-bars-add-quarter-x-axis.wasm" type="application/wasm" />
      </qip-step>
      <qip-step name="rolling-mean">
        <source src="/image/svg+xml/svg-bars-add-rolling-mean.wasm" type="application/wasm" data-uniform-window_size="4" />
      </qip-step>
      <label>CSV
        <textarea name="input" rows="10" spellcheck="false">fiscal_quarter,revenue
FY2021Q1,$3.08B
FY2021Q2,$3.866B
FY2021Q3,$4.726B
FY2021Q4,$5.003B
FY2022Q1,$5.661B
FY2022Q2,$6.507B
FY2022Q3,$7.103B
FY2022Q4,$7.643B
FY2023Q1,$8.288B
FY2023Q2,$6.704B
FY2023Q3,$5.931B
FY2023Q4,$6.051B
FY2024Q1,$7.192B
FY2024Q2,$13.507B
FY2024Q3,$18.12B
FY2024Q4,$22.103B
FY2025Q1,$26.044B
FY2025Q2,$30.04B
FY2025Q3,$35.082B
FY2025Q4,$39.331B
FY2026Q1,$44.062B
FY2026Q2,$46.743B
FY2026Q3,$57.006B
FY2026Q4,$68.127B
FY2027Q1,$81.615B
</textarea>
      </label>
      <output name="output"><img alt="NVIDIA quarterly revenue as vertical bars by fiscal quarter, with a four-quarter average line" /></output>
    </qip-edit>
<copy-code>

```sh
cat quarters.csv | npx @qip.dev/qipx qip.dev run \
  text/csv/fiscal-quarter-csv-to-svg-bars.wasm \
  image/svg+xml/svg-bars-add-y-axis.wasm \
  image/svg+xml/svg-bars-add-quarter-x-axis.wasm \
  image/svg+xml/svg-bars-add-rolling-mean.wasm -u window_size=4 \
  > chart.svg
```

</copy-code>
  </form>
</div>
