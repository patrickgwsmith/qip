# Translating QIP Components To Zig

`qip-component-to-zig.wasm` translates a bounded QIP Content component into
native Zig source. The generated module contains checked linear-memory access,
structured component functions, recoverable traps, workspace turnover, dirty
page tracking, and the QIP `render` lifecycle.

This is a QIP Content backend, not a general WebAssembly-to-Zig translator. It
accepts a deliberately bounded profile and traps during translation when the
input uses an unsupported instruction.

Build and run the translator like any other Content component:

```sh
make -j application/wasm/qip-component-to-zig.wasm
wasm-validate text/trim.wasm
./qip run \
  -i text/trim.wasm \
  -o trim.zig \
  application/wasm/qip-component-to-zig.wasm
```

Compile the generated module as part of a Zig program. Give it a module name so
the generic exported names remain scoped:

```sh
zig build-exe \
  --dep component \
  -Mroot=app.zig \
  -Mcomponent=trim.zig
```

The translator enforces its feature profile but is not a complete WebAssembly
validator. Validate untrusted input before translation. Translation is an
artifact-generation step; do not expose it as a service that compiles arbitrary
Wasm.

## Generated API

Every generated file publishes these constants:

```zig
pub const MEMORY_SIZE: usize = ...;
pub const INPUT_OFFSET: u32 = ...;
pub const INPUT_CAPACITY: u32 = ...;
pub const OUTPUT_CAPACITY: u32 = ...;
```

The host owns the raw memory and dirty-page bitmap:

```zig
const memory = try allocator.alloc(u8, component.MEMORY_SIZE);
const dirty = try allocator.alloc(
    u64,
    component.requiredDirtyWords(memory.len),
);
var workspace = try component.Workspace.init(memory, dirty);
```

Write the input before `init`, then render without a host-buffer copy:

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

`Workspace.init` zeroes the caller-provided allocation. Generated code does not
allocate or free memory.

## Sharing One Workspace

`init` and `clearWorkspace` accept the workspace structurally with `anytype`.
An independently generated module can therefore accept another module's
`Workspace` value. The component instance stores only the raw slice, generation
pointer, and dirty bitmap; it does not retain the workspace's nominal Zig type.

Allocate for the largest recipe step:

```zig
const memory_size = @max(step_a.MEMORY_SIZE, step_b.MEMORY_SIZE);
const memory = try allocator.alloc(u8, memory_size);
const dirty = try allocator.alloc(u64, step_a.requiredDirtyWords(memory_size));
var workspace = try step_a.Workspace.init(memory, dirty);
```

After step A renders, move its output to step B's input offset and initialize B
with the same workspace:

```zig
std.mem.copyForwards(
    u8,
    workspace.memory[step_b.INPUT_OFFSET..][0..output_size],
    workspace.memory[output_offset..][0..output_size],
);
_ = step_b.init(&b, &workspace, output_size);
```

Turnover preserves B's caller-written input, clears dirty bytes outside that
range, applies B's initial data and globals, and advances the workspace
generation. Calling A again returns `stale_instance`.

This is sequential workspace reuse, not WebAssembly shared memory. Generated
components remain single-threaded and have no imports or host callbacks.

## Structured Control Flow And Traps

The Zig backend preserves Wasm's control structure:

- `block` becomes a labeled Zig block;
- `loop` becomes a labeled `while`;
- `br` and `br_if` become labeled `break` or `continue`;
- `br_table` becomes `switch`;
- direct Wasm calls become Zig calls.

Operand values remain in an explicit `Val` stack so branches can carry a block
result without changing the control-flow lowering.

Trapping helpers and generated functions return a small Zig error union. A trap
propagates to the public `render` wrapper, which converts it to a specific
`Status`. Memory and globals changed before the trap remain changed; there is no
rollback.

## Initial Translation Profile

The first backend accepts:

- one defined wasm32 memory with a declared maximum;
- no imports, start function, shared memory, atomics, or `memory.grow`;
- structured control flow, `br_table`, and direct calls;
- Core WebAssembly 1.0 integer and floating-point constants, comparisons,
  arithmetic, rounding, conversions, and reinterpretation instructions;
- scalar integer and floating-point loads and stores;
- mutable and immutable scalar globals with constant initializers;
- active data segments;
- `memory.size`, `memory.copy`, and `memory.fill`;
- one fixed `funcref` table, active function-index element segments, and
  `call_indirect`.

It currently rejects:

- passive data, `memory.init`, and `data.drop`;
- saturating conversions, SIMD, exceptions, tail calls, and reference
  instructions;
- block signatures that use a type index or more than one result.

The generated source targets little-endian systems. QIP currently tests native
translation on little-endian x86-64 and AArch64; there is no byte-swapping path.

`call_indirect` introduces runtime target selection, but not runtime code
loading. The translator emits the fixed Core 1.0 table as a Zig constant and a
`switch` over structurally compatible, already-generated functions. Generated
code checks the table index, null slots, structural function type, and the same
call-depth limit used by direct calls. Each failed check returns a distinct trap
status. Imports and host callbacks remain unavailable.

This native translation profile differs from QIP's strict Wasm profile. The
strict profile rejects indirect calls so it can prove an acyclic direct call
graph. Generated Zig instead bounds direct and indirect nesting at runtime.

The public wrapper covers Content `render`. It does not yet expose optional
`uniform_set_*` exports.

## When Not To Use It

Use a normal WebAssembly runtime when a component needs imports, WASI, threads,
memory growth, passive data, or a proposal outside this profile. Use the C
backend when the host application is not already built with Zig.

Generated Zig is intended for a fixed collection of reviewed QIP components
compiled into a native program.
