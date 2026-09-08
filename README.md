```
┏━━━┓ ━┳━ ┏━━━┓
┗━┳━┛ ━┻━ ┣━━━┛
```

QIP Components are Quick to run/make/maintain, Isolated from network/disk/dependencies, and Portable across browser/server/native.

QIP Components are fast for you to create with coding agents and fast for users to run. Your users get small `.wasm` modules that load fast. You get small amounts of code that is easy to review.

We believe small functions should not need a massive application environment to run. Write or vibe Zig/C then compile to WebAssembly, and you get a deterministic puzzle piece that runs the same everywhere in the browser, on the server, on native, or in your terminal.

Render text, images, documents, PDFs, zip files, or even interactive TUIs or GUIs. Components pass content in and content out, with  an optional MIME type for each side. You can combine components step-by-step like a recipe.

Make a recipe you like? You can be confident it will work identically on mobile, in a browser, in your CI pipeline, on Windows, or whatever comes next. If it works here, it works there.

Modern software never stops moving. QIP components are self-contained, so you can worry less about supply-chain attacks, outdated libraries, remote-code execution, and environment drift.

QIP is built around a strict contract: same component with the same input results in the same output. It does not read the clock, locale, filesystem, package graph, environment variables, OS, device, config, or network — unless you deliberately pass it in. Every input is explicit. This determinism means if it works today, it’ll continue to work tomorrow.

Components, AI coding, security: you can pick all three.

## Install CLI

```bash
npm install --global @qip.dev/qipx
```

`qipx` requires Node.js 22 or newer.

## Try It

Let's start by running `rgb-to-hex.wasm`. qipx downloads the component from qip.dev and saves it locally at `text/rgb-to-hex.wasm`:

```sh
printf 'rgb(101, 79, 240)' \
  | npx @qip.dev/qipx qip.dev run text/rgb-to-hex.wasm
```

It prints `#654ff0`.

Now benchmark the same component with the same input:

```sh
printf 'rgb(101, 79, 240)' \
  | npx @qip.dev/qipx qip.dev bench \
      -i - --runs 100 text/rgb-to-hex.wasm
```

Test behavior complies with a reusable oracle that checks a range of expected output or can even fuzz:

```sh
npx @qip.dev/qipx qip.dev comply \
  text/rgb-to-hex.wasm \
  --with oracles/rgb-to-hex.comply.wasm
```

Then open the same component in the interactive qipdb debugger:

```sh
npx @qip.dev/qipx qip.dev tui \
  -F component=@text/rgb-to-hex.wasm \
  -F 'input=rgb(101, 79, 240)' \
  interactive/qipdb.wasm
```

Press ↓ to step instruction by instruction seeing state of memory and every variable. Press Space to continue to completion and `Ctrl-C` to exit.

Multiple components run left to right like a unix pipeline:

```sh
printf 'qip + wasm\n' \
  | npx @qip.dev/qipx qip.dev run \
      bytes/zlib-compress.wasm \
      bytes/base64-encode.wasm
```

## qipdb

qipdb runs a QIP Content component inside a small WebAssembly interpreter and
shows its instructions, operand stack, locals, globals, linear memory, calls,
loops, and live counters.

Start with the small `rgb-to-hex` component:

```sh
npx @qip.dev/qipx qip.dev tui \
  -F component=@text/rgb-to-hex.wasm \
  -F 'input=rgb(101, 79, 240)' \
  interactive/qipdb.wasm
```

Inspect a larger Commonmark Markdown component with tables and indirect calls:

```sh
npx @qip.dev/qipx qip.dev tui \
  -F component=@text/markdown/commonmark.0.31.2.wasm \
  -F 'input=# Hello from qipdb' \
  interactive/qipdb.wasm
```

Debug a PNG decodee with SIMD acceleration passing a image file as input:

```sh
npx @qip.dev/qipx qip.dev tui \
  -F component=@image/png/png-to-bmp-b8g8r8a8-srgb-simd.wasm \
  -F input=@qip-logo.png \
  interactive/qipdb.wasm
```

qipdb deliberately supports a bounded
WebAssembly profile rather than every WebAssembly feature, this lets it gain determinism.

## Module contract

QIP does not use WASI or WIT, standards that have ballooned in complexity from scope creep. We want to get stuff done in today’s browsers so we pick a much smaller contract between hosts and modules:

- `input_ptr()` / `input_bytes_cap()`: where the host writes input.
- `input_content_type_ptr()` / `input_content_type_size()`: optional MIME type of the input
- `output_bytes_cap()`: the declared maximum output size.
- `output_content_type_ptr()` / `output_content_type_size()`: optional MIME type of the output
- `render(input_size) -> i64`: function that does the work to transform input and return the output pointer and
  size, or reject the input.
- `uniform_set_<key>(value)`: optional primitive integer/float parameters applied before rendering.

