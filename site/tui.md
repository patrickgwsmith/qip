<title>TUI components</title>

# TUI components

These components render text frames and accept keyboard events. Run them in a
terminal with `qiptui` or `qipx tui`. The host owns the
terminal mode and redraws; the component cannot read files or send arbitrary
terminal commands.

## Components

- [`calendar-gregorian.wasm`](/tui/calendar-gregorian.wasm) shows a Gregorian month. Up and Down move between months.
- [`qipdb.wasm`](/tui/qipdb.wasm) inspects and runs a supplied Wasm component. Pass the component and its input as multipart fields.

For example:

```sh
npx qiptui qip.dev tui/calendar-gregorian.wasm
npx qiptui qip.dev -F 'input=Hello' -F component=@text/wc.wasm tui/qipdb.wasm
```

See the [TUI contract](/docs/tui-components) for input, key, timing, and ANSI
rules. For browser-hosted graphical applications, browse the [GUI components](/gui).
