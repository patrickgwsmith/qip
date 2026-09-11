# Render-Reachable WebAssembly Cyclomatic Complexity

`render-cyclomatic-complexity.wasm` reports the static branch complexity
of the local Wasm code that a module's exported `render` function can call. It
reads a WebAssembly module and emits one unsigned decimal integer, with no
trailing newline in the output file.

```sh
make -j qip application/wasm/render-cyclomatic-complexity.wasm

qip run -i text/e164.wasm \
  -o complexity.txt \
  -- application/wasm/render-cyclomatic-complexity.wasm

cat complexity.txt
```

```text
4
```

The caller decides what value is acceptable. For example, a policy that
requires complexity below 22 rejects an output of 22 or more.

## How It Calculates The Value

The reporter starts at the defined exported `render` function and follows each
direct local `call` and `return_call`. It visits each reachable function body
once, so splitting one function into helpers does not reduce the value.

The value starts at one. It then adds:

- one for each `if` instruction;
- one for each `br_if` instruction; and
- one fewer than the number of distinct branch destinations in each `br_table`.

`br`, `loop`, and direct calls do not add branch complexity themselves. A loop
contributes through the decision that exits or repeats it. Recursive calls are
safe to analyze: the reporter counts the reachable function body once rather
than expanding the cycle forever.

The result describes local Wasm instructions only. A direct call to an imported
function has no local body to inspect, so it contributes no branch sites.
The reporter traps on reachable `call_indirect`, `return_call_indirect`, or
`call_ref`; their possible local targets cannot be established from direct-call
edges alone. Use the strict profile when those instructions must be prohibited
for the complete module.

The input must contain a defined function export named `render`. Malformed Wasm
or a module without that export traps. Validate untrusted bytes with
[`wasm-validate-core-2.0.wasm`](/application/wasm/wasm-validate-core-2.0.wasm)
first.

## When Not To Use It

This number is a static control-flow budget. It does not measure executed
instructions, loop iteration counts, memory use, test coverage, or algorithmic
cost. Use [`wasm-counts.wasm`](/application/wasm/wasm-counts.wasm) for a broad
static inventory, [`wasm-bounded-loops.wasm`](/application/wasm/wasm-bounded-loops.wasm)
for recognized loop bounds, and runtime benchmarks for observed cost.