You can read more about the [Content component contract in our docs](./docs/content-component.md).

## CLI Usage

You can pipe the results of other CLI tools to stdin, pass one raw file with
`-i`, or construct multipart input with repeatable `-F` options. You can also
chain multiple QIP components together like unix tools.

Put one or more HTTPS hosts before `run`, `dry run`, `bench`, or `comply` to
load a missing component by its relative path:

```bash
printf '# Hello\n' \
  | qipx qip.dev run text/markdown/gfm-commonmark.0.31.2.wasm
```

`qipx` uses local components when available. Otherwise, it downloads them over HTTPS and saves them at the same local file path for later runs. There's no special protocol or discovery mechanism: it’s just a GET.

```bash
npm install --global @qip.dev/qipx

# Convert purple from rgb to hex
echo "rgb(101, 79, 240)" | qipx run components/text/rgb-to-hex.wasm
# #654ff0

# Normalize phone number
echo "+1 (212) 555-0100" | qipx run components/text/e164.wasm
# +12125550100

# Expand emoji shortcodes
echo "Run :rocket: WebAssembly components identically on any computer :sparkles:" | qipx run components/text/shortcode-to-emoji.wasm
# Run 🚀 WebAssembly components identically on any computer ✨

# Create zlib bytes (dynamic Huffman, shown as base64)
echo "qip + wasm" | qipx run components/bytes/zlib-compress-dynamic-huffman.wasm components/bytes/base64-encode.wasm
# eAEFwKENAAAMArBX8LtqcmIJBMH7VEcMsv4CEnkDbg==

# Round-trip zlib back to original text
echo "qip + wasm" | qipx run components/bytes/zlib-compress-dynamic-huffman.wasm components/bytes/zlib-decompress.wasm
# qip + wasm

# Load Hacker News, extract all links
curl -s https://news.ycombinator.com | qipx run components/text/html/html-link-extractor.wasm

# Render QIP logo to ICO
qipx run -i qip-logo.svg \
  components/image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm \
  components/image/ktx2/ktx2-r8g8b8a8-srgb-double.wasm \
  components/image/ktx2/ktx2-r8g8b8a8-srgb-to-favicon.wasm \
  > qip-logo.ico

# Render Switzerland flag SVG to ICO
echo '<svg width="32" height="32"><rect width="32" height="32" fill="#d52b1e" /><rect x="13" y="6" width="6" height="20" fill="#ffffff" /><rect x="6" y="13" width="20" height="6" fill="#ffffff" /></svg>' \
  | qipx run \
      components/image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm \
      components/image/ktx2/ktx2-r8g8b8a8-srgb-to-favicon.wasm \
  > switzerland-flag.ico

```

## Guide to making QIP components

There are a few recommended languages for writing QIP components: Zig, C, or raw WebAssembly text format.

### Zig: infallible component

Here we’ll write an infallible QIP component for an E.164 canonicalizer. It
takes a phone number and converts it into a canonical international form. It
does not export `failure_modes_per_input_offset`, and every successful call
sets `failed` to zero.

- `+1 (212) 555-0100` -> `+12125550100`
- `  1212-555-0100  ` -> `+12125550100`

#### 1. Create `e164.zig`

```zig
// The input is maximum 64KiB
const INPUT_CAP: usize = 64 * 1024;
// The output is maximum 64KiB
const OUTPUT_CAP: usize = 64 * 1024;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

// Export functions so the QIP host can read these static values.
export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_utf8_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

export fn render(input_size_in: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    if (input_size_in > INPUT_CAP) @trap();
    const input_size: usize = @intCast(input_size_in);

    // Emit '+' then append only digits.
    output_buf[0] = '+';
    var output_size: usize = 1;

    var i: usize = 0;
    while (i < input_size) : (i += 1) {
        const c = input_buf[i];

        if (!isDigit(c)) continue;

        if (output_size >= OUTPUT_CAP) @trap();

        output_buf[output_size] = c;
        output_size += 1;
    }

    // If just '+' then return empty string.
    if (output_size == 1) output_size = 0;

    return .{
        .output_size = @intCast(output_size),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}
```

#### 2. Compile it to WebAssembly

```bash
zig build-exe e164.zig \
  -target wasm32-freestanding \
  -O ReleaseSmall \
  -fno-entry \
  --export=render \
  --export=input_ptr \
  --export=input_utf8_cap \
  --export=output_utf8_cap \
  -femit-bin=e164.wasm
```

#### 3. Run it with `qipx`

```bash
echo "+1 (212) 555-0100" | qipx run e164.wasm
# +12125550100

echo "  1212-555-0100  " | qipx run e164.wasm
# +12125550100
```

#### 4. Import it from JavaScript

When your JavaScript runtime or bundler supports direct WebAssembly ES module
imports, import the QIP exports and wrap the memory exchange in a normal
JavaScript function:

