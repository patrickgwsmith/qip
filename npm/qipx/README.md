# qipx

`qipx` renders, benchmarks, and tests QIP components in Node.js. Use its
zero-dependency CLI and library to compose pipelines and run interactive
terminal apps.

It supports [QIP Content components](https://qip.dev/docs/content-component),
[TUI components](https://qip.dev/docs/tui-components), and
[Compliance oracles](https://qip.dev/docs/comply).

The package targets Node.js 22 or newer. Useful component and oracle
downloads are available from [qip.dev/tools](https://qip.dev/tools) and
[qip.dev/oracles](https://qip.dev/oracles).

## Try It

Use the same `rgb-to-hex.wasm` component to render, benchmark, test, and debug.
Start by running it. qipx downloads the component from qip.dev and saves it at
`text/rgb-to-hex.wasm`:

```sh
printf 'rgb(101, 79, 240)' \
  | npx @qip.dev/qipx qip.dev run text/rgb-to-hex.wasm
```

It prints `#654ff0`.

Benchmark that saved component on the same input:

```sh
printf 'rgb(101, 79, 240)' \
  | npx @qip.dev/qipx qip.dev bench \
      -i - --runs 100 text/rgb-to-hex.wasm
```

Test its declared behavior with a reusable Compliance oracle:

```sh
npx @qip.dev/qipx qip.dev comply \
  text/rgb-to-hex.wasm \
  --with oracles/rgb-to-hex.comply.wasm
```

Then open the same component in the interactive debugger:

```sh
npx @qip.dev/qipx qip.dev tui \
  -F component=@text/rgb-to-hex.wasm \
  -F 'input=rgb(101, 79, 240)' \
  interactive/qipdb.wasm
```

Press `s` or ↓ to step into the next instruction, Space to continue, and
`Ctrl-C` to leave the debugger.

Multiple components run left to right. Hosts apply to every missing component
in the pipeline:

```sh
printf 'qip + wasm\n' \
  | npx @qip.dev/qipx qip.dev run \
      bytes/zlib-compress.wasm \
      bytes/base64-encode.wasm
```

## Run

Run a Content component pipeline:

```sh
qipx [host ...] run [options] <component.wasm> [component2.wasm ...]

Options:
  -i, --input <path>              Read input from a file instead of stdin
  -F, --form <name=value>         Add multipart text or file input (repeatable; @path or @-)
  -o, --output <path>             Write output to a file instead of stdout
  --max-memory <bytes>            Reject modules whose declared memory exceeds bytes
  --capacities-must-fit           Reject stages whose max output cannot fit next input
  -u, --uniform <name=value>      Set a uniform on the preceding component (repeatable)
```

Construct multipart input with text and exact file bytes:

```sh
qipx qip.dev run \
  -F 'input=rgb(101, 79, 240)' \
  -F component=@text/rgb-to-hex.wasm \
  multipart/form-data/form-data-to-tar.wasm \
  > component-input.tar
```

Use `@-` to read one file field from stdin. `--form` is an exact alias for
`-F`. Multipart form input and `-i` are mutually exclusive. Go `qip` and
Node.js `qipx` use the same fixed QIP boundary and produce byte-identical
multipart bodies for the same fields.

When hosts are present, a missing safe relative `.wasm` file referenced by
`-F name=@path.wasm` follows the same local-first download and caching rules as
a pipeline component. Other file paths remain local-only. Remote multipart
files receive only a WebAssembly 1.0 header check; the receiving component owns
profile and ABI validation.

## Host Resolution

Hosts are global execution context for `run`, `tui`, `dry run`, `bench`, and `comply`.
They also resolve eligible missing `.wasm` files referenced by `-F`.
Put them before the required subcommand, in fallback order:

```sh
qipx qip.dev mirror.example run text/markdown/gfm-commonmark.0.31.2.wasm
```

A host is a dotted ASCII DNS name with an optional port. Do not include a URL
scheme or path. IP addresses and `localhost` are not supported in this version.
qipx always uses HTTPS.

For each component, qipx constructs the same ordered source chain:

```text
0  local  text/markdown/gfm-commonmark.0.31.2.wasm
1  https  https://qip.dev/text/markdown/gfm-commonmark.0.31.2.wasm
2  https  https://mirror.example/text/markdown/gfm-commonmark.0.31.2.wasm
```

An existing local file always wins. Otherwise, qipx tries each host in order.
It validates the first successful response and saves it at the original
relative path. It creates parent directories but never replaces an existing
file. Only safe relative paths ending in `.wasm` are eligible; local directories
are not fetched.

Connection failures, TLS failures, timeouts, HTTP 404 or 410, and HTTP 5xx
responses advance to the next host. Other HTTP errors and invalid component
bytes stop resolution. Downloads follow at most two redirects on the same
HTTPS origin, time out after 30 seconds, and have a 16 MiB decoded-byte limit.

## TUI

Run a TUI component in the terminal:

```sh
qipx tui \
  -F component=@text/wc.wasm \
  -F 'input=The quick brown fox jumps over the lazy dog' \
  components/interactive/qipdb.wasm
```

The first component is retained across key events and scheduled updates.
Additional components act as ordinary Content transforms on every frame. The
host passes terminal size through optional `columns` and `lines` uniforms,
unless an explicit `-u` value overrides one.

TUI mode uses stdin for keys, so it rejects `-i -` and `-F name=@-`. It accepts
printable UTF-8, line feeds, and a small ANSI SGR styling allowlist from the
rendered output. It rejects cursor movement, OSC, DCS, clipboard commands, and
other terminal controls before writing a frame. `Ctrl-C` exits, `Ctrl-Z`
suspends on Unix, and `Ctrl-S`/`Ctrl-Q` remain reserved.

See [TUI Components](https://qip.dev/docs/tui-components) for the exact
keyboard and output rules.

### Uniforms

Put `-u <name=value>` or `--uniform <name=value>` after the component it
configures. Repeat the option to set more than one uniform:

```sh
qipx run text/text-to-bmp.wasm \
  -u cols=80 \
  -u leading=16 \
  < text.txt > out.bmp
```

Uniform keys are lowercase snake identifiers with 1 to 63 characters. They must
start with `[a-z]`, continue with `[a-z0-9_]*`, must not end with `_`, and must
not contain `__`.

Integer `i32` uniforms are treated as unsigned values. Use an `i64` uniform when
a component needs signed integer configuration.

## Comply

Check QIP Content compliance for files or directories:

```sh
qipx [host ...] comply [options] <file-or-dir> [...]

Options:
  --with <compliance.wasm>        Run a Compliance oracle (repeatable)
  --seed <n>                      Call uniform_set_seed(u32) on each oracle
  --max-memory <bytes>            Reject implementation memory above bytes
```

Load a component and a reusable oracle, then check them together:

```sh
npx @qip.dev/qipx qip.dev comply \
  text/utf8-must-be-valid.wasm \
  --with oracles/reject-invalid-utf8.wasm
```

`comply` accepts files and directories. Directories are searched recursively.
Each `.wasm` file is checked against the Strict Wasm Profile subset, static QIP
ABI exports, and QIP Content ABI.

Use `--with` to add one or more Compliance oracles. `qipx` runs the built-in
checks first, then runs each oracle through the `qip` bridge.

A Compliance oracle can also test a non-QIP implementation. A JS test can
instantiate the oracle `.wasm`, bind the `qip` imports, and route each declared
case to a normal JavaScript function that returns bytes or throws. The
implementation does not need to be WebAssembly; only the adapter must implement
the oracle bridge.

```text
PASS text/trim.wasm
PASS text/trim.wasm --with compliance/preserve-empty.wasm (1 cases)

pass=2 fail=0 total=2
```

## Bench

Benchmark one or more Content component implementations on reused Node/V8 or
Bun/JavaScriptCore instances:

```sh
# Node.js
NODE_OPTIONS=--expose-gc npx @qip.dev/qipx bench \
  -i README.md \
  --benchtime=3s \
  before.wasm \
  after.wasm

# Bun
BUN_OPTIONS=--expose-gc bunx --bun @qip.dev/qipx bench \
  -i README.md \
  --benchtime=3s \
  before.wasm \
  after.wasm
```

The first component is the output baseline. `qipx` compiles and instantiates
each component once, then warms and measures each component in input order.
Every warmup and measured render must have the same type and bytes as the
baseline.

Use repeatable `-F` or `--form` fields to benchmark a component that accepts
`multipart/form-data`:

```sh
qipx bench \
  -F component=@text/hello.wasm \
  --runs 100 \
  components/interactive/qipdb.wasm
```

Benchmark forms use the same canonical bytes as `qipx run` and Go `qip bench`.
`-F name=@-` reads one file field from standard input. `-F` and `-i` are
mutually exclusive.

The `NODE_OPTIONS` and `BUN_OPTIONS` prefixes opt into one collection after
each component's warmup and before its measured runs. `bunx --bun` overrides
the package's Node shebang.

Bun uses
[JavaScriptCore](https://docs.webkit.org/Deep%20Dive/JSC/JavaScriptCore.html),
WebKit's JavaScript and WebAssembly engine used by Safari.

```text
Options:
  -i, --input <path>              Read benchmark input from a file ('-' for stdin)
  -F, --form <name=value>         Add multipart text or file input (repeatable; @path or @-)
  -r, --runs <n>                  Measure exactly n runs per component
  --benchtime <duration>          Target measured time per component (default: 3s)
  --warmup <n>                    Warmup runs per component (default: 10)
  --max-memory <bytes>            Reject modules whose declared memory exceeds bytes
  -u, --uniform <name=value>      Set a uniform on the preceding component (repeatable)
```

Each timed render uses a reused Wasm instance and includes uniform setters and
input/output copies. The report shows latency distribution, render and input
throughput, relative performance, Wasm size, and runtime and engine details.
Input throughput is external input bytes divided by mean end-to-end time; it is
not memory bandwidth.

## Dry run

Validate a pipeline without reading input, calling `render`, or writing output:

```sh
qipx [host ...] dry run [options] <component.wasm> [component2.wasm ...]
```

`dry run` prints the complete source chain and observes local state without DNS
or HTTPS requests. It validates every component that is already local. Missing
components and pipeline connections that depend on them are deferred. It does
not create directories, read stdin, call `render`, or write output.

For multipart `@path.wasm` fields, it reports whether the local path is present
and lists eligible host candidates. It does not read or download the field.

## JavaScript API

Use Node's standard library to load files and the built-in `WebAssembly` APIs to
compile and instantiate. Then pass the instance to `newComponent`:

```js
import { readFile } from "node:fs/promises";
import {
  contentTypeUTF8,
  createRecipe,
  newComponent,
  newContentComponentContract,
  render,
  wasmMustComplyWithComponentContract,
} from "@qip.dev/qipx";

const label = "gfm-commonmark.0.31.2.wasm";
const wasm = await readFile("gfm-commonmark.0.31.2.wasm");
const contract = newContentComponentContract({
  label,
  maxMemory: 67108864,
  inputType: contentTypeUTF8("text/markdown"),
  outputType: contentTypeUTF8("text/html"),
});

wasmMustComplyWithComponentContract(wasm, contract);
// Synchronous equivalent:
// const instance = new WebAssembly.Instance(new WebAssembly.Module(wasm));
const { instance } = await WebAssembly.instantiate(wasm);
const markdown = newComponent(instance, contract);

const recipe = createRecipe([markdown]);
const result = render(recipe, "# Hello\n");

if ("outputString" in result) console.log(result.outputString);
```

A recipe can include existing recipes:

```js
const pageRecipe = createRecipe([
  markdownRecipe,
  pageWrap,
]);
```

The library keeps WebAssembly instantiation outside its contract so callers can
choose async or sync setup. It provides QIP-specific validation and execution:

- `wasmMustComplyWithComponentContract(bytes, contract)` checks the byte-level
  QIP Content contract before compilation and instantiation. It enforces the
  Strict Wasm Profile subset, `maxMemory`, no imports, no start function, no
  `memory.grow`, no atomics, the required Content exports, complete
  content-type metadata pairs, and static QIP ABI getter functions.
- `newContentComponentContract(options)` creates a reusable contract object for
  byte-level checks and instantiated component checks.
- `newComponent(instance, contract)` validates the instantiated QIP Content ABI
  and reads callable getter values and content-type metadata bytes. The
  contract can include `inputType: contentTypeUTF8(...)`, `inputType:
  contentTypeBytes(...)`, `outputType: contentTypeUTF8(...)`, or `outputType:
  contentTypeBytes(...)` when your code must verify the expected component
  contract.
- `createRecipe(stages, options)` checks stage compatibility before input
  bytes run. This is where content-type mismatches and
  `capacitiesMustFit` failures are reported.
- `render(componentOrRecipe, input)` executes synchronously against
  instantiated components. This is where runtime traps, input-too-large errors,
  component rejections, and invalid output length errors are reported. A
  `ContentRejection` exposes `inputOffset` and `failureMode` when that detail is
  available. A successful result always
  includes `outputBytes` and `outputType`. UTF-8 output also includes a lazy
  `outputString` getter.

`qipx` does not include a cache. If two recipes share a `.wasm` file, keep
the component yourself and pass it to each recipe that needs it.

## Failure modes

When validation or execution fails, the library throws an `Error` or
`RangeError`. The CLI prints the message and exits with code 1.

| Phase | Function or CLI point | Typical failures |
| --- | --- | --- |
| Component contract bytes | `wasmMustComplyWithComponentContract(bytes, contract)` or CLI component loading | invalid Wasm binary header; imports; start function; shared memory; `memory.grow`; atomics; malformed function bodies; declared memory exceeds `maxMemory`; memory has no declared maximum when `maxMemory` is set; missing Content exports; non-static ABI getters |
| Instantiation and ABI | `newComponent(instance, contract)` | exported memory is missing; `render` is missing; the input pointer or input/output capacity exports are missing or ambiguous; declared content type is invalid |
| Recipe validation | `createRecipe(...)` | a stage expects a different content type than the previous stage produced; recipe content type is unspecified for a stage that declares an input type; `capacitiesMustFit` finds producer output capacity larger than consumer input capacity |
| Execution | `render(componentOrRecipe, input)` | input bytes do not fit the stage input buffer; the component rejects input or traps; returned output length exceeds the advertised output capacity or memory bounds |
| Compliance bridge | `qipx comply impl.wasm --with oracle.wasm` | oracle does not export `memory` or `comply`; oracle imports other than the `qip` bridge; bridge ordinals are not sequential; expected output does not match actual output; expected trap does not trap; must_render_into protocol is not closed |

Example `maxMemory` failure:

```text
component.wasm declares maximum memory 67108864 bytes, exceeding --max-memory 8388608
```

Example pipeline compatibility failure:

```text
markdown.wasm expects text/markdown, got text/html
```

Example capacity compatibility failure:

```text
zlib-compress.wasm output capacity 8389259 exceeds base64-encode.wasm input capacity 65536
```
