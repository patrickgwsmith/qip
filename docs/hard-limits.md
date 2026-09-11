# Hard Limits

QIP runs a component through a byte interface. The host writes input to Wasm
linear memory, calls a known export, and reads output. A normal component does
not receive a file system, network, clock, DOM, cookies, environment variables,
GPU access, or application secrets. The host must pass needed data as input, a
uniform, or an event.

This boundary does not set a resource limit by itself. A component with no
network access can still use too much memory or run for too long. QIP uses
separate controls for host access, memory, and execution time.

| Control | Limit | Normal QIP rule |
| --- | --- | --- |
| Host access | Data and services a component can use | No WASI. The host provides only imports required by the selected contract. |
| Linear memory | Declared Wasm memory size and growth | Reject `memory.grow` by default. An optional byte cap checks declared memory limits. |
| Execution time | Time for one executed CLI stage | `--timeout-ms` stops a stage that exceeds its time limit. |

ABI capacity checks stop host copies outside the advertised input and output
buffers. They do not give a module a total memory budget or prove that its
Wasm code uses the buffers correctly.

## What Each Command Checks

The CLI does not enable the strict Wasm profile or loop proof by default.
Those checks are QIP components that process Wasm bytes. Normal components can
use valid Wasm features that the strict tier rejects.

| Check | `run`, `dry run`, `bench`, and `image` | `comply` |
| --- | --- | --- |
| Component contract and pipeline compatibility | Yes | Base Content ABI and static QIP getter checks |
| Reject `memory.grow` | Yes, unless `--allow-memory-grow` is set | No |
| Check declared memory against `--max-memory` | Yes, when set | Yes, when set |
| Reject indirect calls | No | No |
| Strict Wasm profile | Only with `wasm-strict-profile.wasm` in the pipeline | No |
| Prove loop bounds | Only with `wasm-bounded-loops.wasm` in the pipeline | No |
| Prove render output size | Only with `wasm-bounded-output.wasm` in the pipeline | No |
| Require straight-line Compliance oracles | No | Only with `--straight-line-oracles` |

`qip dry run` prepares and validates a pipeline, but it does not read input or
call `render`. A checker in that pipeline is checked as a component. Dry run
does not inspect the Wasm file that the checker would process at run time.

`qip comply` always checks the base Content ABI. It also checks static QIP
getter functions when those exports exist. Its `--max-memory` option checks
only the implementation memory declaration. It does not reject `memory.grow`,
run the strict profile, or prove loop bounds for the implementation.

`qip score` is deprecated. It reports heuristic metrics that do not form a
policy decision. Use the Wasm checker components below. They accept Wasm bytes
as input, pass the bytes through on success, and reject them when their rule
fails. Use `wasm-counts.wasm` when you need factual CSV metrics rather than a
pass/fail check.

## Run With A Memory And Time Policy

Use these flags on commands that execute components:

```bash
qip run --timeout-ms 1000 --max-memory 67108864 text/trim.wasm
qip bench -i input.txt --timeout-ms 1000 --max-memory 67108864 text/trim.wasm
qip image -i in.png -o out.png --timeout-ms 1000 --max-memory 8388608 components/rgba/invert.wasm
```

- `--max-memory <bytes>` rejects a module when a declared memory minimum or
  maximum is larger than the cap. It also rejects a declared memory with no
  maximum.
- `memory.grow` is rejected by default. Equal initial and maximum memory sizes
  do not change this rule. Allocator code can contain `memory.grow` even when
  every call to it will fail.
- `--allow-memory-grow` permits `memory.grow` and requires
  `--max-memory <bytes>`.
- `--timeout-ms <ms>` limits one executed CLI stage. It limits execution time,
  not allocation.

The declared-memory cap is not a cap for the complete pipeline. QIP checks each
component separately. `qip dry run` reports the sum of ABI buffer capacities,
not resident Wasm memory.

Browser elements use the equivalent attributes:

```html
<qip-edit max-memory="67108864">
  <source src="/text/markdown/commonmark.0.31.2.wasm" type="application/wasm" />
</qip-edit>
```

Allow memory growth only with a cap:

```html
<qip-edit allow-memory-grow max-memory="16777216">
  <source src="/example.wasm" type="application/wasm" />
</qip-edit>
```

## The Strict Wasm Tier

The strict tier is an optional artifact policy for a host that needs a small,
statically inspectable Wasm subset. It is not the normal CLI module policy.

