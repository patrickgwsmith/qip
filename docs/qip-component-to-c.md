# Translating QIP Components To C

`qip-component-to-c.wasm` translates a bounded QIP Content component into one C11
header. The generated header contains the translated functions, a module
instance type, a host-supplied linear-memory pointer, explicit memory checks,
dirty-page tracking, trap recovery, and a small wrapper for the QIP `render`
lifecycle.

The first implementation deliberately accepts less than general WebAssembly.
That keeps the generated runtime small enough to audit and gives unsupported
instructions an unambiguous failure mode.

Build the translator and run it like any other QIP Content component:

```sh
make -j components/application/wasm/qip-component-to-c.wasm
wasm-validate components/text/markdown/commonmark.0.31.2.wasm
./qip run \
  -i components/text/markdown/commonmark.0.31.2.wasm \
  -o commonmark.h \
  components/application/wasm/qip-component-to-c.wasm
```

The translator enforces its feature profile, but it is not a complete
WebAssembly validator. Validate untrusted input before translation. This is an
artifact-generation step: do not expose the translator as a service that
accepts arbitrary Wasm and compiles the resulting C.

During translation, the component rejects out-of-range local and global
indices, writes to immutable globals, operand-stack underflow, and unmatched
stack heights at control-flow boundaries. It also computes each function's
maximum operand-stack height and uses that value to size the generated C
array. It does not yet check every operand type, so these checks do not replace
a complete WebAssembly validator.

## Generated Header

Every header hashes the complete input bytes with SHA-256 and uses the first
128 bits as its module identifier. The identifier prefixes public symbols,
private helpers, the include guard, and the instance type. Independently
translated modules can therefore be compiled into one program without linker
collisions in normal use. The complete digest remains in a comment at the top
of the header for provenance.

Define the generated implementation in exactly one translation unit:

```c
#define QIP_WASM_IMPLEMENTATION
#include "generated_component.h"
```

Other translation units include the same header without defining
`QIP_WASM_IMPLEMENTATION`.

Compile the implementation as C11 and link the platform math library:

```sh
cc -std=c11 -O2 app.c -lm
```

The public interface has this shape, with the hash-specific prefix substituted
for `qip_wasm_ID`:

```c
typedef struct qip_wasm_ID_instance qip_wasm_ID_instance;

typedef struct qip_render_workspace {
    uint8_t *memory;
    size_t memory_size;
} qip_render_workspace;

qip_wasm_ID_status qip_wasm_ID_init(
    qip_wasm_ID_instance *,
    qip_render_workspace *,
    uint32_t input_size);

uint32_t qip_wasm_ID_dirty_page_count(
    const qip_wasm_ID_instance *);

qip_wasm_ID_status qip_wasm_ID_render(
    qip_wasm_ID_instance *,
    uint32_t input_size,
    uint32_t *output_offset,
    uint32_t *output_size);
```

Each header publishes hash-prefixed `INPUT_OFFSET`, `INPUT_CAPACITY`,
`OUTPUT_CAPACITY`, and `MEMORY_SIZE` constants. The caller writes input directly
into the workspace before `init`. `render` performs no host-buffer copies; it
returns the dynamic output offset and length.

A workspace allocation contains the Wasm-visible memory followed by a small
private trailer holding a generation and one dirty bit per 64 KiB Wasm page.
`qip_render_workspace_allocation_size(memory_size)` returns the complete
allocation size. The public workspace remains a two-field host value:

```c
size_t allocation_size =
    qip_render_workspace_allocation_size(recipe_memory_size);
uint8_t *allocation = calloc(1, allocation_size);
qip_render_workspace workspace = {
    .memory = allocation,
    .memory_size = recipe_memory_size,
};
```

The allocation must initially be zero. Generated code never allocates or frees
it. The trailer sits beyond the translated Wasm bounds, and touching it does
not make the intervening lazy-zero linear-memory pages resident.

`init` is a workspace turnover operation. It preserves exactly the new
component's caller-written input, clears previously dirty bytes outside that
range, initializes globals, tables, and active data, and advances the workspace
generation. A previous component instance then returns `STALE_INSTANCE` if it
is used accidentally.

Recipe steps therefore need no explicit reset and no external intermediate
buffer:

```c
memcpy(
    workspace.memory + step_a_INPUT_OFFSET,
    input,
    input_size);
step_a_init(&a, &workspace, input_size);
step_a_render(&a, input_size, &output_offset, &output_size);

memmove(
    workspace.memory + step_b_INPUT_OFFSET,
    workspace.memory + output_offset,
    output_size);
step_b_init(&b, &workspace, output_size);
step_b_render(&b, output_size, &output_offset, &output_size);
```

