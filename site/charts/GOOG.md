# Alphabet (GOOG) quarterly revenue

Alphabet's total revenue for each fiscal quarter from 2016 Q4 to 2026 Q3, the last ten years,
drawn as one bar per quarter with a trailing four-quarter average. Alphabet's fiscal year is the calendar year.
See [Charts](/charts) for how the bars, axis, and average components fit together.

Figures are total revenue in US dollars from Alphabet's SEC filings, taken
from the [XBRL company facts](https://data.sec.gov/api/xbrl/companyfacts/CIK0001652044.json).
Q1–Q3 are the three-month figures in each 10-Q, using the latest filing that
reports the quarter. Q4 is not filed on its own, so it is the 10-K annual total
minus Q1–Q3. The latest quarter is Q3 2026 (ended September 30, 2026).
All filings are listed on [EDGAR](https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=1652044&type=10-&dateb=&owner=include&count=40).

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
  <form class="time-series-example" aria-labelledby="goog-revenue-heading">
    <h3 id="goog-revenue-heading">Alphabet quarterly revenue with a four-quarter average</h3>
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
FY2016Q4,$26.064B
FY2017Q1,$24.75B
FY2017Q2,$26.01B
FY2017Q3,$27.772B
FY2017Q4,$32.323B
FY2018Q1,$31.146B
FY2018Q2,$32.657B
FY2018Q3,$33.74B
FY2018Q4,$39.276B
FY2019Q1,$36.339B
FY2019Q2,$38.944B
FY2019Q3,$40.499B
FY2019Q4,$46.075B
FY2020Q1,$41.159B
FY2020Q2,$38.297B
FY2020Q3,$46.173B
FY2020Q4,$56.898B
FY2021Q1,$55.314B
FY2021Q2,$61.88B
FY2021Q3,$65.118B
FY2021Q4,$75.325B
FY2022Q1,$68.011B
FY2022Q2,$69.685B
FY2022Q3,$69.092B
FY2022Q4,$76.048B
FY2023Q1,$69.787B
FY2023Q2,$74.604B
FY2023Q3,$76.693B
FY2023Q4,$86.31B
FY2024Q1,$80.539B
FY2024Q2,$84.742B
FY2024Q3,$88.268B
FY2024Q4,$96.469B
FY2025Q1,$90.234B
FY2025Q2,$96.428B
FY2025Q3,$102.346B
FY2025Q4,$113.828B
FY2026Q1,$109.896B
FY2026Q2,$119.796B
FY2026Q3,$127.577B
</textarea>
      </label>
      <output name="output"><img alt="Alphabet quarterly revenue as vertical bars by fiscal quarter, with a four-quarter average line" /></output>
    </qip-edit>
<copy-code>

```sh
cat GOOG.csv | npx @qip.dev/qipx qip.dev run \
  text/csv/fiscal-quarter-csv-to-svg-bars.wasm \
  image/svg+xml/svg-bars-add-y-axis.wasm \
  image/svg+xml/svg-bars-add-quarter-x-axis.wasm \
  image/svg+xml/svg-bars-add-rolling-mean.wasm -u window_size=4 \
  > GOOG.svg
```

</copy-code>
  </form>
</div>
