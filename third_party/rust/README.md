# Vendored Rust packages

These Cargo packages are build inputs for QIP components. Builds use the local
paths and do not download package source.

| Package | Version | Cargo package SHA-256 | License | Upstream |
| --- | --- | --- | --- | --- |
| `wasmparser` | 0.252.0 | `d3eb099dcadcde5be9eef55e3a337128efd4e44b4c93122487e4d2e4e1c6627c` | Apache-2.0 with LLVM exception, Apache-2.0, or MIT | <https://github.com/bytecodealliance/wasm-tools/tree/main/crates/wasmparser> |
| `bitflags` | 2.13.0 | `b4388bee8683e3d04af747c73422af53102d2bd24d9eadb6cbc100baef4b43f8` | MIT or Apache-2.0 | <https://github.com/bitflags/bitflags/tree/2.13.0> |

The package archives came from crates.io. Each package directory also contains
Cargo's per-file checksum manifest and the upstream license files.
