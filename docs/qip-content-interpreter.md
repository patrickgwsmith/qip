# Running A Content Component In The QIP Interpreter

`qip-content-interpreter.wasm` accepts a QIP Content component and its input as
multipart form data. It executes that component in the same bounded Zig
interpreter used by qipdb, then returns the component's output bytes.

```sh
make -j qip application/wasm/qip-content-interpreter.wasm

qip run \
  -F component=@image/svg+xml/svg-recolor-current-color.wasm \
  -F 'input=<svg xmlns="http://www.w3.org/2000/svg"><path fill="currentColor" d="M0 0"/></svg>' \
  -F 'uniforms[color_rgba]=0x654ff0ff' \
  application/wasm/qip-content-interpreter.wasm
```

The request supports these multipart fields:

- `component` is required and contains the target Wasm module.
- `input` is optional and contains the target's exact Content input bytes.
- `uniforms[<key>]` is optional and may be repeated with different QIP uniform
  keys. Quote the assignment in shells that treat brackets as patterns.

Uniform values use the target setter's `i32`, `i64`, `f32`, or `f64` type.
The interpreter validates uniform names, rejects duplicate keys, sorts keys,
and calls each `uniform_set_<key>` export before `render`. Setter instructions
and render instructions share the outer component's instruction budget:

```sh
qip run \
  -F component=@image/svg+xml/svg-recolor-current-color.wasm \
  -F input=@qip-logo.svg \
  -F 'uniforms[color_rgba]=0x654ff0ff' \
  application/wasm/qip-content-interpreter.wasm \
  -u instruction_budget=2000000 \
  > recolored.svg
```

The component accepts target modules up to 1 MiB, target input up to 8 MiB,
and fixed target memory up to 192 MiB. The instruction budget defaults to one
million and clamps at ten million. A malformed request, unsupported Wasm
feature, trap, exhausted budget, invalid target Content contract, or target
rejection becomes an outer Content rejection.

The output has the generic `application/octet-stream` content type. A QIP
component's content-type metadata is static, so this wrapper cannot declare the
target's runtime-selected output type. Callers that know the target should
restore or validate its expected type at the application boundary.

The wrapper validates the target's buffer and UTF-8 contract. It does not match
the `input` form part against the target's declared content type. The multipart
request carries the target input bytes, but not a trusted target content-type
contract.

## When Not To Use It

Use `qip run` when you need the normal runtime, target-specific content-type
composition, or production speed. Use qipdb when you need instruction steps,
memory inspection, counters, or terminal interaction. This interpreter
component is useful for testing the interpreter itself, measuring interpreter
overhead, or placing bounded nested execution inside a QIP pipeline.
