# NVIDIA (NVDA) quarterly revenue

NVIDIA's total revenue for each fiscal quarter from 2017 Q3 to 2027 Q2, the last ten years,
drawn as one bar per quarter with a trailing four-quarter average. NVIDIA's fiscal year ends on the last Sunday of January, so fiscal 2027 began in late January 2026.
See [Charts](/charts) for how the bars, axis, and average components fit together.

Figures are total revenue in US dollars from NVIDIA's SEC filings, taken
from the [XBRL company facts](https://data.sec.gov/api/xbrl/companyfacts/CIK0001045810.json).
Q1–Q3 are the three-month figures in each 10-Q, using the latest filing that
reports the quarter. Q4 is not filed on its own, so it is the 10-K annual total
minus Q1–Q3. The latest quarter is fiscal 2027 Q2 (ended July 26, 2026).
All filings are listed on [EDGAR](https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=1045810&type=10-&dateb=&owner=include&count=40).

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
  <form class="time-series-example" aria-labelledby="nvda-revenue-heading">
    <h3 id="nvda-revenue-heading">NVIDIA quarterly revenue with a four-quarter average</h3>
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
FY2017Q3,$2.004B
FY2017Q4,$2.173B
FY2018Q1,$1.937B
FY2018Q2,$2.23B
FY2018Q3,$2.636B
FY2018Q4,$2.911B
FY2019Q1,$3.207B
FY2019Q2,$3.123B
FY2019Q3,$3.181B
FY2019Q4,$2.205B
FY2020Q1,$2.22B
FY2020Q2,$2.579B
FY2020Q3,$3.014B
FY2020Q4,$3.105B
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
FY2027Q2,$96.221B
</textarea>
      </label>
      <output name="output"><img alt="NVIDIA quarterly revenue as vertical bars by fiscal quarter, with a four-quarter average line" /></output>
    </qip-edit>
<copy-code>

```sh
cat NVDA.csv | npx @qip.dev/qipx qip.dev run \
  text/csv/fiscal-quarter-csv-to-svg-bars.wasm \
  image/svg+xml/svg-bars-add-y-axis.wasm \
  image/svg+xml/svg-bars-add-quarter-x-axis.wasm \
  image/svg+xml/svg-bars-add-rolling-mean.wasm -u window_size=4 \
  > NVDA.svg
```

</copy-code>
  </form>
</div>
