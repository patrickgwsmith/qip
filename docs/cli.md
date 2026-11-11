# Command-Line Hosts

Five command-line hosts run QIP components. Every one has a Node.js version, which requires Node.js 22 or newer and has no runtime dependencies. `qipx` also has a Rust version, built on Wasmtime.

| Command | Language | Runs | Use it to |
| --- | --- | --- | --- |
| [`qipdo`](#qipdo) | Node.js | A chain of [Content components](/docs/content-component) | Transform input into output, like a Unix pipe. |
| [`qipx`](#qipx) | Node.js, Rust | Content and [TUI components](/docs/tui-components), and [Compliance oracles](/docs/comply) | Run, dry-run, benchmark and check components from one tool. |
| [`qipok`](#qipok) | Node.js | Content components, files or directories, and [Compliance suites](/docs/comply) | Check components follow the Content ABI and pass their suites, as `qipx comply` does. |
| [`qiptui`](#qiptui) | Node.js | One TUI component, or one plain-text Content component | Use an interactive text component in a terminal. |
| [`qipgui`](#qipgui) | Node.js | One [GUI component](/docs/gui-components), plus optional transforms | Use a pixel-based component in a terminal with Kitty graphics. A prototype. |

`qipdo` and `qipx run` behave the same: they share a test suite with the Rust `qipx`. Pick `qipdo` when you only need to run pipelines, and `qipx` when you also want to benchmark or check compliance.

## Shared Conventions

### Components and hosts

Components are `.wasm` paths. A dotted DNS name such as `qip.dev` before the first component is a host. When a relative `.wasm` path doesn't exist locally, the CLI downloads the same path from each host in order over HTTPS:

```sh
printf '# Hello\n' | npx qipdo qip.dev text/markdown/gfm-commonmark.0.31.2.wasm
```

An existing local file always wins. `qipdo` and `qipx` save each download at its relative path, so later runs stay local. `qiptui` and `qipgui` keep downloads in memory for that run only, and also accept a hosted path such as `qip.dev/tui/calendar-gregorian.wasm`.

Downloads have a 16 MiB limit, a 30-second timeout, and follow at most two redirects within the same HTTPS origin. Naming a host trusts it to supply executable component bytes.

### Input

| Option | Effect |
| --- | --- |
| `-i <path>` | Read input from a file. `-i -` reads piped stdin. |
| `-F name=value` | Add a UTF-8 field to a `multipart/form-data` input. |
| `-F name=@path` | Add a file's bytes, with its basename as the filename. |
| `-F 'name=<path'` | Add a file's bytes as a regular field, without a filename. |

With no input option, `qipdo` and `qipx run` read stdin. Combining `-i` with `-F` builds `multipart/related` input instead. See [Multipart input](/docs/qipx#multipart-input) for the exact encoding. `qipgui` accepts `-i` but not `-F`.

### Uniforms

`-u name=value` sets a [uniform](/docs/uniforms) on the component just before it:

```sh
npx qipdo -i input.txt text-to-bmp.wasm -u cols=80 -u leading=16 -o output.bmp
```

Each value is parsed for the setter's parameter type. Integers accept decimal or `0x` hex. A fractional, out-of-range or overflowing value is an error; it is never truncated, wrapped or rounded.

### Checks before running

Every CLI rejects a module before running it unless it stays inside the [hard limits](/docs/hard-limits): no imports, a finite unshared memory maximum, no `memory.grow`, no start function, only Strict Wasm Profile opcodes, and static Content ABI getters. A chain is also checked before anything runs: each component's input type must match the output type of the one before it.

The memory limits differ. `qipdo`, `qipx` and `qipok` take `--max-memory <bytes>`, `qiptui` allows up to 256 MiB, and `qipgui` allows up to 1 GiB per component so it can run large rasterizers.

## qipdo

`qipdo` runs Content components left to right. Each component's output becomes the next one's input:

```sh
echo '<b>hi</b>' | npx qipdo qip.dev text/html/html-escape.wasm
npx qipdo qip.dev -i page.md text/markdown/markdown-basic.wasm -o page.html
```

| Option | Effect |
| --- | --- |
| `-o <path>` | Write output to a file instead of stdout. |
| `--dry-run` | Check the chain without reading input or rendering. |
| `--strict-capacities` | Fail before running when a step's output capacity exceeds the next step's input capacity. Without it, a run fails only if the real output doesn't fit. |
| `--max-memory <bytes>` | Reject modules that declare more memory. |

## qipx

`qipx` runs Content components and also covers the rest of a component's life cycle:

| Subcommand | Use |
| --- | --- |
| `run` | Run a Content component pipeline, as `qipdo` does. |
| `dry run` | Show every source a component could load from, and validate the pipeline without network requests. |
| `tui` | Run one TUI component, with optional Content transforms after it. |
| `bench` | Compare warmed components on the same input. Every candidate must return the same bytes. |
| `comply` | Check the Content ABI and run Compliance oracles. |

```sh
printf 'rgb(101, 79, 240)' | npx @qip.dev/qipx qip.dev run text/rgb-to-hex.wasm
npx @qip.dev/qipx qip.dev comply text/rgb-to-hex.wasm --suite oracles/rgb-to-hex.comply.wasm
```

The Rust `qipx` has the same subcommands and runs Wasm with Wasmtime. Build it from a checkout with `make qipx-rust`, then run `rust/qipx/target/debug/qipx`.

See the [qipx reference](/docs/qipx) for host resolution, dry runs and multipart input in full, and [Benchmarking Components](/docs/benchmarking-components) for reading `bench` results.

## qipok

`qipok` checks that Content components are ok: that they follow the Content ABI and the Strict Wasm Profile, and that they pass any [Compliance suites](/docs/comply) you give it. It is `qipx comply` without the subcommand, and shares its test suite with `qipx comply` and the Rust `qipx`.

```sh
npx qipok text/hello.wasm
npx qipok text/ --max-memory 16777216
npx qipok qip.dev text/cve.wasm --suite compliance/cve.comply.wasm
```

Each check prints `PASS` or `FAIL`, then a summary such as `pass=2 fail=0 total=2`. `qipok` exits 1 if any check fails. A directory is searched for `.wasm` files, without following symlinks.

| Option | Effect |
| --- | --- |
| `--suite <suite.wasm>` | Also run a Compliance suite on each component. Repeatable. |
| `--seed <n>` | Seed suites that export `uniform_set_seed`. Without it, each such suite gets a random seed, reported in the summary so you can repeat the run. |
| `--max-memory <bytes>` | Reject components that declare more memory. |

## qiptui

`qiptui` runs one component in a terminal and redraws it after each key, resize or wake deadline:

```sh
npx qiptui qip.dev/tui/calendar-gregorian.wasm
npx qiptui qip.dev -F 'input=Hello' -F component=@text/wc.wasm tui/qipdb.wasm
```

It accepts:

- **TUI components**, which receive keys and updates as described in [TUI Components](/docs/tui-components).
- **Plain-text Content components** that take UTF-8 `text/plain` input and export no events. `qiptui` adds an editable text field above the output and re-renders on every edit, so a search component becomes a live search. Up and Down change `active_index` when the component supports it.

`qiptui` runs one component with no transforms after it. Use `qipx tui` for a chain. When stdin carries input (`-i -` or `-F name=@-`), keys are read from the terminal on stderr instead. `Ctrl-C` exits and restores the terminal.

## qipgui

`qipgui` is a prototype. It isn't published to npm yet, so run it from a checkout of the repository.

It shows a GUI component in a terminal that supports the [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/) and pixel mouse reports, such as kitty, Ghostty and WezTerm. Each KTX2 frame is sent to the terminal as an image, and mouse clicks and drags become `pointer_event` calls:

```sh
node npm/qipgui/qipgui.mjs gui/calculator.wasm
node npm/qipgui/qipgui.mjs --size fill gui/paint.wasm
```

Components after the first transform each frame, and the last one must output KTX2 `R8G8B8A8_SRGB`. Only the first component receives keys, pointer events and updates. This lets an SVG component run through a rasterizer:

```sh
node npm/qipgui/qipgui.mjs gui/klondike.wasm \
  image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm -u background_color_rgba=0xffffffff
```

Transforms are assumed only to scale the frame, so clicks are mapped back to the first component's own size.

| Option | Effect |
| --- | --- |
| `--size auto\|native\|fill` | Show pixels 1:1, shrinking to fit the window (`auto`, the default), always 1:1 (`native`), or scaled to fill the window (`fill`). |
| `--transport direct\|zlib\|file` | Send frames as base64 RGBA (`direct`, the default), as compressed RGBA (`zlib`), or through a temporary file. `file` only works when the terminal runs on the same machine. |
| `--stats` | On exit, print the frame rate, render and encode times, bytes per frame, and input-to-frame latency. |

The [qipgui README](https://github.com/royalicing/qip/blob/main/npm/qipgui/README.md) has measured frame costs and what's still to verify in real terminals.
