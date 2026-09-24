# IEEE 754 Floating Point

Inspect how `f32` and `f64` values are encoded as sign, exponent, and fraction bits.

The selected format, bits, and cursor are retained as component state. The
component has no animation wake and publishes KTX2 bytes only from `render`.

Controls:

- Click `F32` or `F64` to switch formats.
- Click any bit to toggle it.
- Use the preset buttons for zero, one, pi, infinity, NaN, and the smallest normal value.
- Keyboard: `F` toggles format, `3` selects f32, `6` selects f64, arrow keys move the selected bit, and `Space` or `Enter` toggles it.
- Shortcuts: `S`/`N` toggles sign, `Z` zero, `O`/`1` one, `P` pi, `I` infinity, `Q` NaN, and `M` minimum normal.
- Watch the raw exponent, hidden bit, hexadecimal bytes, decimal value, and scientific notation update together.

<qip-play>
  <source src="/gui/ieee-754-floats.wasm" type="application/wasm" />
</qip-play>
