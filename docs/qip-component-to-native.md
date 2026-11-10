# Translating QIP Components To Native Source

QIP can translate a bounded QIP Content component into native source, so a
reviewed component compiles into an application without a WebAssembly
runtime. Two backends are supported:

- `qip-component-to-c.wasm` generates one C11 header.
- `qip-component-to-zig.wasm` generates one Zig module.

Swift applications use the C backend through Clang (see
[Swift](#swift)).

Both backends produce the same runtime model: the translated functions, a
module instance, a host-owned linear-memory workspace, explicit memory checks,
dirty-page tracking, recoverable traps, and a small wrapper for the QIP
`render` lifecycle. Neither is a general WebAssembly translator. Each accepts
a deliberately bounded profile and fails translation when the input uses an
unsupported instruction, so unsupported features have an unambiguous failure
mode and the generated runtime stays small enough to audit.

Build a translator and run it like any other Content component:

```sh
make -j application/wasm/qip-component-to-c.wasm
wasm-validate text/markdown/commonmark.0.31.2.wasm
npx qipdo qip.dev \
  -i text/markdown/commonmark.0.31.2.wasm \
  -o commonmark.h \
  application/wasm/qip-component-to-c.wasm
```

Replace `qip-component-to-c.wasm` with `qip-component-to-zig.wasm` and the
output name with `commonmark.zig` for Zig.

The translators enforce their feature profiles, but they are not complete
WebAssembly validators. Validate untrusted input with `wasm-validate` before
translation. Translation is an artifact-generation step: do not expose a
translator as a service that accepts arbitrary Wasm and compiles the result.

During translation, the C backend also rejects out-of-range local and global
indices, writes to immutable globals, operand-stack underflow, and unmatched
stack heights at control-flow boundaries. It computes each function's maximum
operand-stack height and uses that value to size the generated C array. It does
not yet check every operand type, so these checks do not replace a complete
validator.

## Translation Profile

Both backends accept:

- a QIP Content component with one defined wasm32 memory with a declared
  maximum; generated code uses the fixed initial size;
- Core WebAssembly 1.0 structured control flow, `br_table`, direct calls, and
  scalar integer and floating-point instructions;
- sign extension;
- scalar globals with constant initializers and active data segments;
- `memory.size`, `memory.copy`, and `memory.fill`;
- one fixed `funcref` table, active function-index element segments, and
  `call_indirect`.

Both reject imports, WASI, host callbacks, start functions, `memory.grow`,
shared memory, threads, atomics, multiple memories or tables, table mutation
and bulk operations, general reference instructions, `externref`, multi-value
functions and blocks, type-index block signatures, SIMD, and post-Core-2.0
features such as exceptions and tail calls.

The backends differ in a few places:

| Feature | C | Zig |
|---|---|---|
| Passive data, `memory.init`, `data.drop` | Supported | Rejected |
| Saturating float-to-integer conversions | Supported | Rejected |
| `f32`/`f64` `nearest`, `min`, `max` | Rejected | Supported |

Unsupported sections and instructions fail closed. Each translator's source
file starts with its complete supported and disabled feature list.

`call_indirect` introduces runtime target selection, but not runtime code
loading. Generated code checks the table index, rejects an uninitialized slot,
and checks the selected function's structural type before dispatch. Each
failure returns a distinct trap status. The Zig backend emits the table as a
constant and dispatches with a `switch` over structurally compatible,
already-generated functions.

This is a native-translation profile, not a revision of QIP's strict profile.
The strict profile proves an acyclic direct call graph by rejecting indirect
calls. Generated code instead bounds direct and indirect call nesting with a
runtime call-depth limit.

The generated source targets little-endian systems. QIP tests native
translation on x86-64 and AArch64; there is no byte-swapping path.

The public API covers the Content `render` lifecycle. Neither backend yet
publishes wrappers for optional `uniform_set_*` exports, so components that
depend on host-configured uniforms need that API added before native use.

## Workspace And Recipes

The host owns the linear memory and a dirty-page bitmap with one bit per
64 KiB Wasm page. Generated code never allocates or frees them. The memory must
initially be zero.

The caller writes input directly into the workspace at `INPUT_OFFSET` before
`init`. `render` performs no host-buffer copies; it returns the dynamic output
offset and length, which the wrapper has checked against linear memory and the
component's declared output capacity.

`init` is a workspace turnover operation. It preserves exactly the new
component's caller-written input, clears previously dirty bytes outside that
range, initializes globals, tables, and active data, and advances the workspace
generation. A previous component instance then returns a stale-instance status
if it is used accidentally.

Independently translated components can therefore share one workspace sized
for the largest recipe step. After step A renders, the host moves its output to
step B's input offset and initializes B with the same workspace. There is no
explicit reset and no external intermediate buffer. This is sequential
workspace reuse, not WebAssembly shared memory; generated components remain
single-threaded and have no imports or host callbacks.

## Memory And Traps

Wasm addresses remain `uint32_t`/`u32`. The generated memory helper widens the
dynamic address and static offset to 64 bits, then checks the complete range
before producing a native pointer. This catches address addition overflow and
accesses that cross the end of memory.

The host chooses how to obtain the zeroed buffer. A single `calloc` is portable
and normally receives lazy zero-filled pages on x86-64 and AArch64.
Applications can instead use `mmap`, `VirtualAlloc`, a persistent arena, or
another allocator whose lifetime fits the surrounding program.

Every generated write marks its page in the dirty bitmap. The next `init`
clears those pages except for the new input range, so turnover does not make
untouched lazy-zero pages resident.

Bulk-memory operations check both ranges before mutation:

- `memory.copy` uses `memmove` semantics because the ranges may overlap.
- `memory.fill` uses `memset`.
- `memory.init` (C only) checks the passive segment and memory ranges.
- `data.drop` (C only) records that the segment is unavailable to later
  nonempty `memory.init` operations.

An explicit trap, failed memory check, invalid numeric conversion, invalid
indirect call, or call-depth exhaustion returns a typed status from the public
`render` wrapper rather than terminating the host application. A trap does not
roll back component memory or globals; subsequent renders reuse the instance
just as repeated Wasm renders do.

## C

Every header hashes the complete input bytes with SHA-256 and uses the first
128 bits as its module identifier. The identifier prefixes public symbols,
private helpers, the include guard, and the instance type, so independently
translated modules can be compiled into one program without linker collisions.
The complete digest remains in a comment at the top of the header for
provenance.

Define the implementation in exactly one translation unit:

```c
#define QIP_WASM_IMPLEMENTATION
#include "generated_component.h"
```

Other translation units include the same header without defining
`QIP_WASM_IMPLEMENTATION`. Compile as C11 and link the platform math library:

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
`OUTPUT_CAPACITY`, and `MEMORY_SIZE` constants.

The C workspace allocation contains the Wasm-visible memory followed by a small
private trailer holding the generation and dirty bitmap.
`qip_render_workspace_allocation_size(memory_size)` returns the complete
allocation size:

```c
size_t allocation_size =
    qip_render_workspace_allocation_size(recipe_memory_size);
uint8_t *allocation = calloc(1, allocation_size);
qip_render_workspace workspace = {
    .memory = allocation,
    .memory_size = recipe_memory_size,
};
```

The trailer sits beyond the translated Wasm bounds, and touching it does not
make the intervening lazy-zero pages resident.

A two-step recipe sharing the workspace:

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

The caller checks `output_size` against `step_b_INPUT_CAPACITY` before the
`memmove`. Call `qip_render_workspace_clear(&workspace)` only when no next
component will take over and the host wants the workspace returned to zero. It
invalidates the current instance but does not free the allocation.

`qip_wasm_ID_dirty_page_count` reports the number of marked pages for the
current instance. Defining `QIP_WASM_DIRTY_TRACKING=0` before including the
implementation removes the bitmap writes for comparative benchmarks. In that
mode, turnover must clear the complete memory range outside the preserved input
and can make previously untouched pages resident.

Scalar loads and stores use fixed-size `memcpy`, which avoids unaligned pointer
dereferences and C aliasing violations. The public render wrapper establishes a
`setjmp` boundary for traps.

## Zig

Compile the generated module as part of a Zig program. Give it a module name so
the generic exported names remain scoped:

```sh
zig build-exe \
  --dep component \
  -Mroot=app.zig \
  -Mcomponent=trim.zig
```

Every generated file publishes these constants:

```zig
pub const MEMORY_SIZE: usize = ...;
pub const INPUT_OFFSET: u32 = ...;
pub const INPUT_CAPACITY: u32 = ...;
pub const OUTPUT_CAPACITY: u32 = ...;
```

The host allocates the memory and dirty bitmap separately:

```zig
const memory = try allocator.alloc(u8, component.MEMORY_SIZE);
const dirty = try allocator.alloc(
    u64,
    component.requiredDirtyWords(memory.len),
);
var workspace = try component.Workspace.init(memory, dirty);
```

`Workspace.init` zeroes the caller-provided allocation. Write the input, then
render:

```zig
@memcpy(
    workspace.memory[component.INPUT_OFFSET..][0..input.len],
    input,
);

var instance: component.Instance = undefined;
var output_offset: u32 = 0;
var output_size: u32 = 0;

if (component.init(&instance, &workspace, input.len) != .ok) return error.Init;
if (component.render(
    &instance,
    input.len,
    &output_offset,
    &output_size,
) != .ok) return error.Render;

const output = workspace.memory[output_offset..][0..output_size];
```

`init` and `clearWorkspace` accept the workspace structurally with `anytype`,
so an independently generated module can accept another module's `Workspace`
value. The instance stores only the raw slice, generation pointer, and dirty
bitmap. For a recipe, allocate for the largest step:

```zig
const memory_size = @max(step_a.MEMORY_SIZE, step_b.MEMORY_SIZE);
const memory = try allocator.alloc(u8, memory_size);
const dirty = try allocator.alloc(u64, step_a.requiredDirtyWords(memory_size));
var workspace = try step_a.Workspace.init(memory, dirty);

// after step A renders:
std.mem.copyForwards(
    u8,
    workspace.memory[step_b.INPUT_OFFSET..][0..output_size],
    workspace.memory[output_offset..][0..output_size],
);
_ = step_b.init(&b, &workspace, output_size);
```

Calling A again returns `stale_instance`.

The Zig backend preserves Wasm's control structure: `block` becomes a labeled
block, `loop` a labeled `while`, `br` and `br_if` labeled `break` or
`continue`, `br_table` a `switch`, and direct Wasm calls Zig calls. Operand
values remain in an explicit `Val` stack so branches can carry a block result.
Trapping helpers and generated functions return a small error union, which the
public `render` wrapper converts to a specific `Status`.

## Swift

Generate C with `qip-component-to-c.wasm`, expose the header to Swift through a
Clang module or the application's bridging header, and define
`QIP_WASM_IMPLEMENTATION` in one C translation unit. Keep the Swift facade
small: allocate or accept the workspace, call `init` and `render`, and convert
C status values to a Swift error type. Clang compiles and optimizes the
generated functions quickly, and Swift only sees the narrow component boundary.

The repository also contains an experimental `qip-component-to-swift.wasm`
that emits Swift source directly. Do not use it: the Swift compiler is too slow
on the generated code. An optimized build of CommonMark did not finish after
seven minutes, and even `-Onone` took about two minutes. Explicit types and
avoiding protocols did not help.

To run a component in Swift without translation, see
[Running QIP in Swift](/docs/running-in-swift).

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
translation profile. Generated source is also a poor interchange format when
the application already embeds a mature Wasm engine: it increases build size
and moves validation from runtime admission to the artifact-generation step.

Use the Zig backend when Zig is the application's build boundary, and the C
backend otherwise, including for Swift.

Generated source is intended for applications that need a fixed collection of
reviewed QIP components compiled into the native binary.

## Benchmarks

See [QIP Component-to-C Runtime Benchmarks](/docs/qip-component-to-c-benchmarks)
for measurements against QIP/wazero, Node/V8, WABT wasm2c, and direct native
Zig builds.
