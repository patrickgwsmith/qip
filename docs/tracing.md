# Tracing

Tracing is QIP's debug visibility path: keep normal components small and deterministic, then add instrumentation only when the host needs more context.

The default QIP component contract does not include error strings, diagnostic formats, or host callbacks. That is deliberate. Error text is hard to make stable, hard to parse, and tied to a human language. Trap tracing takes a narrower path: the original component still runs under the normal contract, and only after a failure does `qip run` optionally transform the module and retry it with trace imports.

## Run It

Build the trace component and the CLI:

```sh
make -j qip application/wasm/wasm-trace-instrument.wasm
```

Then run a component with a debug retry instrumenter:

```sh
qip run --trace-with application/wasm/wasm-trace-instrument.wasm ./component.wasm
```

If the original component traps, QIP retries an instrumented copy and appends a short memory trace to the failure:

```text
trace retry with application/wasm/wasm-trace-instrument.wasm:
instrumented retry trapped: wasm error: out of bounds memory access
  before_load func=0 op=0 mem=0 addr=0x00010000 width=4 bytes=<out-of-bounds>
```

For a store, QIP records memory before and after the write:

```text
  before_store func=0 op=0 mem=0 addr=0x00000008 width=4 bytes=41424344
  after_store func=0 op=0 mem=0 addr=0x00000008 width=4 bytes=44332211
```

## Why This Shape

We prefer retry instrumentation because it keeps production execution lean. Most runs should pay nothing for diagnostics. The extra imports, local variables, and callback overhead exist only in the transformed module used after a failure.

This also keeps tracing portable. The transformer is itself a QIP Content component:

- Input: `application/wasm`
- Output: `application/wasm`
- Path: `application/wasm/wasm-trace-instrument.wasm`

Because the transformer is a component, any QIP host that can run Content components can produce the same instrumented module. The CLI does not need to grow a full Wasm rewriting engine, and browser or SDK hosts can reuse the same diagnostic component.

## Trace Import ABI

The instrumented module imports three functions from `qip_trace`:

```wat
(import "qip_trace" "before_load" (func (param i32 i32 i32 i32 i32)))
(import "qip_trace" "before_store" (func (param i32 i32 i32 i32 i32)))
(import "qip_trace" "after_store" (func (param i32 i32 i32 i32 i32)))
```

Each callback receives:

- `func_id`: the original function index before instrumentation.
- `op_id`: the zero-based memory operation number within that function.
- `memory_index`: currently always `0`.
- `effective_addr`: the address after adding the instruction offset.
- `width`: the byte width of the load or store.

The callback does not receive the loaded or stored value. Instead, the host reads memory directly at `effective_addr`. That avoids a large polymorphic callback surface for `i32`, `i64`, `f32`, `f64`, and narrower load/store forms. It also lets an out-of-bounds load report the address that would trap before the load executes.

## What Gets Traced

The first version traces normal Wasm32 memory load and store opcodes:

- Before every load, call `qip_trace.before_load`.
- Before every store, call `qip_trace.before_store`.
- After every successful store, call `qip_trace.after_store`.

`before_load` is enough for loads because a trapping load never produces a value. Stores are different: seeing both sides of the mutation is often the useful clue.

QIP keeps the last 256 events and prints the last 16 events when reporting a failed retry. That gives enough nearby context without flooding normal terminal output.

## Limits

Use tracing as a debugging aid, not as a shipped module format.

- The current transformer supports Wasm32 modules with at most one memory.
- Memory64, multi-memory, SIMD memory instructions, and atomic memory instructions are rejected for now.
- Bulk memory operations are not expanded into byte-level trace events.
- Function indices in the instrumented stack trace may shift because the transformed module imports trace callbacks.
- Trace output is diagnostic text. The stable part to build on is the import ABI of the instrumented module, not the exact wording of CLI messages.

## Tests

The regression tests compile small WAT fixtures and exercise the real CLI path:

```sh
make -j test-node
make -j test-deno
```

To run just the trace tests after building the CLI and trace component:

```sh
make -j qip application/wasm/wasm-trace-instrument.wasm
node --test test/trace-with.mjs
```

Or with Deno:

```sh
deno test --allow-read --allow-write --allow-run --allow-sys --allow-env test/trace-with.mjs
```
