# WebAssembly Core 2.0 validator build

This QIP component validates the complete WebAssembly Core 2.0 language and
passes valid `application/wasm` input through unchanged. It uses
`wasmparser::Validator` with `WasmFeatures::WASM2`. This setting enables only
the proposals in Core 2.0 and rejects later WebAssembly proposals.

The build uses `wasmparser` 0.252.0 and `bitflags` 2.13.0 from
`third_party/rust`. Their Cargo package checksums are recorded in
`third_party/rust/README.md`.

Install Rust 1.85 or later and its `wasm32-unknown-unknown` target. The normal
build does not access the network:

```sh
rustup target add wasm32-unknown-unknown
make components/application/wasm/wasm-validate-core-2.0.wasm
```

The component has an 8 MiB input buffer and a 64 MiB fixed allocator arena.
It does not import host functions and does not use `memory.grow`. If the arena
is exhausted, the render call traps and the host must discard that instance.

The acceptance test uses the official `wg-2.0` specification tests at commit
`fffc6e12fa454e475455a7b58d3b5dc343980c10`.
The GitHub tag archive used for the recorded run has SHA-256
`263aef470fbe49aca2687f5996fee9f8f550944f613769b3fa708eb6d0ceb846`.

Run the suite from a checkout of that commit:

```sh
WASM_CORE_2_0_SPEC_DIR=/path/to/spec make test-wasm-core-2-spec
```
