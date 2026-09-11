# Proving Integer Divisions Do Not Trap

`wasm-nontrapping-divides.wasm` is a conservative static checker for
WebAssembly integer division and remainder instructions. It returns the input
module unchanged when every operation is proven non-trapping. Its `render`
result rejects the input when a proof is missing.

```sh
make -j qip application/wasm/wasm-nontrapping-divides.wasm

qip run \
  -i component.wasm \
  -- application/wasm/wasm-nontrapping-divides.wasm \
  > checked.wasm
```

The checker recognizes constants, straightforward dominating guards, and
unsigned value ranges:

- Unsigned division and all remainder instructions require a nonzero divisor.
- Signed division also rejects `MIN / -1` unless an adjacent constant dividend
  or guard rules out that overflow.
- A false `br_if` path after `eqz` or equality with `0`, `-1`, or `MIN`
  contributes a fact. Facts propagate through locals and structured forward
  branches, and are intersected when reachable paths join.
- Signed lower-bound guards and Zig's integer-absolute-value lowering establish
  positive ranges that survive unsigned extension.
- Exact and unsigned interval ranges propagate through non-wrapping addition,
  subtraction, multiplication, low-bit masks, unsigned shifts, and narrow
  loads. An operation that might wrap becomes unknown.
- Locals written within each loop are identified in a prepass. Their entry
  facts are discarded for that loop, so a first-iteration range cannot be
  reused unsafely on a later iteration.
- A dynamic divisor is rejected when the source program made it safe in a way
  this version does not yet recognize.
- A module without integer division or remainder passes trivially.

This is commonly called divide-by-zero analysis in static-analysis tools.
`nontrapping` is more precise for WebAssembly because signed integer division
has a second trapping case.

The checker is intentionally sound and incomplete. A successful result is a
useful guarantee; a rejection means only that the current checker could not
prove the guarantee. More expression forms and loop invariants can be added
without changing that meaning.

Use `wasm-counts.wasm` when you only need to inventory division and remainder
sites. Use this checker when an unproven site should fail a pipeline.
