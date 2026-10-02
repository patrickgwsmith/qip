# Running QIP in Python

Python can run a QIP component with the Wasmtime package and a small wrapper around the QIP memory contract. The app loads the `.wasm` file from disk, writes UTF-8 input into its memory, calls `render`, and copies the UTF-8 output back into Python.

QIP uses *component* to mean a small unit that follows a QIP contract. A QIP component is currently a [WebAssembly Core module](https://webassembly.github.io/spec/core/), not a [WebAssembly Component Model](https://component-model.bytecodealliance.org/) component. Use Wasmtime's `Module` and `Instance` APIs, not `wasmtime.component.Component`. QIP components also have no WASI imports, so this example does not configure WASI or expose host capabilities.

## Install Wasmtime

Create a virtual environment and install the [Wasmtime Python package](https://github.com/bytecodealliance/wasmtime-py):

```bash
python -m venv .venv
source .venv/bin/activate
python -m pip install wasmtime
```

Wasmtime publishes frequent major versions. Once the example works in your app, record the tested version in your lock file or dependency constraints.

Put the downloaded component next to the Python script:

```text
markdown-example/
├── gfm-commonmark.0.31.2.wasm
└── markdown.py
```

## Render Markdown

This example assumes a trusted GFM component that follows the QIP Content contract. Use an artifact you built, tested, or admitted through a controlled process. The function checks caller-controlled input capacity; it does not validate arbitrary Wasm.

Create `markdown.py`. `markdown_to_html` returns HTML or raises an exception.

```python
from pathlib import Path

from wasmtime import Instance, Module, Store


wasm_path = Path(__file__).with_name("gfm-commonmark.0.31.2.wasm")

store = Store()
module = Module.from_file(store.engine, wasm_path)
instance = Instance(store, module, [])


def markdown_to_html(markdown: str, store: Store, instance: Instance) -> str:
    exports = instance.exports(store)
    memory = exports["memory"]
    source = markdown.encode("utf-8")

    capacity = exports["input_utf8_cap"](store)
    if len(source) > capacity:
        raise ValueError(
            f"Markdown input exceeds component capacity: {len(source)} > {capacity}"
        )

    memory.write(store, source, exports["input_ptr"](store))

    packed = exports["render"](store, len(source)) & 0xFFFF_FFFF_FFFF_FFFF
    if packed >> 63:
        raise ValueError("rejected input")
    size = packed & 0xFFFF_FFFF
    start = (packed >> 32) & 0x7FFF_FFFF
    end = start + size
    result = memory.read(store, start, end)
    return bytes(result).decode("utf-8")


markdown = """# Project status

| Feature | Status |
| --- | --- |
| Python host | Ready |

- [x] Load the component from disk
- [x] Render **GFM**
"""

print(markdown_to_html(markdown, store, instance))
```

Run it with:

```bash
python markdown.py
```

The output is HTML:

```html
<h1>Project status</h1>
<table>
<thead>
<tr>
<th>Feature</th>
<th>Status</th>
</tr>
</thead>
<tbody>
<tr>
<td>Python host</td>
<td>Ready</td>
</tr>
</tbody>
</table>
<ul>
<li><input checked="" disabled="" type="checkbox"> Load the component from disk</li>
<li><input checked="" disabled="" type="checkbox"> Render <strong>GFM</strong></li>
</ul>
```

## How the boundary maps to Python

The loader is runtime-specific; the QIP calls are not:

1. `Module.from_file` compiles the WebAssembly Core module from local bytes.
2. `Instance(store, module, [])` instantiates it with no imports.
3. Python encodes the Markdown as UTF-8 and checks `input_utf8_cap()`.
4. `memory.write` copies those bytes to `input_ptr()`.
5. `render(input_size)` returns the rejection bit, output pointer, and size in
   one packed `i64` value.
6. Python copies the accepted range and decodes UTF-8.

This wrapper trusts the known-valid GFM component and checks only the
caller-controlled input size. A host accepting arbitrary Wasm has a different
validation boundary; see [Known And Untrusted
Components](/docs/content-component#known-and-untrusted-components).

## Traps and reuse

If `render` traps, Wasmtime raises an exception. Treat that render as failed and
do not read the output buffer; it may contain stale or partial bytes. Discard
that instance and instantiate the module again before another render.

The example compiles and instantiates the component once, then reuses it. That avoids repeated compilation, but the instance owns mutable memory. Do not let concurrent requests write to the same instance. Serialize access with a lock, or give each worker or concurrent request its own instance. A compiled module can be reused when creating those instances.

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
one second of component execution, with a five-second limit on the subprocess:

```python
import subprocess

subprocess.run(
    ["qip", "run", "--max-memory", "67108864", "--timeout-ms", "1000",
     "--capacities-must-fit", "./component.wasm"],
    check=True,
    timeout=5,
)
```

The host uses the module's declared content types; this example does not
assume the output is HTML. Contract checks do not prove that the module
performs the intended transform. The memory limit covers Wasm linear memory,
not the whole host process. See [Hard limits](/docs/hard-limits) for the checks
and their limits. Hosting untrusted Wasm in process requires these validation
and resource controls before using the direct call flow.

## When to use something else

Keep ordinary Python code in charge of database access, HTTP calls, authentication, logging, and application workflow. QIP fits the deterministic Markdown-to-HTML step. If the transform needs Python objects, callbacks, or ambient host services throughout its execution, a normal Python library will usually be simpler.
