# CSV grouped bar chart

`name-group-value-to-svg-bars.wasm` converts UTF-8 CSV to a standalone SVG
grouped horizontal bar chart. Each row supplies one bar:

```csv
name,group,value
WAT,Scalar,132.4
WAT,SIMD,16.7
C,Scalar,134.1
C,SIMD,22.0
```

Run it with:

```sh
./qip run -i results.csv -o chart.svg text/csv/name-group-value-to-svg-bars.wasm
```

`name` identifies a category and `group` identifies a series. The header can
put the three columns in any order. The first occurrence of each name or group
sets its display order. Each `(name, group)` pair may occur once. Missing pairs
leave a gap. Values must be finite, nonnegative numbers. Bars start at zero and
use the largest input value as the right edge of the scale. The SVG shows the
input number next to each bar; put units and a descriptive title in the page
that embeds it.

The component accepts quoted commas and doubled quotes, with LF or CRLF row
endings. It does not accept line breaks inside quoted fields. It accepts at
most 32 names, 8 groups, 256 data rows, and 64 bytes per field. Input is
limited to 64 KiB and output to 128 KiB. Invalid CSV and values outside these
limits cause a recoverable rejection.

Use this chart when several series share the same numeric unit and zero is a
meaningful baseline. For time series or values that need a nonzero baseline,
use a different chart.