Run both strict-tier stages on a Wasm file:

```bash
qip run -i component.wasm -- \
  application/wasm/wasm-strict-profile.wasm \
  application/wasm/wasm-bounded-loops.wasm
```

For untrusted Wasm bytes, validate the core module first:

```bash
qip run -i component.wasm -- \
  application/wasm/wasm-validate-core-2.0.wasm \
  application/wasm/wasm-strict-profile.wasm \
  application/wasm/wasm-bounded-loops.wasm
```

`wasm-validate-core-2.0.wasm` validates the complete Core 2.0 language. This
includes SIMD, multi-value functions, reference types, and bulk memory. Use
`wasm-validate-core-1.0.wasm` only when a pipeline must reject every feature
added after Core 1.0. The profile checker assumes valid core Wasm. It fails
closed when it cannot decode an instruction body, but it does not replace full
core Wasm validation.

### `wasm-strict-profile`

`wasm-strict-profile.wasm` requires all of these properties:

- wasm32 and no more than one linear memory;
- no imports;
- a declared memory maximum and no `memory.grow`;
- no shared memory or atomic instructions;
- SIMD instructions are allowed;
- no start function;
- no indirect or reference calls, including `call_indirect`,
  `return_call_indirect`, and `call_ref`;
- an acyclic direct call graph, so no recursion;
- static input-pointer and input/output-capacity getters; and
- no active data segment that overlaps the declared input buffer.

If the module exports content-type metadata, the checker must read it from the
initial memory image without instantiating the module.

Indirect calls are not rejected by the normal CLI policy. C libraries and
translated components can use function tables and indirect calls. Rejecting
them for every `qip run` would reject valid existing components. The strict
profile rejects them because it must collect the complete call graph before it
can reject recursion.

### Fixed-Bound Loops

`wasm-bounded-loops.wasm` is a separate component. It proves a fixed bound for
every Wasm loop that has a backedge. Keeping it separate lets a host use the
structural profile with a runtime time limit or another execution meter.

The checker examines the final Wasm binary, not source code. It needs one local
counter with only recognized monotonic updates in the loop and an exit test in
the matching direction. Recognized updates include adding or subtracting a
constant, division or a shift toward zero, and a recognized temporary-local
form. It also accepts the common parser step `i += 1 + len` when `len` is a
known non-negative narrow value.

The exit can use a signed or unsigned 32-bit or 64-bit comparison with a
constant, local, global, or computed value. A countdown test with `i32.eqz` is
also valid. The exit can branch out of the loop, return from the function, or
pass through blocks whose paths all leave the loop or function.

Any other write to the candidate counter makes the proof fail. For example,
`i = next_pos` can move the counter away from its limit. A `loop { br 0 }` has
no counter or exit, so the checker rejects it. A correct loop can still fail
this conservative proof. In that case, simplify the loop, add a step budget,
or use a runtime time limit. See [Provable Loops](provable-loops.md).

<h3 id="bounded-output-proofs">Bounded Output Proofs</h3>

`wasm-bounded-output.wasm` checks the successful result of a Content
component's `render(i32) -> i64`. It proves that the returned output size is
not larger than the static `output_utf8_cap()` or `output_bytes_cap()` value.

```bash
qip run -i component.wasm -- \
  application/wasm/wasm-bounded-output.wasm
```

The checker accepts a constant result within the capacity. For a dynamic
result, it accepts a final Wasm epilogue that compares the output-size local
with the exact capacity and traps when the size is too large:

```wat
local.get $output_size
i32.const OUTPUT_CAP
i32.gt_u
if
  unreachable
end
;; Return the unchanged output size in the low 32 bits of the i64 result.
```

The capacity can be an immutable constant global used by the capacity export.
The checker also accepts Zig's equivalent final-block form. Every successful
exit must use the recognized final return. An earlier `return` or a branch to
the function label makes the proof fail.

This checker proves only the returned byte count. It does not prove that the
component wrote useful bytes, wrote inside its output buffer, or returned a
valid output pointer. Normal QIP contract checks and component tests cover
those conditions. A module without this proof can still be correct.

## Cost Of The Strict Profile Check

For a valid module, let `B` be the module size in bytes, `I` the number of
decoded instructions, `V` the number of defined functions, and `E` the number
of direct calls between defined functions.

