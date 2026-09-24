# Calculator

A compact four-function calculator built as an interactive QIP component.

Its timestamp-free key and pointer events run inside application-style updates.
`finish_update` closes an update without rejection, and a separate render
presents canonical KTX2 output.

Controls:

- Click the keys or use number keys
- `+`, `-`, `*`, `/`: choose an operation
- `Enter` or `=`: evaluate
- `Backspace`: delete a digit
- `C`: clear

<qip-play>
  <source src="/gui/calculator.wasm" type="application/wasm" />
</qip-play>
