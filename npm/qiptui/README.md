# qiptui

`qiptui` runs one QIP TUI component in a terminal. The package has no runtime
dependencies and ships one executable JavaScript file. It requires Node.js 22
or newer.

```sh
npx qiptui qip.dev/interactive/calendar-gregorian.wasm
```

Hosted components are downloaded over HTTPS into memory on each run. `qiptui`
does not save them or read a same-named local file. Use an explicit `./` prefix
to run a local component whose first directory looks like a host. A path that
starts with `/` is always local, even with a leading host. A failed hosted
download does not fall back to a local file.

```sh
npx qiptui ./components/interactive/calendar-gregorian.wasm
npx qiptui -i input.txt ./my-tui.wasm
npx qiptui qip.dev -F 'input=Hello' -F component=@text/wc.wasm interactive/qipdb.wasm
npx qiptui qip.dev -F 'component=<text/wc.wasm' interactive/qipdb.wasm
npx qiptui -u columns=100 ./my-tui.wasm
```

`-F` builds one `multipart/form-data` input. Use `name=@path` to send file bytes
with a filename, or `name=<path` to send them as a regular field without a
filename. Quote the `<` form so the shell does not treat it as redirection. A
leading host such as `qip.dev` applies to the TUI and its `.wasm` form fields.
Hosted files are downloaded into
memory on each run. Terminal stdin is reserved for key events, so `@-` and `<-`
are unavailable in TUI mode. If a component declares a different input type,
`qiptui` reports the mismatch before rendering. `Ctrl-C` exits and restores
the terminal. With `<`, `qipdb` runs the component but shows a generic WASM
label because the form field has no filename.

The component must implement the [QIP TUI contract](https://qip.dev/docs/tui-components).
`qiptui` accepts one TUI component and does not run post-processing stages.
It checks terminal frames before writing them, rejects WebAssembly imports, and
requires a finite, unshared memory maximum of at most 256 MiB. Component memory
can grow within that declared limit. Downloads have
a 16 MiB limit, a 30-second timeout, and at most two redirects within the same
HTTPS origin.

## Publish

Run `make publish` from this directory. It publishes the version in
`package.json` and appends that version to `published-versions.txt` only after
`npm publish` succeeds. Commit the updated log. Add versions published by other
means to the log by hand.

## TODO

- Match `qipx`'s pre-execution Wasm checks: reject start functions and
  `memory.grow`, and verify that Content ABI getters are static. Keep the CLI
  dependency-free and in one executable file.
