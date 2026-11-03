# Apple (AAPL) quarterly revenue

Apple's total revenue for each fiscal quarter from 2017 Q1 to 2026 Q4, the last ten years,
drawn as one bar per quarter with a trailing four-quarter average. Apple's fiscal year ends on the last Saturday of September, so `Q1` is the holiday quarter ending in late December.
See [Charts](/charts) for how the bars, axis, and average components fit together.

Figures are total revenue in US dollars from Apple's SEC filings, taken
from the [XBRL company facts](https://data.sec.gov/api/xbrl/companyfacts/CIK0000320193.json).
Q1–Q3 are the three-month figures in each 10-Q, using the latest filing that
reports the quarter. Q4 is not filed on its own, so it is the 10-K annual total
minus Q1–Q3. Fiscal 2026 Q4 (ended September 26, 2026) comes from the [earnings release filed on Form 8-K](https://www.sec.gov/Archives/edgar/data/320193/000032019326000024/a8-kex991q4202609262026.htm) on November 2, 2026, because the 10-K has not been filed yet.
All filings are listed on [EDGAR](https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=320193&type=10-&dateb=&owner=include&count=40).

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
  <form class="time-series-example" aria-labelledby="aapl-revenue-heading">
    <h3 id="aapl-revenue-heading">Apple quarterly revenue with a four-quarter average</h3>
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
FY2017Q1,$78.351B
FY2017Q2,$52.896B
FY2017Q3,$45.408B
FY2017Q4,$52.579B
FY2018Q1,$88.293B
FY2018Q2,$61.137B
FY2018Q3,$53.265B
FY2018Q4,$62.9B
FY2019Q1,$84.31B
FY2019Q2,$58.015B
FY2019Q3,$53.809B
FY2019Q4,$64.04B
FY2020Q1,$91.819B
FY2020Q2,$58.313B
FY2020Q3,$59.685B
FY2020Q4,$64.698B
FY2021Q1,$111.439B
FY2021Q2,$89.584B
FY2021Q3,$81.434B
FY2021Q4,$83.36B
FY2022Q1,$123.945B
FY2022Q2,$97.278B
FY2022Q3,$82.959B
FY2022Q4,$90.146B
FY2023Q1,$117.154B
FY2023Q2,$94.836B
FY2023Q3,$81.797B
FY2023Q4,$89.498B
FY2024Q1,$119.575B
FY2024Q2,$90.753B
FY2024Q3,$85.777B
FY2024Q4,$94.93B
FY2025Q1,$124.3B
FY2025Q2,$95.359B
FY2025Q3,$94.036B
FY2025Q4,$102.466B
FY2026Q1,$143.756B
FY2026Q2,$111.184B
FY2026Q3,$109.417B
FY2026Q4,$114.477B
</textarea>
      </label>
      <output name="output"><img alt="Apple quarterly revenue as vertical bars by fiscal quarter, with a four-quarter average line" /></output>
    </qip-edit>
<copy-code>

```sh
cat AAPL.csv | npx @qip.dev/qipx qip.dev run \
  text/csv/fiscal-quarter-csv-to-svg-bars.wasm \
  image/svg+xml/svg-bars-add-y-axis.wasm \
  image/svg+xml/svg-bars-add-quarter-x-axis.wasm \
  image/svg+xml/svg-bars-add-rolling-mean.wasm -u window_size=4 \
  > AAPL.svg
```

</copy-code>
  </form>
</div>
