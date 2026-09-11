# Translating QIP Components To Swift

The supported way to use a translated QIP Content component from Swift is to
generate C source with `qip-component-to-c.wasm`, compile it as a Clang module,
and put a small Swift facade around its C API. Clang compiles and optimizes the
generated functions quickly. Swift only sees the narrow component boundary.

`qip-component-to-swift.wasm` is an experiment that translates a bounded QIP
Content component directly into Swift source. Do not use this backend for a
large component. On the current development machine, an optimized CommonMark
build did not finish after seven minutes. Adding explicit types and avoiding
protocols did not resolve the compile-time cost.

Neither route is a general WebAssembly-to-Swift translator.

## Supported Swift Integration

Generate the component as C:

```sh
./qip run \
  -i text/trim.wasm \
  -o trim.h \
  application/wasm/qip-component-to-c.wasm
```

Define `QIP_WASM_IMPLEMENTATION` in one C translation unit. Expose that header
to Swift through a Clang module or the application's bridging header. Keep the
Swift facade small: allocate or accept the raw workspace, call initialize and
render, and convert C status values to a Swift error type. Do not reproduce the
generated component implementation in Swift.

```sh
make -j application/wasm/qip-component-to-swift.wasm
./qip run \
  -i text/trim.wasm \
  -o trim.swift \
  application/wasm/qip-component-to-swift.wasm
```

Validate untrusted input with `wasm-validate` before translation. The backend
checks its feature profile, but it is not a complete WebAssembly validator.

## Experimental Direct-Swift API

The host owns the memory, dirty-page bitmap, and generation counter. Pass their
raw buffers to `initialize`:

```swift
var memory = [UInt8](repeating: 0, count: memorySize)
var dirty = [UInt64](repeating: 0, count: requiredDirtyWords(memorySize))
var generation: UInt64 = 0
var instance = Instance()
var outputOffset: UInt32 = 0
var outputSize: UInt32 = 0

memory.withUnsafeMutableBytes { memoryBuffer in
    dirty.withUnsafeMutableBufferPointer { dirtyBuffer in
        withUnsafeMutablePointer(to: &generation) { generationPointer in
            _ = initialize(
                &instance,
                memory: memoryBuffer,
                dirtyPages: dirtyBuffer,
                generation: generationPointer,
                inputSize: 0
            )
            _ = render(
                &instance,
                inputSize: 0,
                outputOffset: &outputOffset,
                outputSize: &outputSize
            )
        }
    }
}
```

The buffers and generation pointer must remain valid while the instance is in
use. Generated code does not own or free them.

Independently generated Swift modules can receive the same three host buffers.
Initializing the next component preserves its input range, clears dirty bytes
outside that range, and advances the generation. An older instance then returns
`staleInstance`. This is sequential workspace reuse. It is not WebAssembly
shared memory, and generated components remain single-threaded.

## Translation Profile

The backend currently supports the same initial profile as the Zig backend:

- Core WebAssembly 1.0 scalar integer and floating-point instructions;
- structured control flow, direct calls, and single-value results;
- checked scalar loads and stores in fixed little-endian memory;
- scalar globals, active data segments, and memory copy and fill;
- one fixed function table and checked `call_indirect`;
- recoverable memory, numeric, table, and call-depth traps.

It rejects imports, WASI, host callbacks, start functions, memory growth,
threads, atomics, multiple memories or tables, passive data, saturating
conversions, SIMD, exceptions, tail calls, and multi-value signatures. The
source file starts with the complete supported and disabled feature list.

Compile each generated file as its own Swift module if an application embeds
more than one component. The generated public names are intentionally generic.

The complex differential suite translates CommonMark, JSON prettify,
PNG-to-BMP, BMP-to-PNG, and Wasm counts. It compares native Swift output with
the Wasm runtime output byte for byte:

```sh
make test-qip-component-to-swift-complex
```

This suite is separate from `make test` because its five Swift compilations take
several minutes. CommonMark alone takes about two minutes with `-Onone` on the
current development machine. An optimized build did not finish after seven
minutes. The experiment must change its generated code shape before direct
Swift is a practical build boundary.

## When Not To Use It

Use a normal WebAssembly runtime when a component needs imports, WASI, threads,
memory growth, or proposals outside this profile. Use the Zig backend when Zig
is the application build boundary. For a Swift application, use the generated C
backend through Swift's C interoperability unless a small experimental
component has a specific reason to use direct Swift source.
