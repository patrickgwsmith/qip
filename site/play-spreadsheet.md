# Spreadsheet

A compact spreadsheet for editing cells directly inside a QIP Eventful
component. Updates retain cell and editing state, while separate renders present
canonical KTX2 output. The edit caret requests its next blink as a semantic
wake deadline.

Supported:

- Arrow-key cell navigation
- Mouse cell selection
- Type to edit the active cell
- `Enter` commits and moves down
- `Tab` commits and moves right
- `Esc` cancels the current edit
- `Backspace` / `Delete` clears or edits cell text
- `Ctrl`/`Cmd` + `C`, `X`, `V` for internal copy, cut, and paste
- Simple formulas with integer cell references, such as `=B2*C2` and `=D2+D3`

<qip-play>
  <source src="/gui/spreadsheet.wasm" type="application/wasm" />
</qip-play>
