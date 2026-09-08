# `qipx` cli

`qipx` runs QIP Content components in Node.js. Use it to run content recipes, check components against compliance oracles, and benchmark multiple components against each other.

The package requires Node.js 22 or newer. Run it without installing it globally:

```sh
npx @qip.dev/qipx --help
```

## Subcommands

| Command | Use |
| --- | --- |
| `qipx [host ...] run [options] <component.wasm> [...]` | Run one Content component or a left-to-right component pipeline. Input comes from stdin by default; output goes to stdout. |
| `qipx [host ...] dry run [options] <component.wasm> [...]` | Show the complete source plan and validate locally available pipeline stages without network requests, input reads, or rendering. |
| `qipx [host ...] tui [options] <tui.wasm> [content.wasm ...]` | Run one TUI component in a terminal, with optional Content transforms after it. |
| `qipx [host ...] comply [options] <file-or-dir> [...]` | Check the Content ABI and strict WebAssembly subset, then run any Compliance oracles supplied with `--with`. |
| `qipx [host ...] bench (-i <input> \| -F <name=value>) [options] <component.wasm> [...]` | Compare warmed Content components on Node/V8 or Bun/JavaScriptCore. Every candidate must return the same type and bytes as the first component. |

Run `npx @qip.dev/qipx --help` for the current options. Uniform options follow the component they configure:

```sh
npx @qip.dev/qipx run text-to-bmp.wasm \
  -u cols=80 \
  -u leading=16 \
  < input.txt > output.bmp
```

## Load from hosts

Put one or more hosts before the required subcommand. A host is a dotted ASCII DNS name with an optional port. Do not include `https://`, credentials, a path, a query, or a fragment. IP addresses and `localhost` are not supported in this version.

```sh
printf '# Hello from qipx\n' \
  | npx @qip.dev/qipx qip.dev run text/markdown/gfm-commonmark.0.31.2.wasm
```

The component path produces this ordered source chain:

```text
0  local  text/markdown/gfm-commonmark.0.31.2.wasm
1  https  https://qip.dev/text/markdown/gfm-commonmark.0.31.2.wasm
```

An existing local file always wins. If the file is missing, qipx requests the same relative path from each host in order. A successful response is validated and saved at the original relative path. qipx creates missing parent directories, but it never replaces an existing file. Later commands use the local file without a request.

Only missing, safe relative paths that end in `.wasm` can use a host. Absolute paths, parent segments such as `..`, backslashes, queries, fragments, and local directories are never fetched. Direct `.wasm` arguments to `comply` and its `--with` oracles use the same resolution rules.

Host fallback handles unavailable sources: connection and TLS failures, timeouts, HTTP 404 or 410, and HTTP 5xx responses. Other HTTP errors stop resolution. A response that is not valid for its command also stops resolution and is not saved. This prevents a bad first host from being hidden by a later mirror.

Downloads use HTTPS, follow at most two redirects on the same HTTPS origin,
time out after 30 seconds, and have a 16 MiB decoded-byte limit. A redirect to
a different origin stops resolution. Supplying a host trusts it to provide
executable component bytes. A fallback host also learns each component path
requested from it.

### Dry run

Dry run uses the same source planner but stops before network resolution:

```sh
qipx qip.dev mirror.example dry run text/markdown/gfm-commonmark.0.31.2.wasm
```

It prints every possible source, observes local files, and validates each component that is already available. Missing components and pipeline connections that depend on them are deferred. Dry run makes no DNS or HTTPS requests, does not create directories, does not read command input, does not call `render`, and does not write output.

## Try a component

Load the GitHub Flavored Markdown renderer from qip.dev. The first command vendors it locally; later commands remain local:

```sh
printf '# Hello from qipx\n' \
  | npx @qip.dev/qipx qip.dev run text/markdown/gfm-commonmark.0.31.2.wasm
```

See the [Content Component Contract](/docs/content-component) for the ABI, [Compliance oracles](/docs/comply) for portable behavior checks, and [Benchmarking Components](/docs/benchmarking-components) for benchmark interpretation.

`qipx` deliberately focuses on Content components, TUI components, and
Compliance oracles. It does not serve router projects or run Tile and Form
components. See [TUI Components](/docs/tui-components) for the composed
contract, input mapping, and terminal-output boundary.

## Multipart input

Use repeatable `-F` or `--form` options instead of `-i` to construct one
`multipart/form-data` input:

```sh
qipx run \
  -F mode=step \
  -F component=@examples/counter.wasm \
  components/multipart/form-data/form-data-to-tar.wasm \
  > debugger-input.tar
```

`-F name=value` adds a UTF-8 field. `-F name=@path` adds the file's exact
bytes and sends only its final path segment as `filename`. `-F name=@-` reads
one file field from stdin and sends `filename="-"`. Only one field may use
`@-`. `--form` is an exact alias for `-F`. Multipart form input and `-i` are
mutually exclusive.

Go `qip` and Node.js `qipx` produce byte-identical bodies. They preserve flag
order, use `Content-Type: application/octet-stream` for file fields, use CRLF
framing, and use the component contract's default boundary:

```text
multipart/form-data;boundary=uuid-00000000-0000-0000-0000-000000000000
```

Field names and emitted filenames must be printable ASCII without quotes or
backslashes. Both CLIs reject a part body that contains the fixed boundary as
a delimiter line. A `run` command still requires at least one component. Use
`components/bytes/identity.wasm` when you need to inspect the complete body.
