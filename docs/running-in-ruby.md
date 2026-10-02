# Running QIP in Ruby

Ruby can run a QIP component with the [Wasmtime Ruby gem](https://github.com/bytecodealliance/wasmtime-rb) and a small wrapper around the QIP memory contract. The app loads the `.wasm` file from disk, writes UTF-8 input into its memory, calls `render`, and copies the UTF-8 output back into a Ruby `String`.

QIP uses *component* to mean a small unit that follows a QIP contract. A QIP component is currently a [WebAssembly Core module](https://webassembly.github.io/spec/core/), not a [WebAssembly Component Model](https://component-model.bytecodealliance.org/) component. Use `Wasmtime::Module` and `Wasmtime::Instance`. QIP components also have no WASI imports, so this example does not configure WASI or expose host capabilities.

## Add Wasmtime

The current Wasmtime gem requires Ruby 3.1 or newer. Add it to the application's `Gemfile`:

```ruby
source "https://rubygems.org"

gem "wasmtime", "~> 46.0"
```

Install the bundle:

```bash
bundle install
```

Wasmtime publishes precompiled gems for common macOS, Linux, and Windows targets. Add every production target to `Gemfile.lock` so Bundler resolves the native artifact before deployment:

```bash
bundle lock --add-platform arm64-darwin
bundle lock --add-platform x86_64-linux
```

Use the platforms the application actually deploys to. A platform without a precompiled gem needs a Rust toolchain to build the native extension. Once the example works in your app, keep the tested Wasmtime version and deployment platforms in `Gemfile.lock`.

Put the downloaded component next to the Ruby script:

```text
markdown-example/
├── Gemfile
├── Gemfile.lock
├── gfm-commonmark.0.31.2.wasm
└── markdown.rb
```

## Render Markdown

This example assumes a trusted GFM component that follows the QIP Content contract. Use an artifact you built, tested, or admitted through a controlled process. The function checks caller-controlled input capacity; it does not validate arbitrary Wasm.

Create `markdown.rb`. `markdown_to_html` returns HTML or raises an exception.

```ruby
# frozen_string_literal: true

require "wasmtime"

def markdown_to_html(markdown, instance)
  memory = instance.export("memory").to_memory
  source = markdown.encode(Encoding::UTF_8)
  raise ArgumentError, "Markdown input is not valid UTF-8" unless source.valid_encoding?

  capacity = instance.export("input_utf8_cap").to_func.call
  if source.bytesize > capacity
    raise ArgumentError,
      "Markdown input exceeds capacity: #{source.bytesize} > #{capacity}"
  end
  input_ptr = instance.export("input_ptr").to_func.call
  memory.write(input_ptr, source)

  packed = instance.export("render").to_func.call(source.bytesize) & 0xffff_ffff_ffff_ffff
  raise ArgumentError, "component rejected input" unless (packed >> 63).zero?
  output_size = packed & 0xffff_ffff
  output_ptr = packed >> 32
  memory.read_utf8(output_ptr, output_size)
end

wasm_path = File.expand_path("gfm-commonmark.0.31.2.wasm", __dir__)
engine = Wasmtime::Engine.new
wasm_module = Wasmtime::Module.from_file(engine, wasm_path)
store = Wasmtime::Store.new(engine)
instance = Wasmtime::Instance.new(store, wasm_module, [])

markdown = <<~MARKDOWN
  # Project status

  | Feature | Status |
  | --- | --- |
  | Ruby host | Ready |

  - [x] Load the component from disk
  - [x] Render **GFM**
MARKDOWN

puts markdown_to_html(markdown, instance)
```

Run it from the project directory:

```bash
bundle exec ruby markdown.rb
```

The output begins with the rendered HTML:

```html
<h1>Project status</h1>
<table>
<thead>
<tr>
<th>Feature</th>
<th>Status</th>
</tr>
<!-- ... -->
```

## How the boundary maps to Ruby

The loader is runtime-specific; the QIP calls are not:

1. `Wasmtime::Module.from_file` validates and compiles the WebAssembly Core module.
2. `Wasmtime::Instance.new` instantiates it with no imports.
3. Ruby encodes the Markdown as UTF-8 and checks `input_utf8_cap()`.
4. `Memory#write` copies those bytes to `input_ptr()`.
5. `render(input_size)` returns the rejection bit, output pointer, and size in
   one packed `i64` value.
6. `Memory#read_utf8` copies and validates the accepted output range.

The function relies on the trusted component's exports. `to_func` and `to_memory` convert them to callable functions and memory.

This wrapper trusts the known-valid GFM component and checks only the caller-controlled input size. A host accepting arbitrary Wasm has a different validation boundary; see [Known And Untrusted Components](/docs/content-component#known-and-untrusted-components).

## Traps, threads, and reuse

If `render` traps, Wasmtime raises a `Wasmtime::Trap`. Treat that render as
failed and do not read the output buffer; it may contain stale or partial bytes.
Discard that instance and instantiate the module again before another render.

The example renders once. For repeated renders, keep the store and instance and call `markdown_to_html` again. Each instance owns mutable memory. Give each thread, worker, or pool entry its own store and instance, or serialize access.

Wasmtime calls hold Ruby's Global VM Lock by default. The gem can release it with `to_func(gvl: false)`, but that mode requires a separate `Wasmtime::Store` for every calling thread. Use the default until profiling shows that long WebAssembly calls are blocking useful Ruby work; violating the store-per-thread requirement can cause undefined behavior.

Preloading an instance before a process server forks can also produce unclear ownership of native runtime state. Prefer creating stores and instances in each worker after the fork.

## Run untrusted Wasm through the QIP host

Core Wasm validation does not establish the QIP contract. Use the `qip` CLI
for a module whose exports and behavior you do not trust. The host checks the
component contract and returned output range and capacity. It rejects memory
growth by default.

Install the Go QIP CLI and put `$(go env GOPATH)/bin` on `PATH`:

```bash
go install github.com/royalicing/qip@latest
```

This separate example runs `./component.wasm`, reads stdin, and writes stdout.
A failed host call raises an error. It allows 64 MiB of Wasm linear memory and
one second of component execution:

```ruby
system(
  "qip", "run",
  "--max-memory", "67108864",
  "--timeout-ms", "1000",
  "--capacities-must-fit",
  "./component.wasm",
  exception: true
)
```

The host uses the module's declared content types; this example does not
assume the output is HTML. Contract checks do not prove that the module
performs the intended transform. The memory limit covers Wasm linear memory,
not the whole host process. See [Hard limits](/docs/hard-limits) for the checks
and their limits. Hosting untrusted Wasm in process requires these validation
and resource controls before using the direct call flow.

The execution timeout does not limit compilation or subprocess startup.

## When to use something else

Keep ordinary Ruby code in charge of database access, HTTP calls, authentication, logging, and application workflow. QIP fits the deterministic Markdown-to-HTML step and gives that code no access to the rest of the application.

Use a normal Ruby gem when the transform intentionally needs Ruby objects, callbacks, or framework services throughout its execution. Use the `qip` CLI as a subprocess when adding a native extension to the application's bundle or deployment image is a worse tradeoff than process startup and IPC.