`step_b_init` clears the abandoned source bytes while preserving the relocated
input. The caller checks `output_size` against `step_b_INPUT_CAPACITY` before
the `memmove`.

Call `qip_render_workspace_clear(&workspace)` only when no next component will
take over and the host wants the workspace returned to zero. It invalidates the
current instance but does not free the allocation.

The current public API covers the Content `render` lifecycle. It does not yet
publish wrappers for optional `uniform_set_*` exports, so components that
depend on host-configured uniforms need that API added before native use.

## Translation Profile

The native translation profile accepts:

- a QIP Content component with one defined wasm32 memory;
- no imports, start function, shared memory, or `memory.grow`;
- scalar Core instructions used by the covered repository components;
- structured control flow and direct calls;
- active and passive data segments;
- `memory.size`, `memory.copy`, `memory.fill`, `memory.init`, and `data.drop`;
- one fixed `funcref` table, active function-index element segments, and
  `call_indirect`;
- no SIMD, exceptions, tail calls, or table mutation instructions.

`call_indirect` checks the table index, rejects an uninitialized slot, and
checks the selected function's structural type before dispatch. Each failure
returns a distinct trap status. `return_call` and `return_call_indirect` remain
unsupported.

This is a native-translation profile, not a revision of QIP's strict profile.
The strict profile proves an acyclic direct call graph by rejecting indirect
calls. The native profile instead applies a runtime call-depth limit once
`call_indirect` is enabled.

## Memory And Traps

Wasm addresses remain `uint32_t`. Linear memory is a fixed-size, host-owned
buffer; the native profile does not support `memory.grow`. The
generated memory helper widens the dynamic address and static offset to
`uint64_t`, then checks the complete range before producing a native pointer.
This catches address addition overflow and accesses that cross the end of
memory.

The host chooses how to obtain the initially zeroed buffer. A single `calloc`
is portable C11 and normally receives lazy zero-filled pages on the target
x86-64 and AArch64 systems. Applications can instead use `mmap`,
`VirtualAlloc`, a persistent application arena, or another allocator whose
lifetime fits the surrounding program.

Every generated write marks its 64 KiB Wasm page in the workspace trailer.
`dirty_page_count` reports the number of marked pages for the workspace's
current instance. The next `init` clears those pages except for the new input
range. `qip_render_workspace_clear` clears every marked page.

Dirty tracking is enabled by default. Defining `QIP_WASM_DIRTY_TRACKING=0`
before including the implementation removes the bitmap writes for comparative
benchmarks. In that mode, workspace turnover must clear the complete memory
range outside the preserved input and can make previously untouched lazy-zero
pages resident.

Scalar loads and stores use fixed-size `memcpy`. The generated code targets
little-endian x86-64 and AArch64, so no byte swap is required. `memcpy` avoids
unaligned pointer dereferences and C aliasing violations.

Bulk-memory operations check both ranges before mutation:

- `memory.copy` uses `memmove` because the ranges may overlap.
- `memory.fill` uses `memset`.
- `memory.init` checks the passive segment and memory ranges.
- `data.drop` records that the segment is unavailable to later nonempty
  `memory.init` operations.

The public render wrapper establishes a `setjmp` boundary. An explicit trap,
failed memory check, invalid numeric conversion, invalid indirect call, or
call-depth exhaustion returns a typed status rather than terminating the host
application. A trap does not roll back component memory or globals; subsequent
renders reuse the instance just as repeated Wasm renders do.

## Comparison With RLBox