| Rule | Time | Extra memory |
| --- | --- | --- |
| Check imports, memory shape, and start function | `O(B)` overall | `O(1)` |
| Reject `memory.grow`, atomic instructions, and indirect calls | `O(I)` | `O(1)` |
| Find direct-call cycles | `O(V + E)` | `O(V + E)` |
| Read static content-type metadata and active data | `O(B)` | `O(S)` for active data segments |

The checker reads the module bytes once and records direct call edges. It then
walks that graph to find cycles. Since every edge comes from an instruction,
the complete structural check takes `O(B)` time. The graph needs linear extra
memory because a function can call a function that appears later in the file.

## Build With A Memory Budget

Choose the budget before you select compiler flags. Include input, output,
scratch space, stack, static data, and allocator storage. Then inspect the
final `.wasm` file. Source code and linker flags do not prove the final policy.

For small transforms, static buffers are usually the simplest choice. If an API
needs an allocator, place it over a fixed buffer. Treat an allocation failure
as an error or trap. Do not request more linear memory.

### Zig

Set an explicit initial and maximum memory size. This example sets both to
1 MiB:

```bash
zig build-exe component.zig \
  -target wasm32-freestanding \
  -O ReleaseSmall \
  -fno-entry \
  -rdynamic \
  --stack 65536 \
  --initial-memory=1048576 \
  --max-memory=1048576 \
  -femit-bin=component.wasm
```

The repository Makefile passes `--max-memory=$(ZIG_WASM_MAX_MEMORY)`. A module
can override that value. Use `std.heap.FixedBufferAllocator` when you need an
allocator interface with fixed memory.

### C and Clang

LLVM's Wasm linker can make maximum memory equal initial memory:

```bash
clang --target=wasm32 -nostdlib -Oz component.c \
  -Wl,--no-entry \
  -Wl,--no-growable-memory \
  -Wl,-z,stack-size=65536 \
  -Wl,--export=render \
  -Wl,--export=input_ptr \
  -Wl,--export=input_utf8_cap \
  -Wl,--export=output_utf8_cap \
  -Wl,--export-memory \
  -o component.wasm
```

The explicit equivalent is:

```text
-Wl,--initial-memory=1048576 -Wl,--max-memory=1048576
```

These linker flags also work with `zig cc`. Avoid `malloc` and libc features
that assume a larger runtime unless you provide and budget their memory. See
the [LLVM lld WebAssembly options](https://lld.llvm.org/WebAssembly.html).

### Rust

The `wasm32-unknown-unknown` target uses `dlmalloc` by default. A program that
uses that allocator can contain `memory.grow`. `--no-growable-memory` sets the
maximum memory size equal to the initial size. It does not remove the
instruction from allocator code.

For fixed-memory components, use `wasm32v1-none`, `no_std`, and static buffers
or an allocator on a fixed static region. Set the memory shape at link time and
inspect the final artifact:

```bash
RUSTFLAGS="-C link-arg=--initial-memory=1048576 -C link-arg=--max-memory=1048576" \
  cargo build --release --target wasm32v1-none

qip run target/wasm32v1-none/release/component.wasm
```

If an existing component needs a growable allocator, set a host cap:

```bash
qip run --allow-memory-grow --max-memory 16777216 component.wasm
```

See the Rust [wasm32-unknown-unknown target notes](https://doc.rust-lang.org/rustc/platform-support/wasm32-unknown-unknown.html)
and [wasm32v1-none target notes](https://doc.rust-lang.org/rustc/platform-support/wasm32v1-none.html).

### WebAssembly Text

For hand-written WAT, declare equal initial and maximum page counts and omit
`memory.grow`:

```wat
(memory (export "memory") 16 16)
```

A Wasm page is 64 KiB. This module declares 1 MiB.

## When Not To Use This Boundary

These restrictions make a component easier to inspect, test, benchmark, and
run in more than one host. They do not prove component correctness or make
untrusted output safe. The host must still validate output for its use.

QIP fits content transforms, validators, image filters, and small interactive
renderers with known input sizes. Do not use the fixed-memory or strict tier
for work that needs open-ended allocation, operating-system services, threads,
recursive or highly irregular control flow, or a large managed runtime. Keep
that work in the host, or use a less restrictive execution model with its own
resource controls.

For a production component:

1. Set a memory maximum at link time.
2. Run the final artifact with `--max-memory` in CI. Fixed memory is the CLI
   default.
3. Keep host capabilities in the host and pass required data as bytes.
4. Use `--timeout-ms` for untrusted or expensive executed stages.
5. Run `qip bench` after the contract and resource limits are stable.