```js
import {
  memory,
  input_ptr,
  input_utf8_cap,
  render,
} from "./e164.wasm";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function normalizeE164(phoneNumber) {
  const input = new Uint8Array(
    memory.buffer,
    input_ptr(),
    input_utf8_cap(),
  );
  const { read, written } = encoder.encodeInto(phoneNumber, input);
  if (read !== phoneNumber.length) {
    throw new RangeError("phone number exceeds input capacity");
  }

  const result = BigInt.asUintN(64, render(written));
  if ((result >> 63n) !== 0n) throw new Error("component rejected input");
  const outputSize = Number(result & 0xffff_ffffn);
  const outputPtr = Number((result >> 32n) & 0x7fff_ffffn);
  return decoder.decode(
    new Uint8Array(memory.buffer, outputPtr, outputSize),
  );
}

console.log(normalizeE164("+1 (212) 555-0100"));
// +12125550100
```

This uses the component directly: encode the input, write it at `input_ptr()`,
call `render()`, then decode the pointer and size in its result. There is no QIP
JavaScript runtime or reusable wrapper involved. It assumes `e164.wasm` is the
known-valid component built above; hosts accepting arbitrary Wasm need a
separate validation boundary described by the [Content Component
Contract](docs/content-component.md#known-and-untrusted-components). Direct
`.wasm` imports depend on runtime or bundler support; [Running In
JavaScript](docs/running-in-javascript.md) covers the equivalent
explicit-instantiation fallback.

### C

We’ll write some C to trim leading and trailing whitespace.

#### 1. Create `trim.c`

```c
#include <stdint.h>

#define INPUT_CAP (4u * 1024u * 1024u)
static char input_buffer[INPUT_CAP];

__attribute__((export_name("input_ptr")))
uint32_t input_ptr() {
    return (uint32_t)(uintptr_t)input_buffer;
}

__attribute__((export_name("input_utf8_cap")))
uint32_t input_utf8_cap() {
    return sizeof(input_buffer);
}

__attribute__((export_name("output_utf8_cap")))
uint32_t output_utf8_cap() {
    return sizeof(input_buffer);
}

static int is_space(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}

__attribute__((export_name("render")))
uint64_t render(uint32_t input_size) {
    if (input_size > INPUT_CAP) __builtin_trap();

    uint32_t start = 0;
    while (start < input_size && is_space(input_buffer[start])) {
        start++;
    }

    uint32_t end = input_size;
    while (end > start && is_space(input_buffer[end - 1])) {
        end--;
    }

    uint32_t output_size = end - start;
    uint32_t output_ptr = (uint32_t)(uintptr_t)(input_buffer + start);
    return ((uint64_t)output_ptr << 32) | output_size;
}
```

#### 2. Compile it to WebAssembly

```bash
zig cc trim.c \
  -target wasm32-freestanding \
  -nostdlib \
  -Wl,--no-entry \
  -Wl,--export=render \
  -Wl,--export-memory \
  -Wl,--export=input_ptr \
  -Wl,--export=input_utf8_cap \
  -Wl,--export=output_utf8_cap \
  -Oz \
  -o trim.wasm
```

#### 3. Run it with `qipx`

```bash
echo "   hello world   " | qipx run trim.wasm
# hello world

printf "\t  line one  \n" | qipx run trim.wasm
# line one
```

### Raw WebAssembly

You can also write raw WebAssembly text format which compiles directly to `.wasm`. Here is a hello world example:

```wasm
(module $YourTextModule
;; Memory must be exported with name "memory"
  ;; First page empty, input at 0x10000, output at 0x20000
  (memory (export "memory") 3)

  ;; Internal buffer constants with function exports for qip integration
  (global $input_ptr i32 (i32.const 0x10000))
  (global $input_utf8_cap i32 (i32.const 0x10000))
  (global $output_ptr i32 (i32.const 0x20000))
  (global $output_utf8_cap i32 (i32.const 0x10000))

  (func (export "input_ptr") (result i32)
    (global.get $input_ptr))
  (func (export "input_utf8_cap") (result i32)
    (global.get $input_utf8_cap))
  (func (export "output_utf8_cap") (result i32)
    (global.get $output_utf8_cap))

  ;; Required export: render(input_size) -> packed output pointer and size
  (func (export "render") (param i32 $input_size) (result i64)
    ;; Write "Hello, World" as i64 + i32
    ;; "Hello, W" as i64 (little-endian: 0x57202c6f6c6c6548)
    (i64.store (global.get $output_ptr) (i64.const 0x57202c6f6c6c6548))
    ;; "orld" as i32 (little-endian: 0x646c726f)
    (i32.store (i32.add (global.get $output_ptr) (i32.const 8)) (i32.const 0x646c726f))
    ;; Put the pointer in bits 32..62 and the size in bits 0..31.
    (i64.or
      (i64.shl
        (i64.extend_i32_u (global.get $output_ptr))
        (i64.const 32))
      (i64.const 12))
  )
)
```

## Router

The Node.js `qip-router` CLI makes static websites from files and QIP recipes:

1. Put website source content in a directory (Markdown, HTML, images, CSS, etc.).
2. Add recipe QIP components to transform source files by MIME type. For example you could create a `_recipes/text/markdown/10-markdown-to-html.wasm` to render Markdown to HTML.
3. Preview locally with `npx qip-router dev`.
4. Export as static files with `npx qip-router warc`.

Example content:

```text
docs/
  index.md
  about.md
  images/logo.png
docs/_recipes/
  text/markdown/10-markdown-to-html.wasm
  text/markdown/20-html-page-wrap.wasm
```

Preview in dev mode:

```bash
npx qip-router dev ./docs -p 4000
open http://localhost:4000
```

Resolve a single path through the same router pipeline:

```bash
# GET /about
npx qip-router get ./docs /about
# HEAD /about
npx qip-router head ./docs /about
# List all routes
npx qip-router list ./docs
```

Build static tar from the site:

```bash
npx qip-router warc ./docs \
  | qipx run components/application/warc/warc-to-static-tar-no-trailing-slash.wasm \
  > site.tar

tar -tf site.tar

ls ./site
```

## Documentation

- [QIP Component Contracts](docs/component-contract.md)
- [Content Component Contract](docs/content-component.md)
- [Time And Events](docs/time-and-events.md)
- [GUI Components](docs/gui-components.md)
- [TUI Components](docs/tui-components.md)
- [Uniforms](docs/uniforms.md)
- [QIP Component Patterns](docs/module-patterns.md)
- [Writing QIP Components in Zig](docs/zig-components.md)
- [Building C Libraries as QIP Components](docs/c-wasm-toolchains.md)
- [Translating QIP Components To C](docs/qip-component-to-c.md)
- [Translating QIP Components To Zig](docs/qip-component-to-zig.md)
- [Translating QIP Components To Swift](docs/qip-component-to-swift.md)
- [Hard Limits](docs/hard-limits.md)
- [Provable Loops](docs/provable-loops.md)
- [Running In JavaScript](docs/running-in-javascript.md)
- [qipx CLI](docs/qipx.md)
- [QIP Component Compliance](docs/comply.md)

----

## Required build and test tools

If you are contributing components or running the full `Makefile` in this repo, install these tools:

- `make` and standard POSIX command-line tools such as `find`, `diff`, `tar`, `perl`, and `xxd`
- Go (required for `qip` CLI): https://go.dev/doc/install
- Zig (used for `.zig` and `.c` -> `.wasm` builds): https://ziglang.org/download/
- `wat2wasm` from WABT (used for `.wat` -> `.wasm` builds): https://github.com/WebAssembly/wabt
- Node.js 20+ (used by `make test-node` and the default `make test` path): https://nodejs.org/
- Deno (optional, used by `make test-deno`): https://deno.com/

Quick installs:

```bash
# macOS (Homebrew)
brew install go zig wabt node

# Ubuntu/Debian (install Node.js 20+ from your preferred Node distribution)
sudo apt-get update
sudo apt-get install -y build-essential golang-go wabt perl vim-common
```

After installing dependencies, build in parallel:

```bash
make -j components recipes
```

Run the test targets through the Makefile:

```bash
make -j test-node
make -j test-deno
make -j test-go
make -j test
```

`test/trace-with.mjs` is included in both `make -j test-node` and `make -j test-deno`. To run it directly with Node:

```bash
make -j qip components/application/wasm/wasm-trace-instrument.wasm
node --test test/trace-with.mjs
```

To run it directly with Deno, pass the same permissions used by `make test-deno`:

```bash
deno test --allow-read --allow-write --allow-run --allow-sys --allow-env test/trace-with.mjs
```

You can clone this repo to use the components provided in `./components`.

The component layout groups components by content domain and media type:

```text
components/
  bytes/
  image/svg+xml/
  text/
    css/
    html/
    javascript/
    markdown/
    x-c/
  rgba/
```

## Benchmark

Benchmark the performance of one or more QIP components. If you compare multiple components then it’ll check each output is exactly the same. This is useful for porting from C to Zig, or asking your AI agent to implement optimizations and verifying that the result still behaves the same.

```bash
# Benchmark one component for two seconds
echo "World" | qipx bench -i - --benchtime=2s components/text/hello.wasm
# Benchmark: outputs match

# Benchmark two components against each other and verify identical output
echo "World" | qipx bench -i - --benchtime=2s components/text/hello.wasm components/text/hello-c.wasm
# Benchmark: outputs match

# Benchmark three components against each other and verify identical output
echo "World" | qipx bench -i - --benchtime=2s components/text/hello.wasm components/text/hello-c.wasm components/text/hello-zig.wasm
# Benchmark: outputs match

# Ask Node.js to collect garbage between component measurements
echo "World" | NODE_OPTIONS=--expose-gc qipx bench -i - --benchtime=2s components/text/hello.wasm
```

## TODO

- [ ] Add a `--double` flag for `qipx bench` that doubles the input and plots the performance. So we should see if rendering is `O(n)` where n is the size of the input or not. It could keep doubling the input. I imagine it would only work for text input and uncompressed ktx2 input, as those should be trivial to “double”.
- [ ] House keeping: drop `components` and match the qip.dev site paths:
  - [ ] `components/text/text-to-path-svg-dejavu-sans-mono.wasm` -> `text/text-to-path-svg-dejavu-sans-mono.wasm`
  - [ ] `components/image/png/png-to-ktx2-r8g8b8a8-srgb.zig` -> `image/png/png-to-ktx2-r8g8b8a8-srgb.zig`
  - [ ] `components/interactive/calendar-gregorian.wasm` -> `tui/calendar-gregorian.wasm`
  - [ ] `components/interactive/textedit.zig` -> `gui/textedit.zig`
- [ ] Make TUI like `https://allweeks.exe.xyz/2026`
- [ ] Decide whether to add a post-link pass that removes unused one-slot WebAssembly tables emitted by `zig cc`.
- [ ] Decide whether the component debugger should show fixed table entries alongside locals and globals.
- [ ] In debugger show instructions used by the current wasm: call_indirect, SIMD, etc.
- [ ] Allow compiling TUIs into native code via `components/application/wasm/qip-component-to-c.wasm`. So you get the benefit of a sandbox but you get the fast performance of native.
- [ ] Explore a consistent route hierarchy for interactive image tools, such as moving `/image-resize` to `/image/resize`. Consider all image tools together, preserve redirects for existing URLs, and decide how tool routes coexist with the `/image` component namespace.
- [ ] Add `--view-source` to `npx qip-router warc`, including recipe source and view-source records.
- [ ] Align `npx qip-router` CLI output with `./qip router`. Rendering and WARC output match byte-for-byte, and `list` has the same routes after whitespace normalization. Remaining differences: `list` uses tabs instead of Go's padded columns; `head` prints an HTTP-style block to stdout while Go logs headers to stderr; Node does not currently emit `ETag` for some static/raw `HEAD` responses that Go reports.
- [ ] Add `github:owner/repo/subdir` content roots to `qip-router`, pinned to one repository snapshot per load.
- [ ] Add AVIF encoding with Display P3 HDR with either PQ (Perceptual Quantizer) or HLG.
- [x] Allow ordered HTTPS host fallback in qipx: `qipx qip.dev run text/markdown/gfm-commonmark.0.31.2.wasm`
- [ ] Decide whether qipx redirects may target any configured HTTPS host, not only the source origin. Keep the two-redirect limit and reject unconfigured origins; define whether a failed redirected request resumes the original fallback sequence and may request the target host twice.
- [ ] Investigate if qip-component-to-c is affected by https://trustsig.eu/blog/wasm2c-tableflip-unchecked-calloc/
- [ ] Remove `@memcpy(ktx_buf[ktx.HEADER_SIZE..], output_buf[0..]);` — just render directly to output_buf instead of ktx_buf.
- [ ] For GUI components should we inline the KTX2 header write function into components?
- [ ] For GUI components should we allow uniforms to be optional?
- [x] Return the dynamic output pointer, size, and rejection state from `render`.
- [ ] Should uniforms return their previous value? This means we can bring a component back to its original state.
- [ ] Ensure we always `new TextDecoder("utf-8", { fatal: true })`
- [ ] Add `/text` and `/image` pages with list of wasm modules. I think image should include any with input or output image.
- [x] Should we drop `/components` prefix from web path?
- [ ] Recipes page: interactive upload and text entry
- [x] Recipes page: copy recipe as source code (e.g. as JavaScript)
- [ ] Extend `content-recipe-to-browser-javascript` with per-stage uniforms: add an optional recipe CSV query column, apply `uniform_set_<key>` functions in sorted order before each render, parse `i32`, `i64`, `f32`, and `f64` values, reject duplicate keys, missing setters, and host-managed multi-parameter hooks, and support optional runtime overrides. Consider stable stage IDs before exposing overrides for multi-stage recipes.
- [ ] Recipes page: prune useless recipes
- [ ] Complete the common image conversion paths through `image/bmp`:
  - [x] Add `image/avif/avif-to-ktx2-r8g8b8a8-srgb.wasm` so AVIF can feed the canonical KTX2 image pipeline without a BMP intermediate.
  - [x] Add `image/bmp/bmp-b8g8r8a8-srgb-to-jpeg-lossy.wasm`, with an explicit quality uniform, so every format that decodes to BMP can produce JPEG.
  - [ ] Add `image/gif/gif-first-frame-to-bmp-b8g8r8a8-srgb.wasm`. Keep the first-frame policy in the name rather than implying that one BMP preserves an animation; add a separate GIF-frames-to-TAR component if all frames are needed. Or we could pass the frame as a uniform?
  - [ ] Add `image/x-icon/ico-to-bmp-b8g8r8a8-srgb.wasm`, with a deterministic default image choice and uniforms for selecting an embedded size when needed.
- [ ] Add `php-to-c` that converts a subset of PHP to a standalone C program. `text/x-php`
  - [ ] Support `SQLite3`: <https://www.php.net/manual/en/sqlite3.prepare.php>
- [ ] Add SQLite prepared statement example that takes SQLite database and a query, and produces a new optimized component that accepts query parameters as its input.
  - [ ] Curried component: input content type `application/vnd.sqlite3` output content type `application/sql -> application/x-www-form-urlencoded -> text/csv`
- [ ] Work through the [QIP component-to-C code-generation performance experiments](components/application/wasm/qip-component-to-c.zig), measuring each lowering change independently against the current translator and WABT `wasm2c`.
- [ ] How does our `qip-component-to-c.wasm` compare with RLBox? https://rlbox.dev/
- [ ] Add `warc-latency-estimator.wasm` that takes a WARC and then for each route calculates largest-contentful-paint and time-to-interaction and so forth.
- [ ] Investigate lighter router `HEAD` handling. Today `HEAD` follows the full `GET` path so WARC recipes can add derived routes, change headers, and set the final content length correctly. Many WARC recipes need the full site to understand links, but usually do not change status or headers other than `content-length`. Find a safe way for `HEAD` to avoid unnecessary body work when recipes can declare that behavior.
- [ ] Update to latest Zig
- [ ] Add TAR fixture archives for straight-line Content Compliance cases. Accept them through `qip comply --with fixtures.tar` and `qipx comply --with fixtures.tar`; support `must_render_exactly`, `must_trap`, explicit per-case uniforms in the case directory name, deterministic path sorting, duplicate-key rejection, and unknown-entry failures.
- [ ] Add Compliance sidecar recording for Wasm oracles. Start with `--record-failures failures.tar` for fuzz/debug repro cases, then consider `--record-cases cases.tar` for exporting all observed `must_render_exactly` and `must_trap` oracle calls into the TAR fixture archive format. Include a record limit so fuzzers cannot produce unbounded archives.
- [ ] Retire `qip comply --straight-line-oracles` after TAR fixture archives cover the audit use case. Procedural Wasm Compliance oracles can keep normal control flow; fixture archives provide the no-branching format.
- [ ] Design `<qip-step>`, `<qip-connect-search-params>`, `<qip-render>`, and pre-rendered `<qip-view>` together as the finite-rendering markup.
  - [x] Wrap `<source>` with `<qip-step>` in `<qip-play>` as multiple `<source>` elements are meant to be alternatives to each other. Extend the same markup to the finite elements when their design is implemented.
    - [ ] Add conditional sources with a step, such as to support bmp or png or jpeg upload with `<input type="file">`.
    - [ ] Add WARC-time validation that the steps are compatible with each other.
  - [ ] Add `<qip-connect-search-params>` for explicitly allowing URL search parameters into a render without exposing every parameter, like Rails strong parameters. Each direct `<input type="hidden" name="language" value="en">` child declares one permitted key and uses its initial value as the fallback. Rendering replaces current values from matching search parameters, and the successful controls combine with ordinary user inputs as one form-encoded input for the steps of an enclosing `<qip-view>` or `<qip-render>`.
  - [ ] Add support for nested `<qip-render component="/bytes/base64-encode.wasm">` that can be substituted at build time or serving time. This would allow something akin to React, Astro, or PHP rendering while keeping the executable components fixed by the page.
  - [ ] Add a signal for `<qip-view>` marking pre-rendered output as authoritative so activation can skip the initial render (perhaps a `rendered` attribute). It must be an explicit marker, never inferred from non-empty output, since empty output is a valid result.
- [ ] Retire the web-shaped `Form` component contract.
  - [ ] Add `submit(input_size)` export
    - [ ] Input is either `application/x-www-form-urlencoded` or `multipart/form-data`
    - [ ] Have demo with `FormData` that works in client and on server
    - [ ] Will be like an uncontrolled form in React, where every keypress does NOT need a re-render. Only do this on submit.
    - [ ] See how it could work with Time and Events, and HTML-in-canvas
  - [ ] In favor of a future cross-host `Prompt` contract: sequential prompts with recoverable failure, `submit(input_size, now_ms)` for state changes, and `render(0)` for the current semantic projection/output.
- [ ] Add Command Palette example, combining `<input>` and `<canvas>`
- [ ] Add CSV to chart SVG example
- [ ] Add TCP simulator example, showing segments and allowing you to test failure.
- [ ] Add more shader examples from https://github.com/paper-design/shaders/tree/main/packages/shaders/src/shaders:
  - [x] God rays
  - [ ] Metaballs, dithering, grain gradient, mesh gradient, heatmap, liquid metal, and halftone
  - See https://shaders.paper.design
- [ ] Add `application/edifact` example
- [ ] Add Wuffs example
  - See: https://github.com/google/wuffs/blob/main/doc/getting-started.md
  - See roadmap of examples: https://github.com/google/wuffs/blob/main/doc/roadmap.md
- [ ] Allow `qip comply` to be run against arbitrary shell command. This would internally call out to the underlying command by copying the input when the comply task calls `impl.render`.
- [ ] Add Email render example (do we use an existing layout system?)
  - See https://www.joshwcomeau.com/react/wonderful-emails-with-mjml-and-mdx/
  - See https://react.email/components and https://demo.react.email/preview/05-Studio/welcome
- [ ] Add MathML https://www.w3.org/TR/mathml-core/ `<math>` renderer
  - See https://github.com/KaTeX/KaTeX
  - See https://www.intmath.com/cg5/katex-mathjax-comparison.php?processor=MathJax3
  - See https://andrewlock.net/rendering-math-in-html-mathml-mathml-core-and-asciimath/
  - See https://developer.mozilla.org/en-US/docs/Web/MathML/Reference/Element/semantics
  - See https://asciimath.org/#syntax
  - Have `/math-to-html` demo like https://katex.org/#demo
- [ ] Increase recipe order prefix from `nn` to `nnn`.
- [ ] Add dev/CI QIP Vitals for pipelines: harness metrics that zoom in on time to first render bytes (read/fetch, compile, instantiate, first `render`), per-stage render time, full pipeline render time, interactive event-to-frame-bytes latency, frame-budget miss rate, output hash, wasm/compressed size, input/output byte sizes, memory pages/max memory, trap/timeout rate, and host/runtime/device metadata. Report p50/p95/p99 so timings stay measurable and comparable when output bytes still match.
- [ ] Add optional field telemetry for deployed QIP components: user-experience metrics such as component hash, host/runtime/device class, time to first QIP paint p75/p95/p99, render-to-paint delay p75/p95/p99, interactive event-to-painted-frame p75/p95/p99, sampled pipeline render p95/p99, frame-budget miss rate, trap/timeout rate, and slowest device classes so production performance can be compared without changing the component contract.
- [ ] Add TypeScript-to-JavaScript type stripper.
- [x] Document uniforms properly `qip image -i fixtures/SAAM-2015.54.2_1.jpg -o tmp/halftone.png components/rgba/color-halftone.wasm -u max_radius=2.0 components/rgba/brightness.wasm -u brightness=0.2`
- [ ] Add CDN example to allow this to run server-side: `qip image -i fixtures/SAAM-2015.54.2_1.jpg -o tmp/halftone.png components/rgba/color-halftone.wasm -u max_radius=2.0 components/rgba/brightness.wasm -u brightness=0.2`
- [ ] Add DOOM example.
  - See https://github.com/Daivuk/PureDOOM
- [ ] Add monochrome rendering `output_monochrome_bytes() -> i32`
- [x] Add application/wasm verifier for fixed memory, fixed-bound loop evidence, and no recursion. This is a conservative subset of https://en.wikipedia.org/wiki/The_Power_of_10:_Rules_for_Developing_Safety-Critical_Code: loops must compile to a visible counter, monotonic update, and exit bound.
- [ ] Add a `wasm-fuel-instrument` component that injects deterministic fuel metering as a wasm-to-wasm transform: a decrementing fuel global checked at each loop backedge and call, trapping at zero. Prior art: wasmtime fuel/epochs and Parity's wasm-metering gas injection. Fuel is deterministic (same input, same fuel spend on every host), unlike wall-clock `--timeout-ms`, and browsers cannot preempt a wasm call on the main thread. This gives modules whose loops the static checker cannot prove (for example `commonmark`) a metered tier, while statically proven modules keep the strict tier.
- [ ] Add tracing by modifying modules:
  - [ ] Trace unreachable by adding calls to memory reads of input so we can check last read which will likely be source reason for the trap.
  - [ ] Trace any loops by adding calls to an imported function in each iteration. e.g. `trace_loop($func_n, $loop_n)`
  - [ ] Trace any internal calls by adding calls to an imported function. e.g. `trace_will_call($func_n, $call_n)`
  - [ ] Trace any branches by adding calls to an imported function. e.g. `trace_if($func_n, $if_n)` and `trace_block($func_n, $block_n)`
  - [x] Trace scalar Wasm32 memory loads/stores with before/after callbacks.
  - [ ] Extend memory tracing to SIMD, atomic, and bulk-memory operations.
- [ ] Extend `paint` example with `animate` that is like Flash or After Effects with a simple keyframe and tween editor of graphics. We could have a limited number of layers (8?) and text input.
- [x] Add spreadsheet example.
- [x] Add bar charts.
- [ ] Add scatter plot charts.
- [x] Add pixel editor.
- [x] Add Cover Flow example.
- [ ] Add Figma vector networks example.
- [x] Add localized example in multiple languages.
- [ ] Add a split interactive pipeline mode with two collaborative modules: a state/update module writes an internal scene buffer, and a renderer consumes it via `render(input_size)` with a simple `memcpy` handoff between module instances. This would enable presentation variants such as language or locale, dark or light mode, font size, DPI scaling, and accessibility-focused rendering.
- [ ] Have separate `pointermove` event handler so we can skip expensive `pointermove` listeners and rendering if not needed??
- [x] Separate update scheduling from presentation: `finish_update()` returns `next_wake_at_ms`, events report accepted or ignored, and the host decides whether to call `render(0)`. Specify pointer leave coordinates and button state consistently across hosts.
- [ ] Add digest pinning for remote modules (for example `https://...#sha256=<hex>`), and fail fast when fetched bytes do not match the pinned digest.
- [x] Update docs to encourage hard failure with traps instead of returning empty output which could lead to data loss.
- [ ] Convert soft-failure validators to trap on invalid input, then add invalid-then-valid same-instance recovery tests:
  - [ ] `components/text/css/css-class-validator.wasm`
  - [x] `components/text/html/html-id-validator.wasm`
  - [x] `components/text/html/html-input-name-validator.wasm`
  - [x] `components/text/html/html-tag-validator.wasm`
  - [ ] `components/text/tld-validator.wasm`
  - [x] `components/text/luhn.wasm`
- [x] Add `qip dry run ...pipeline.wasm` that validates pipeline compatibility and outputs memory usage (summing all input/output buffers).
- [ ] Add `qip serve` command that runs the server in `prod` mode by default, and includes a module upload endpoint.
- [ ] Add `random_ptr` and `random_size` to modules that the host can detect and fill in with random data. It can choose to seed with determinism or use a cryptographic source of randomness — it’s up to the host.
- [ ] Add `--postcondition` or `--outmust` flag to `qip run` that verifies the final output conforms to a particular module e.g. `--postcondition valid-xml-1.0.wasm`.
- [ ] Add first-stage content-type guards: either lightweight ingress sniffing (check initial bytes against expected type) or validator modules (for example `validate-html.wasm`) that accept untrusted input and re-emit it with asserted MIME type on success.
- [ ] Add `qip photocopy` command that observes an existing tool’s input/output behavior and generates a behaviorally similar QIP module implementation in wasm, then validates it with duel/fuzz tests and reports divergences.
- [ ] Finish **Compliance oracles** as a first-class component type alongside `Content`, `Interactive`, `Tile`, and `Form`. The host bridge streams one case at a time, supports procedurally generated oracles and mutation loops, and keeps oracle memory separate from implementation memory.
  - [ ] Case identity = bridge-call ordinal. Oracles are deterministic, so "case 987 of the CommonMark suite" is reproducible by re-running the oracle and skipping the first 986 interactions (host returns pass without executing the impl until the target ordinal). `qip comply --case 987` prints that case's name/input/expected without needing any failure ABI; `--continue` counts all divergences instead of stopping.
  - [ ] Corpus extraction for non-QIP implementations: run the oracle against a null impl (host records every declared case instead of executing anything) and export the ordered corpus as a tar archive (simple, streaming, ordered, arbitrary binary entries; the repo already speaks tar). Any external harness — a Go test dueling x/text, a Node script dueling `toLocaleLowerCase`, a CLI duel over stdin/stdout — consumes the tar. This makes the emit-a-corpus design a *host feature* of the bridge design rather than a separate module shape.
  - [x] Migrate all repository oracles, including Luhn, E.164, `preserve-*`, and `trap-*`, to the bridge.
  - [ ] Move the Compliance oracle meta-contract checks into `qip comply` base validation (the way static contract checks already run for render components): deterministic declarations across a double null-impl run, sequential u64 ordinals, must_render_into open/emit/finish discipline, and seed-varies-fuzz-only. Per-component harnesses must not each re-verify these; `test/lib/compliance-harness.mjs` is the interim JS reference implementation of both the bridge and the generic checks.
- [x] Permit accepted output to be an immutable slice of the input region.
- [ ] Revisit numeric outputs as SIMD-aware tensors instead of restoring the old `output_i32_cap` directly. Useful proof cases are batched CRC, histograms, offset arrays, masks, and matrices. Keep element type, logical shape, and physical layout separate; Mojo's scalar-as-one-lane-SIMD and explicit layout model is pertinent prior art.

![qip logo](qip-logo.svg)
