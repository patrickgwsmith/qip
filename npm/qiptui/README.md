# qiptui

`qiptui` runs one QIP TUI or plain-text Content component in a terminal. The package has no runtime
dependencies and ships one executable JavaScript file. It requires Node.js 22
or newer.

```sh
npx qiptui qip.dev/tui/calendar-gregorian.wasm
```

Hosted components are downloaded over HTTPS into memory on each run. `qiptui`
does not save them or read a same-named local file. Use an explicit `./` prefix
to run a local component whose first directory looks like a host. A path that
starts with `/` is always local, even with a leading host. A failed hosted
download does not fall back to a local file.

```sh
npx qiptui ./tui/calendar-gregorian.wasm
npx qiptui -i input.txt ./my-tui.wasm
cat input.txt | npx qiptui -i - ./my-tui.wasm
curl -I https://www.apple.com | npx qiptui -F 'headers=<-' ./my-tui.wasm
npx qiptui qip.dev -F 'input=Hello' -F component=@text/wc.wasm tui/qipdb.wasm
npx qiptui qip.dev -F 'component=<text/wc.wasm' tui/qipdb.wasm
npx qiptui -u columns=100 ./my-tui.wasm
```

`-F` builds one `multipart/form-data` input. Use `name=@path` to send file bytes
with a filename, or `name=<path` to send them as a regular field without a
filename. Quote the `<` form so the shell does not treat it as redirection. A
leading host such as `qip.dev` applies to the TUI and its `.wasm` form fields.
Hosted files are downloaded into memory on each run. With `-i -`, `-F name=@-`,
or `-F 'name=<-'`, qiptui reads piped stdin once and reads keys from the
terminal on stderr. These forms require stderr to remain attached to a terminal.
If a component declares a different input type,
`qiptui` reports the mismatch before rendering. `Ctrl-C` exits and restores
the terminal. With `<`, `qipdb` runs the component but shows a generic WASM
label because the form field has no filename.

The component must implement the [QIP TUI contract](https://qip.dev/docs/tui-components).
`qiptui` accepts one TUI component and does not run post-processing stages.
It checks terminal frames before writing them and applies the same
pre-execution checks as `qipx`: no WebAssembly imports, a finite, unshared
memory maximum of at most 256 MiB, no `memory.grow`, no start function, no
atomics, only Strict Wasm Profile opcodes (no tail calls, which break
per-function reasoning), and static Content ABI getters.
Component memory is fixed at its declared initial size. Downloads have
a 16 MiB limit, a 30-second timeout, and at most two redirects within the same
HTTPS origin.

## Text input and result navigation

A Content component with UTF-8 `text/plain` input and no event or update exports
gets a text field above its rendered output:

```sh
npx qiptui qip.dev/tui/emoji-finder.wasm
```

Type to search. Up and Down change `active_index` when the component exports
both `uniform_set_active_index` and `active_count`. Each text edit resets the
active index to zero. Arrow navigation and resize preserve the query. The host
writes the complete query and reapplies uniforms before every render; empty
input uses `render(0)`.

Left, Right, Home, End, Backspace, and Delete edit the field. `Ctrl-A` and
`Ctrl-E` move to the ends, `Ctrl-U` and `Ctrl-K` delete before or after the
cursor, and `Ctrl-W` deletes the preceding word. Cursor movement and deletion
use grapheme clusters, so a composed emoji is one editing unit. Bracketed paste
inserts a complete value. Input must be one printable line within the
component's UTF-8 byte capacity; the host reports an exceeded limit beside the
field. `-i` can supply its initial value, and `-u active_index=...` can supply
its initial active result. `Ctrl-C` exits.

`-u name=value` values are parsed for the setter's parameter type, as in
qipx: `i32` takes an unsigned integer up to 4294967295, `i64` a signed 64-bit
integer, and `f32` or `f64` a finite number. Decimal or `0x` hex is accepted for
integers. A fractional, out-of-range or overflowing value is an error, not
truncated, wrapped or rounded.

The original eventful emoji finder, including combination mode, is available
as `tui/emoji-finder-old.wasm`.

## Publish

Run `make publish` from this directory. It publishes the version in
`package.json` and appends that version to `published-versions.txt` only after
`npm publish` succeeds. Commit the updated log. Add versions published by other
means to the log by hand.

## TODO

- Investigate reading piped stdin without an explicit `-` when no input option
  is given.
