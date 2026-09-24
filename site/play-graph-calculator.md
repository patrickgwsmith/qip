# Graph Calculator

A pocket graphing calculator for plotting typed `y=` expressions.

The expression and viewport are retained update state. The component has no
scheduled wake; a new KTX2 frame is published only when the host renders the
changed state.

Controls:

- Type digits, `x`, `+`, `-`, `*`, `/`, `^`, `.`, and parentheses
- `S`: insert `sin(`
- `c`: insert `cos(`
- `T`: insert `tan(`
- `Q`: insert `sqrt(`
- `Backspace`: delete
- `C`: clear
- `Esc`: reset to `sin(x)`
- `Z` / `A`: zoom in or out

<qip-play>
  <source src="/gui/graph-calculator.wasm" type="application/wasm" />
</qip-play>
