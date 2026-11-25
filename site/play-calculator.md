# Calculator

A four-function calculator built as an interactive QIP component, styled after
the 1984 Macintosh Calculator desk accessory: a black-and-white window with a
striped title bar on a grey desktop. It draws one-bit pixels on a 120×180
canvas and scales them up 4×.

It calculates in 64-bit floating point and rounds the display to ten digits, so
`0.1 + 0.2` shows `0.3`. Very large and very small results switch to scientific
notation, and dividing by zero shows Error. Like a desk calculator, it applies
each operation as you go: `2 + 3 × 4 =` gives 20. Pressing `=` again repeats the
last operation.

Its timestamp-free key and pointer events run inside application-style updates.
`finish_update` closes an update without rejection, and a separate render
presents canonical KTX2 output.

Controls:

- Click the keys, or type numbers and `.`
- `+`, `-`, `*`, `/`: choose an operation
- `Enter` or `=`: evaluate
- `E`: clear the entry (the on-screen E key)
- `C` or `Delete`: clear the entry, then everything
- `Escape` or the on-screen C key: clear everything
- `Backspace`: delete a digit
- `n`: change the sign

<qip-play canvas-width="240px" canvas-height="auto">
  <source src="/gui/calculator.wasm" type="application/wasm" />
</qip-play>
