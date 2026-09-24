# Shutterstock Earnings Overlay

A quarter-by-quarter view of Shutterstock earnings with the SSTK share price drawn over the same reporting periods.

The metric and selected quarter are retained update state. Hover changes do
not replace the chart until the host calls `render`.

Controls:

- Hover the chart or use the arrow keys to inspect a quarter
- `1`: revenue
- `2`: net income
- `3`: diluted EPS

Data notes:

- Financials use SEC companyfacts for Shutterstock, Inc. CIK `0001549346`.
- Q4 financials are derived from full-year totals minus Q1-Q3 because the SEC frame data reports the 10-K as an annual period.
- Share prices use Nasdaq quarter-end closes, or the previous trading day when the quarter ended on a market holiday or weekend.

<qip-play canvas-width="760px" canvas-height="auto">
  <source src="/gui/shutterstock-earnings.wasm" type="application/wasm" />
</qip-play>
