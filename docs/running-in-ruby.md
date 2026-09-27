# Running QIP In Ruby

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

Create `markdown.rb`:

```ruby
# frozen_string_literal: true

require "wasmtime"

class MarkdownRenderer
  def initialize(wasm_path)
    @engine = Wasmtime::Engine.new
    @module = Wasmtime::Module.from_file(@engine, wasm_path)
    @store = Wasmtime::Store.new(@engine)
    @instance = Wasmtime::Instance.new(@store, @module, [])

    @memory = export("memory").to_memory
    @input_ptr = export("input_ptr").to_func
    @input_cap = export("input_utf8_cap").to_func
    @render = export("render").to_func
  end

  def markdown_to_html(markdown)
    source = markdown.encode(Encoding::UTF_8)
    capacity = @input_cap.call

    if source.bytesize > capacity
      raise ArgumentError,
        "Markdown input exceeds component capacity: " \
        "#{source.bytesize} > #{capacity}"
    end

    @memory.write(@input_ptr.call, source)

    packed = @render.call(source.bytesize) & 0xffff_ffff_ffff_ffff
    raise "rejected input" unless (packed >> 63).zero?
    output_size = packed & 0xffff_ffff
    output_ptr = (packed >> 32) & 0x7fff_ffff
    @memory.read_utf8(output_ptr, output_size)
  end

  private

  def export(name)
    @instance.export(name) ||
      raise("Component does not export #{name}")
  end
end

wasm_path = File.expand_path(
  "gfm-commonmark.0.31.2.wasm",
  __dir__
)
renderer = MarkdownRenderer.new(wasm_path)

markdown = <<~MARKDOWN
  # Project status

  | Feature | Status |
  | --- | --- |
  | Ruby host | Ready |

  - [x] Load the component from disk
  - [x] Render **GFM**
MARKDOWN

puts renderer.markdown_to_html(markdown)
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

## How The Boundary Maps To Ruby

The loader is runtime-specific; the QIP calls are not:

1. `Wasmtime::Module.from_file` validates and compiles the WebAssembly Core module.
2. `Wasmtime::Instance.new` instantiates it with no imports.
3. Ruby encodes the Markdown as UTF-8 and checks `input_utf8_cap()`.
4. `Memory#write` copies those bytes to `input_ptr()`.
5. `render(input_size)` returns the rejection bit, output pointer, and size in
   one packed `i64` value.
6. `Memory#read_utf8` copies and validates the accepted output range.

Resolving each export during initialization catches a missing export before the first render. Converting it with `to_func` or `to_memory` also rejects an export of the wrong kind.

This wrapper trusts the known-valid GFM component and checks only the caller-controlled input size. A host accepting arbitrary Wasm has a different validation boundary; see [Known And Untrusted Components](/docs/content-component#known-and-untrusted-components).

## Traps, Threads, And Reuse

If `render` traps, Wasmtime raises a `Wasmtime::Trap`. Treat that render as
failed and do not read the output buffer; it may contain stale or partial bytes.
Discard that instance and instantiate the module again before another render.

The class compiles and instantiates the component once, then reuses it. A `MarkdownRenderer` owns mutable component memory and is not safe to call concurrently. Give each thread, worker, or pool entry its own renderer instead of sharing one instance.

Wasmtime calls hold Ruby's Global VM Lock by default. The gem can release it with `to_func(gvl: false)`, but that mode requires a separate `Wasmtime::Store` for every calling thread. Use the default until profiling shows that long WebAssembly calls are blocking useful Ruby work; violating the store-per-thread requirement can cause undefined behavior.

Preloading a renderer before a process server forks can also produce unclear ownership of native runtime state. Prefer constructing renderers in each worker after the fork.

## When To Use Something Else

Keep ordinary Ruby code in charge of database access, HTTP calls, authentication, logging, and application workflow. QIP fits the deterministic Markdown-to-HTML step and gives that code no access to the rest of the application.

Use a normal Ruby gem when the transform intentionally needs Ruby objects, callbacks, or framework services throughout its execution. Use the `qip` CLI as a subprocess when adding a native extension to the application's bundle or deployment image is a worse tradeoff than process startup and IPC.
