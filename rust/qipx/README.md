# qipx for Rust

`qipx` is a command-line host for QIP WebAssembly components. It runs Content
pipelines, interactive terminal components, Compliance oracles, and benchmarks.
It uses Wasmtime to execute Wasm and has no Rust library API.

After publication, install the executable with:

```sh
cargo install qipx
```

For a source checkout, use `make -j qipx-rust` and run
`rust/qipx/target/debug/qipx`.

## Run a Content pipeline

```sh
printf '  hello  ' | qipx run text/trim.wasm bytes/identity.wasm
qipx run -i input.txt -o output.txt text/trim.wasm
qipx run -F mode=step -F component=@component.wasm multipart/form-data/form-data-to-tar.wasm
```

Input comes from stdin and output goes to stdout by default. UTF-8 output gets
one final line feed on stdout. `-F name=value` builds a multipart text field;
`-F name=@path` reads exact file bytes; one field may use `@-` to read stdin.
`-F` and `-i` cannot be combined. Add `-u name=value` after the component that
receives the uniform. `--max-memory` checks the module's declared memory, and
`--capacities-must-fit` checks each stage's maximum output against the next
stage's input capacity.

`qipx dry run` checks locally available stages and shows the ordered source
plan. It does not fetch components, read command input, or call `render`.

## Run a terminal component

```sh
qipx tui components/interactive/calendar-gregorian.wasm
```

TUI mode needs terminal stdin and stdout. It retains the first component
across key events and scheduled updates. Additional stages transform each
frame. It checks rendered text before writing to the terminal and permits
only printable UTF-8, line feeds, and a narrow set of ANSI SGR styles. Use
`Ctrl-C` to exit. TUI mode does not accept `-i -` or `-F name=@-` because stdin
carries keys.

## Check and benchmark components

```sh
qipx comply bytes/identity.wasm --with compliance/preserve-empty.wasm
qipx bench -i input.txt --runs 100 before.wasm after.wasm
qipx bench -F input=hello --benchtime=3s before.wasm after.wasm
```

`comply` accepts files and directories, searches directories recursively, and
reports each built-in or oracle check. `--seed` sets an oracle's
`uniform_set_seed`. `bench` verifies that every candidate returns the same
output before timing and reuses each instance. The reported time covers input
and output copies and `render`; it does not represent another host runtime.

## Download missing components

```sh
printf 'hello' | qipx qip.dev run bytes/identity.wasm
```

Put dotted DNS hosts before the subcommand. An existing local file wins. A
missing safe relative `.wasm` path is fetched over HTTPS, checked, and saved
at that path. qipx verifies TLS certificates, tries hosts in order for
unavailable sources, follows at most two redirects on the same HTTPS origin,
and limits a download to 16 MiB and 30 seconds. Supplying a host trusts it to
provide executable component bytes. Use a local path when that trust is not
appropriate.

For the component contracts and MIME rules, see [QIP Component Contracts](https://qip.dev/docs/component-contract).