[RLBox](https://rlbox.dev/) and QIP's C translation both use WebAssembly's
linear-memory and control-flow model to isolate native code inside a process.
They apply that mechanism to different integration problems. RLBox adapts
general C library APIs to C++ applications. QIP translates components that
already expose one narrow Content contract: bytes enter at a bounded offset,
`render` runs without imports or callbacks, and bounded bytes leave at a
validated offset.

The RLBox Wasm backend has three distinct layers:

1. WebAssembly and wasm2c-generated checks confine the library's memory
   accesses and indirect calls.
2. The
   [RLBox wasm2c backend](https://github.com/PLSysSec/rlbox_wasm2c_sandbox)
   creates the sandbox memory and table, converts 32-bit sandbox pointers,
   marshals ABI values, and mediates allocation and callbacks.
3. The RLBox C++ API controls how application code calls the library and uses
   values returned from it.

The tutorial's `CMakeLists.txt` assembles that build: it compiles the library
to Wasm, runs wasm2c, compiles the generated C with its runtime, and links the
RLBox backend. CMake is not itself a runtime isolation mechanism, although its
flags and selected WASI imports determine what code and external capabilities
enter the sandbox. The
[RLBox Wasm sandbox tutorial](https://rlbox.dev/chapters/tutorial/wasm-sandbox.html)
shows the complete pipeline.

### Tainted Host Values

RLBox wraps values originating in a sandbox as `tainted<T>`. For a fundamental
value such as an integer, this is primarily a C++ type-system boundary:
ordinary host operations that would use the value unsafely do not compile.
Permitted computations propagate the taint. The application must eventually
call an untainting API such as `copy_and_verify`, supplying a verifier, before
it receives an ordinary host value.

The wrapper cannot decide whether the verifier expresses the application's
correct security policy. A developer can write an incomplete verifier or use
an explicitly named escape hatch. Its safety contribution is to prevent
unacknowledged use, keep untrusted state visible through supported
computations, and make each trust decision a reviewable code location. See
RLBox's
[function-call tutorial](https://rlbox.dev/chapters/tutorial/noop-sandbox/func.html)
and
[untainting APIs](https://rlbox.dev/chapters/advanced/untainting-apis.html).

Pointers involve more than the wrapper alone. The backend converts sandbox
offsets to native addresses and checks that a requested range belongs to the
sandbox. Copy-and-verify APIs can clone data into host-owned memory before
validation, preventing the sandbox from changing that copy concurrently.
APIs that deliberately expose a raw pointer perform boundary checks but leave
the referenced bytes mutable by the sandbox.

QIP's generated `render` wrapper instead checks that the returned offset and
length stay within linear memory and the component's declared output capacity.
It then returns ordinary `uint32_t` values. The output bytes remain untrusted
application data, but the C API does not use a taint type to force the host to
acknowledge that fact. Passing those bytes to another translated component
keeps their processing inside a bounded memory model; consuming them in the
host still requires validation appropriate to that use.

### Scope And Trade-Offs

| Concern | QIP generated C | RLBox with wasm2c |
|---|---|---|
| Library interface | Fixed Content byte transform | General C library functions and types |
| Linear-memory isolation | Explicit checks generated into C | wasm2c checks or guarded memory |
| Returned values | Bounds-checked offsets and lengths become ordinary C values | Sandbox values remain `tainted<T>` until explicitly unwrapped |
| Pointers | Wasm offsets are mostly hidden behind the workspace and Content ABI | Generic pointer conversion, ownership, and range checks |
| Host callbacks | Rejected by the translation profile | Explicitly registered and mediated |
| External access | Imports are rejected | Selected imports, commonly including WASI facilities, may be provided |
| Allocation | One fixed host-owned workspace, reusable between components | Sandbox heap allocation through a general library boundary |
| Composition | Sequential components can reuse one allocation | Libraries normally retain separate sandbox instances |
| Host integration | C11 header and application-defined validation | C++ framework with compile-time taint propagation |

QIP's restrictions remove much of the boundary surface that RLBox must
mediate: there are no arbitrary library pointers, structs, callbacks,
allocators, or system calls in the translated interface. That smaller surface
also gives up APIs that need those features. RLBox supports richer existing
libraries and makes host trust decisions explicit, at the cost of a more
involved C++ integration and per-library API adaptation.

The shared QIP workspace introduces a separate trade-off. Reuse lowers the
combined memory requirement of sequential recipes, but separation between
successive components depends on correct dirty tracking and turnover. Separate
RLBox sandbox allocations do not normally share that lifecycle. Conversely,
they cannot reclaim the largest component's storage for another heterogeneous
step without additional host coordination.

Both approaches include their translators, generated checks, runtimes, native
compiler, and host boundary code in the trusted computing base. RLBox and its
wasm2c integration have substantially more deployment history. QIP's native
profile is newer, but rejects imports, threads, memory growth, and most optional
WebAssembly features rather than implementing a general library environment.

## When Not To Use It

Use a normal WebAssembly runtime when the input needs WASI, imports, threads,
memory growth, runtime compilation, memory64, or proposals outside the
translation profile. Generated C is also a poor interchange format when the
application already embeds a mature Wasm engine: it increases build size and
moves validation from runtime admission to the artifact-generation step.

The generated code is intended for applications that need a fixed collection
of reviewed QIP components compiled into the native binary.

See [QIP Component-to-C Runtime Benchmarks](/docs/qip-component-to-c-benchmarks) for measurements
against QIP/wazero, Node/V8, WABT wasm2c, and direct native Zig builds.
